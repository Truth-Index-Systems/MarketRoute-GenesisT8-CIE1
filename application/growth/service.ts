import { evidenceServiceFromEnvironment } from "../evidence/service";
import { truthServiceFromEnvironment } from "../truth/service";
import { relationshipServiceFromEnvironment } from "../relationships/service";
import { contactAuthorityServiceFromEnvironment } from "../contacts/service";
import { ProductionContextRepository } from "../../platform/database/production-context-repository";
import { genesisGrowthRepositoryFromEnvironment,type GrowthAction } from "../../platform/database/genesis-growth-repository";
import { openAIGenesisGrowthProviderFromEnvironment,type GrowthClaimFinding,type GrowthSourceRow } from "../../platform/ai/openai-growth-provider";
import type { AccessPointKind } from "../../core/relationships/index";

const INDUSTRIES:Record<string,string>={
  software:"Software & SaaS","professional-services":"Professional Services",marketing:"Marketing & Advertising",recruitment:"Recruitment & HR",finance:"Finance & FinTech",healthcare:"Healthcare & HealthTech",retail:"Retail & E-commerce",manufacturing:"Manufacturing",logistics:"Logistics & Supply Chain",construction:"Construction & PropTech"
};
function intEnv(name:string,fallback:number,min:number,max:number){const n=Number(process.env[name]??fallback);return Number.isFinite(n)?Math.max(min,Math.min(max,Math.floor(n))):fallback;}
function numberEnv(name:string,fallback:number,min:number,max:number){const n=Number(process.env[name]??fallback);return Number.isFinite(n)?Math.max(min,Math.min(max,n)):fallback;}
function boolEnv(name:string,fallback:boolean){const raw=process.env[name]?.trim().toLowerCase();return raw?raw==="true":fallback;}
function cleanKey(value:string){return value.normalize("NFKC").trim().toLowerCase().replace(/[^a-z0-9._:@/+\-]+/g,"-").slice(0,180)||"access";}
function source(row:GrowthSourceRow){let publisher=row.publisherDomain;try{publisher=new URL(row.sourceUrl).hostname.toLowerCase().replace(/^www\./,"");}catch{}return{sourceKind:"WEB" as const,url:row.sourceUrl,publisherDomain:publisher,title:row.sourceTitle,publishedAt:row.publishedAt,stableLocator:row.sourceUrl,metadata:{producer:"GENESIS_DATABASE_GROWTH_V1"}};}
function acquisition(row:GrowthSourceRow){return{method:"SEARCH_RESULT" as const,acquiredAt:new Date().toISOString(),rawLocator:row.sourceUrl,parserVersion:"MRV2-GENESIS-GROWTH-1.0.0",metadata:{provider:"OPENAI_RESPONSES"}};}
function evidence(row:GrowthSourceRow){return{evidenceKind:"QUOTE" as const,excerptText:row.evidenceText,observedAt:row.observedAt||new Date().toISOString(),originPublishedAt:row.publishedAt,extractionMethod:"AI_EXTRACTED" as const,extractionVersion:"MRV2-GENESIS-GROWTH-1.0.0"};}
function objectOf(row:GrowthClaimFinding){return row.objectType==="BOOLEAN"?row.booleanValue:row.textValue;}
function retryAt(hours:number){return new Date(Date.now()+hours*3600_000).toISOString();}
function errorCode(error:unknown){return (error instanceof Error?error.message:"MARKETROUTE_GROWTH_FAILED").slice(0,300);}
class GrowthActionExecutionFailure extends Error{
  constructor(readonly costUsd:number,cause:unknown){super(errorCode(cause));this.name="GrowthActionExecutionFailure";}
}
function failureCost(error:unknown){return error instanceof GrowthActionExecutionFailure?Math.max(0,error.costUsd):0;}

export class GenesisDatabaseGrowthService{
  private readonly repo=genesisGrowthRepositoryFromEnvironment();
  private readonly ai=openAIGenesisGrowthProviderFromEnvironment();
  private readonly context=new ProductionContextRepository();
  private readonly evidenceService=evidenceServiceFromEnvironment();
  private readonly truth=truthServiceFromEnvironment();
  private readonly relationships=relationshipServiceFromEnvironment();
  private readonly contacts=contactAuthorityServiceFromEnvironment();

