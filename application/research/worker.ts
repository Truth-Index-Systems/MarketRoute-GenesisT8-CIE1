import { RESEARCH_PROVIDER_TIMEOUT_MS, assertResearchProviderResultSafe, type ResearchProvider, type ResearchWorkUnit } from "../../core/research/index";
import { ResearchRepository } from "../../platform/database/research-repository";
import { EvidenceService } from "../evidence/service";
import { RelationshipService } from "../relationships/service";
import { ContactAuthorityService } from "../contacts/service";
import { CommercialRealityService } from "../commercial-reality/service";

export interface ResearchWorkerDependencies {repository:ResearchRepository;provider:ResearchProvider;evidence:EvidenceService;relationships:RelationshipService;contacts:ContactAuthorityService;r4:CommercialRealityService;}
export class ResearchWorker {
  constructor(private readonly d:ResearchWorkerDependencies){}
  async runOne(schedulerRunId:string,at?:string){
    const now=(at?new Date(at):new Date()).toISOString();const work=await this.d.repository.claimNext(schedulerRunId,now);if(!work)return null;
    let incurredCostUsd=0;
    try{
      const requestedOrigin=String(work.payload.researchOrigin??"CUSTOMER_CAMPAIGN");const executionOrigin=work.attemptNumber>1?"SYSTEM_RETRY":requestedOrigin;
      let metadata:Record<string,unknown>={action:work.action,researchOrigin:requestedOrigin,executionOrigin,attemptNumber:work.attemptNumber};
      if(work.action==="REVALIDATE_R4") await this.d.r4.evaluate({organisationId:work.organisationId,campaignId:work.campaignId,companyId:work.companyId,referenceTime:now});
      else if(work.action==="REVALIDATE_R5") await this.d.relationships.evaluateRoutes({organisationId:work.organisationId,campaignId:work.campaignId,companyId:work.companyId,referenceTime:now});
      else if(work.action==="REVALIDATE_R6") await this.d.contacts.evaluate({organisationId:work.organisationId,campaignId:work.campaignId,companyId:work.companyId,referenceTime:now});
      else {
        const unit:ResearchWorkUnit={ordinal:1,gapKey:work.gapKey,layer:work.layer,tier:work.tier,action:work.action,subjectType:work.subjectType,subjectId:work.subjectId,claimKey:work.claimKey,reasonCode:work.reasonCode,queryHints:work.queryHints,costCeilingUsd:work.costCeilingUsd,dedupeKey:String(work.payload.dedupeKey??work.workUnitId),payload:{...work.payload,organisationId:work.organisationId,campaignId:work.campaignId,companyId:work.companyId}};
        const controller=new AbortController();const timeout=setTimeout(()=>controller.abort("MARKETROUTE_RESEARCH_PROVIDER_TIMEOUT"),RESEARCH_PROVIDER_TIMEOUT_MS);
        let result;
        try{result=await this.d.provider.execute(unit,{signal:controller.signal,timeoutMs:RESEARCH_PROVIDER_TIMEOUT_MS});}
        catch(error){if(controller.signal.aborted){const timeoutError=new Error("MARKETROUTE_RESEARCH_PROVIDER_TIMEOUT") as Error&{costUsd?:unknown};if(typeof error==="object"&&error!==null&&"costUsd" in error)timeoutError.costUsd=(error as {costUsd?:unknown}).costUsd;throw timeoutError;}throw error;}
        finally{clearTimeout(timeout);}
        incurredCostUsd=Number(result.costUsd);if(!Number.isFinite(incurredCostUsd)||incurredCostUsd<0)throw new Error("MARKETROUTE_RESEARCH_PROVIDER_COST_INVALID");
        assertResearchProviderResultSafe(result);if(incurredCostUsd>work.costCeilingUsd)throw new Error("MARKETROUTE_RESEARCH_PROVIDER_COST_CEILING_EXCEEDED");
        for(const finding of result.findings){
          if(finding.kind==="CLAIM_EVIDENCE"){const p=finding.payload;const ingested=await this.d.evidence.ingest({source:p.source,acquisition:p.acquisition,evidence:p.evidence});await this.d.evidence.recordClaimEvidence({claim:p.claim,evidenceItemId:ingested.evidenceItemId,polarity:p.polarity,linkMethod:"AI_EXTRACTED",linkVersion:"MRV2-RESEARCH-1.0.0"});}
          else if(finding.kind==="RELATIONSHIP_EVIDENCE"){const p=finding.payload;await this.d.relationships.recordEvidence({relationship:p.relationship,source:p.source,acquisition:p.acquisition,evidence:p.evidence,polarity:p.polarity,linkMethod:"AI_EXTRACTED",linkVersion:"MRV2-RESEARCH-1.0.0",referenceTime:now});}
          else {const p=finding.payload;await this.d.contacts.recordEvidence({claim:p.claim,source:p.source,acquisition:p.acquisition,evidence:p.evidence,polarity:p.polarity,linkMethod:"AI_EXTRACTED",linkVersion:"MRV2-RESEARCH-1.0.0",referenceTime:now});}
        }
        if(work.layer==="R4")await this.d.r4.evaluate({organisationId:work.organisationId,campaignId:work.campaignId,companyId:work.companyId,referenceTime:now});
        else if(work.layer==="R5")await this.d.relationships.evaluateRoutes({organisationId:work.organisationId,campaignId:work.campaignId,companyId:work.companyId,referenceTime:now});
        else await this.d.contacts.evaluate({organisationId:work.organisationId,campaignId:work.campaignId,companyId:work.companyId,referenceTime:now});
        metadata={...metadata,providerMetadata:result.metadata??{},findingCount:result.findings.length};
      }
      await this.d.repository.complete(work.workUnitId,schedulerRunId,incurredCostUsd,metadata,new Date().toISOString());return {work,status:"SUCCEEDED" as const,costUsd:incurredCostUsd};
    }catch(error){
      const code=error instanceof Error?error.message:"MARKETROUTE_RESEARCH_UNKNOWN_FAILURE";
      const reportedCost=typeof error==="object"&&error!==null&&"costUsd" in error?Number((error as {costUsd?:unknown}).costUsd):NaN;
      const providerAction=work.action==="ACQUIRE_CLAIM_EVIDENCE"||work.action==="DISCOVER_ROUTE_STRUCTURE"||work.action==="RESEARCH_CONTACT_BINDING";
      const failedCostUsd=Number.isFinite(reportedCost)&&reportedCost>=0?reportedCost:(incurredCostUsd>0?incurredCostUsd:(providerAction?work.costCeilingUsd:0));
      await this.d.repository.fail(work.workUnitId,schedulerRunId,code,failedCostUsd,true,new Date().toISOString());throw error;
    }
  }
}