  private settings(){return{enabled:boolEnv("MARKETROUTE_GROWTH_ENABLED",true),seedTarget:intEnv("MARKETROUTE_GROWTH_SEED_TARGET_PER_INDUSTRY",50,1,10000),launchTarget:intEnv("MARKETROUTE_GROWTH_LAUNCH_TARGET_PER_INDUSTRY",500,1,100000),dailyBudgetUsd:numberEnv("MARKETROUTE_GROWTH_DAILY_BUDGET_USD",100,0,1_000_000),maxActionCostUsd:numberEnv("MARKETROUTE_GROWTH_MAX_ACTION_COST_USD",0.5,0.001,10000),discoveryBatch:intEnv("MARKETROUTE_GROWTH_DISCOVERY_BATCH",10,1,25),maxActions:intEnv("MARKETROUTE_CRON_GROWTH_ACTIONS",1,1,20),retryHours:intEnv("MARKETROUTE_GROWTH_RETRY_HOURS",24,1,720),refreshDays:intEnv("MARKETROUTE_GROWTH_REFRESH_DAYS",30,1,365)};}

  private async persistClaim(companyId:string,row:GrowthClaimFinding){
    if(objectOf(row)===null||objectOf(row)===undefined)return null;
    const ingested=await this.evidenceService.ingest({source:source(row),acquisition:acquisition(row),evidence:{...evidence(row),tenantScopeOrganisationId:null,subjectType:"COMPANY",subjectId:companyId}});
    const linked=await this.evidenceService.recordClaimEvidence({claim:{tenantScopeOrganisationId:null,subjectType:"COMPANY",subjectId:companyId,claimKey:row.claimKey,predicate:"equals",object:objectOf(row),canonicalValueText:String(objectOf(row))},evidenceItemId:ingested.evidenceItemId,polarity:row.polarity,linkMethod:"AI_EXTRACTED",linkVersion:"MRV2-GENESIS-GROWTH-1.0.0"});
    await this.truth.evaluateClaim(linked.claimId);
    return linked.claimId;
  }

  private async evaluateCompany(companyId:string){return this.truth.evaluateEntity({tenantScopeOrganisationId:null,subjectType:"COMPANY",subjectId:companyId,profileKey:"COMPANY_CORE_V1"});}

  private async discover(action:GrowthAction){
    const industryKey=action.industryKey!;
    const industryName=INDUSTRIES[industryKey]??industryKey;
    const existing=await this.repo.existingDomains(industryKey,5000);
    const result=await this.ai.discoverIndustry({industryKey,industryName,count:action.discoveryBatchSize,existingDomains:existing});
    try{
      let persisted=0,coreComplete=0,evidenceRows=0;
      for(const c of result.value.companies){
        const companyId=await this.repo.ensureCompany({industryKey,name:c.name,domain:c.domain,websiteUrl:c.websiteUrl,countryCode:c.countryCode,discoveryReason:c.discoveryReason});
        const keys=new Set<string>();
        for(const row of c.evidence){
          await this.persistClaim(companyId,row);
          if(row.polarity==="SUPPORTS")keys.add(row.claimKey);
          evidenceRows++;
        }
        await this.evaluateCompany(companyId);
        const complete=["identity.canonical_name","identity.canonical_domain","operation.current"].every(k=>keys.has(k));
        await this.repo.markStage(companyId,"CORE",complete,complete?null:"GENESIS_GROWTH_CORE_EVIDENCE_INCOMPLETE",complete?null:retryAt(action.retryHours),new Date().toISOString());
        persisted++;
        if(complete)coreComplete++;
      }
      return{costUsd:result.usage.estimatedCostUsd,metadata:{industryKey,industryName,discovered:result.value.companies.length,persisted,coreComplete,evidenceRows,model:result.model,responseId:result.responseId,webSearchCalls:result.usage.webSearchCalls}};
    }catch(error){throw new GrowthActionExecutionFailure(result.usage.estimatedCostUsd,error);}
  }

  private async profile(action:GrowthAction){
    const company=await this.context.company(action.companyId!);
    const industryName=INDUSTRIES[action.industryKey??""]??action.industryKey??"Unclassified";
    const result=await this.ai.researchProfile({companyName:company.name,domain:company.canonicalDomain,industryName});
    try{
      const keys=new Set<string>();
      for(const row of result.value.findings){
        await this.persistClaim(company.companyId,row);
        if(row.polarity==="SUPPORTS")keys.add(row.claimKey);
      }
      await this.evaluateCompany(company.companyId);
      const core=["identity.canonical_name","identity.canonical_domain","operation.current"].every(k=>keys.has(k));
      const profileKeys=["industry.category","commercial.offering","market.customer","geography.primary","business_model.type","commercial.buying_signal"];
      const profileCount=profileKeys.filter(k=>keys.has(k)).length;
      const at=new Date().toISOString();
      await this.repo.markStage(company.companyId,"CORE",core,null,null,at);
      await this.repo.markStage(company.companyId,"PROFILE",profileCount>=3,profileCount>=3?null:"GENESIS_GROWTH_PROFILE_INCOMPLETE",profileCount>=3?null:retryAt(action.retryHours),at);
      return{costUsd:result.usage.estimatedCostUsd,metadata:{companyId:company.companyId,findings:result.value.findings.length,coreComplete:core,profileFields:profileCount,model:result.model,responseId:result.responseId}};
    }catch(error){throw new GrowthActionExecutionFailure(result.usage.estimatedCostUsd,error);}
  }

  private async routes(action:GrowthAction){
    const company=await this.context.company(action.companyId!);
    const result=await this.ai.researchRoutes({companyName:company.name,domain:company.canonicalDomain});
    try{
      let persisted=0;
      for(const row of result.value.routes){
        if(row.polarity!=="SUPPORTS")continue;
        const companyNode={nodeKind:"COMPANY" as const,companyId:company.companyId,label:company.name};
        const access={tenantScopeOrganisationId:null,nodeKind:"ACCESS_POINT" as const,stableKey:`growth:${cleanKey(row.accessPointKind)}:${cleanKey(row.accessPointValue)}`,label:row.accessPointKind.replace(/_/g," "),accessPointKind:row.accessPointKind as AccessPointKind,canonicalValue:row.accessPointValue};
        if(row.organisationalUnitKey&&row.organisationalUnitLabel){
          const unit={tenantScopeOrganisationId:null,nodeKind:"ORGANISATIONAL_UNIT" as const,stableKey:`growth:${cleanKey(company.companyId)}:${cleanKey(row.organisationalUnitKey)}`,label:row.organisationalUnitLabel};
          await this.relationships.recordEvidence({relationship:{tenantScopeOrganisationId:null,relationType:"parent_of",from:companyNode,to:unit},source:source(row),acquisition:acquisition(row),evidence:evidence(row),polarity:"SUPPORTS",linkMethod:"AI_EXTRACTED",linkVersion:"MRV2-GENESIS-GROWTH-1.0.0"});
          await this.relationships.recordEvidence({relationship:{tenantScopeOrganisationId:null,relationType:"has_access_point",from:unit,to:access},source:source(row),acquisition:acquisition(row),evidence:evidence(row),polarity:"SUPPORTS",linkMethod:"AI_EXTRACTED",linkVersion:"MRV2-GENESIS-GROWTH-1.0.0"});
          persisted+=2;
        }else{
          await this.relationships.recordEvidence({relationship:{tenantScopeOrganisationId:null,relationType:"has_access_point",from:companyNode,to:access},source:source(row),acquisition:acquisition(row),evidence:evidence(row),polarity:"SUPPORTS",linkMethod:"AI_EXTRACTED",linkVersion:"MRV2-GENESIS-GROWTH-1.0.0"});
          persisted++;
        }
      }
      const complete=persisted>0;
      await this.repo.markStage(company.companyId,"ROUTES",complete,complete?null:"GENESIS_GROWTH_ROUTE_NOT_FOUND",complete?null:retryAt(action.retryHours),new Date().toISOString());
      return{costUsd:result.usage.estimatedCostUsd,metadata:{companyId:company.companyId,routesReturned:result.value.routes.length,relationshipsPersisted:persisted,complete,model:result.model,responseId:result.responseId}};
    }catch(error){throw new GrowthActionExecutionFailure(result.usage.estimatedCostUsd,error);}
  }

  private async contactsAction(action:GrowthAction){
    const company=await this.context.company(action.companyId!);
    const result=await this.ai.researchContacts({companyName:company.name,domain:company.canonicalDomain});
    try{
      let qualified=0;
      for(const row of result.value.contacts){
        if([row.identityEvidence,row.employmentEvidence,row.roleEvidence,row.channelEvidence].some(e=>e.polarity!=="SUPPORTS"))continue;
        const personId=await this.repo.ensurePerson(company.companyId,row.name);
        const companyNode={nodeKind:"COMPANY" as const,companyId:company.companyId,label:company.name};
        const personNode={nodeKind:"PERSON" as const,personId,label:row.name};
        await this.contacts.recordEvidence({claim:{kind:"IDENTITY",tenantScopeOrganisationId:null,personId,canonicalName:row.name},source:source(row.identityEvidence),acquisition:acquisition(row.identityEvidence),evidence:evidence(row.identityEvidence),polarity:"SUPPORTS",linkMethod:"AI_EXTRACTED",linkVersion:"MRV2-GENESIS-GROWTH-1.0.0"});
        await this.contacts.recordEvidence({claim:{kind:"CURRENT_EMPLOYMENT",tenantScopeOrganisationId:null,personId,companyId:company.companyId},source:source(row.employmentEvidence),acquisition:acquisition(row.employmentEvidence),evidence:evidence(row.employmentEvidence),polarity:"SUPPORTS",linkMethod:"AI_EXTRACTED",linkVersion:"MRV2-GENESIS-GROWTH-1.0.0"});
        await this.contacts.recordEvidence({claim:{kind:"CURRENT_ROLE",tenantScopeOrganisationId:null,personId,companyId:company.companyId,roleTitle:row.roleTitle},source:source(row.roleEvidence),acquisition:acquisition(row.roleEvidence),evidence:evidence(row.roleEvidence),polarity:"SUPPORTS",linkMethod:"AI_EXTRACTED",linkVersion:"MRV2-GENESIS-GROWTH-1.0.0"});
        await this.relationships.recordEvidence({relationship:{tenantScopeOrganisationId:null,relationType:"employs",from:companyNode,to:personNode},source:source(row.employmentEvidence),acquisition:acquisition(row.employmentEvidence),evidence:evidence(row.employmentEvidence),polarity:"SUPPORTS",linkMethod:"AI_EXTRACTED",linkVersion:"MRV2-GENESIS-GROWTH-1.0.0"});
        const access={tenantScopeOrganisationId:null,nodeKind:"ACCESS_POINT" as const,stableKey:`growth:${cleanKey(row.channelKind)}:${cleanKey(row.channelValue)}`,label:row.channelKind.replace(/_/g," "),accessPointKind:row.channelKind as AccessPointKind,canonicalValue:row.channelValue};
        const rel=await this.relationships.recordEvidence({relationship:{tenantScopeOrganisationId:null,relationType:"has_access_point",from:personNode,to:access},source:source(row.channelEvidence),acquisition:acquisition(row.channelEvidence),evidence:evidence(row.channelEvidence),polarity:"SUPPORTS",linkMethod:"AI_EXTRACTED",linkVersion:"MRV2-GENESIS-GROWTH-1.0.0"});
        await this.contacts.recordEvidence({claim:{kind:"CHANNEL_OWNERSHIP",tenantScopeOrganisationId:null,accessPointId:rel.to.node_id,personId},source:source(row.channelEvidence),acquisition:acquisition(row.channelEvidence),evidence:evidence(row.channelEvidence),polarity:"SUPPORTS",linkMethod:"AI_EXTRACTED",linkVersion:"MRV2-GENESIS-GROWTH-1.0.0"});
        qualified++;
      }
      const complete=qualified>0;
      await this.repo.markStage(company.companyId,"CONTACTS",complete,complete?null:"GENESIS_GROWTH_CONTACT_NOT_FOUND",complete?null:retryAt(action.retryHours),new Date().toISOString());
      return{costUsd:result.usage.estimatedCostUsd,metadata:{companyId:company.companyId,contactsReturned:result.value.contacts.length,qualifiedContacts:qualified,complete,model:result.model,responseId:result.responseId}};
    }catch(error){throw new GrowthActionExecutionFailure(result.usage.estimatedCostUsd,error);}
  }

  private execute(action:GrowthAction){if(action.actionKind==="DISCOVER_COMPANIES")return this.discover(action);if(action.actionKind==="RESEARCH_CORE_PROFILE"||action.actionKind==="REFRESH_CORE")return this.profile(action);if(action.actionKind==="RESEARCH_ROUTES")return this.routes(action);return this.contactsAction(action);}

  async runCycle(){
    const settings=this.settings();
    await this.repo.syncSettings(settings);
    if(!settings.enabled)return{status:"DISABLED" as const,processed:0};
    const at=new Date().toISOString();
    let runId:string|null=null;
    let processed=0,succeeded=0,failed=0,budgetExhausted=false;
    try{
      runId=await this.repo.start(at);
      for(let i=0;i<settings.maxActions;i++){
        await this.repo.heartbeat(runId,new Date().toISOString());
        const next=await this.repo.nextAction(runId,new Date().toISOString());
        if(!next)break;
        if(next.state==="BUDGET_EXHAUSTED"){budgetExhausted=true;break;}
        processed++;
        let incurredCostUsd=0;
        try{
          const result=await this.execute(next);
          incurredCostUsd=result.costUsd;
          await this.repo.complete(next.actionRunId,result.costUsd,result.metadata,new Date().toISOString());
          succeeded++;
        }catch(error){
          incurredCostUsd=Math.max(incurredCostUsd,failureCost(error));
          await this.repo.fail(next.actionRunId,errorCode(error),incurredCostUsd,retryAt(next.retryHours),new Date().toISOString());
          failed++;
        }
      }
      await this.repo.finish(runId,failed>0&&succeeded>0?"PARTIAL":failed>0?"FAILED":"SUCCEEDED",{processed,succeeded,failed,budgetExhausted},new Date().toISOString());
      return{status:"OK" as const,processed,succeeded,failed,budgetExhausted};
    }catch(error){
      if(runId){try{await this.repo.finish(runId,"FAILED",{errorCode:errorCode(error),processed,succeeded,failed},new Date().toISOString());}catch{}}
      throw error;
    }
  }

}
export function genesisDatabaseGrowthServiceFromEnvironment(){return new GenesisDatabaseGrowthService();}
