import { randomUUID } from "node:crypto";
import { SellerGenomeService } from "../seller-genome/service";
import { SellerGenomeRepository } from "../../platform/database/seller-genome-repository";
import { openAISellerGenomeExtractorFromEnvironment } from "../../platform/ai/openai-seller-genome-extractor";
import { openAITargetDiscoveryProviderFromEnvironment,type DiscoveredTarget } from "../../platform/ai/openai-target-discovery";
import { productionActivationRepositoryFromEnvironment } from "../../platform/database/production-activation-repository";
import { marketrouteErrorCode } from "../../platform/database/postgrest-rpc";
import { activationCountryCodes,activationIndustryKeys,activationMinimumBankTargets,activationTargetCount } from "./activation-targets";

function num(name:string,fallback:number,min:number,max:number){const v=Number(process.env[name]??fallback);return Number.isFinite(v)?Math.max(min,Math.min(max,v)):fallback;}
function retryable(code:string){return !/SELLER_OFFERING_UNRESOLVED|HARD_CONSTRAINTS_NOT_CANONICALLY_REPRESENTED|TARGET_DISCOVERY_EMPTY|SETUP_/.test(code);}
function canonicalDomain(value:string|null|undefined){try{return new URL(value?.includes("://")?value!:`https://${value??""}`).hostname.toLowerCase().replace(/^www\./,"");}catch{return String(value??"").trim().toLowerCase().replace(/^www\./,"");}}

export async function runWorkspaceActivationOnce(workerId=`ACTIVATION:${randomUUID()}`){
  const repo=productionActivationRepositoryFromEnvironment();
  const job=await repo.claim(workerId,new Date().toISOString());
  if(!job)return null;
  try{
    const anonymous=job.activation_kind==="ANONYMOUS_DISCOVERY"?await repo.anonymousPolicyForActivation(job.organisation_id,job.job_id):null;
    const activationOrigin=anonymous?"ANONYMOUS_DISCOVERY":"CUSTOMER_ACTIVATION";
    const material={websiteUrl:job.website_url,sellerOfferingText:job.seller_offering_text,objectiveText:job.objective_text,targetMarketText:job.target_market_text,hardConstraintsText:job.hard_constraints_text,noHardConstraints:job.no_hard_constraints};
    const sellerService=new SellerGenomeService(SellerGenomeRepository.fromEnvironment());
    const persisted=await sellerService.extractAndPersist({organisationId:job.organisation_id,sellerBusinessId:job.seller_business_id,sellerDisplayName:job.seller_name,materialKind:"COMPOSITE",sourceContent:material,extractor:openAISellerGenomeExtractorFromEnvironment({organisationId:job.organisation_id,origin:activationOrigin}),createdByUserId:job.created_by_user_id});
    await repo.stage(job.job_id,workerId,"SELLER_CONTEXT_READY",30,{genomeSnapshotId:persisted.genomeSnapshotId,semanticCompleteness:persisted.semanticCompleteness});
    await repo.stage(job.job_id,workerId,"CREATING_CAMPAIGN",38,{campaignName:job.campaign_name??"Initial market research"});
    const campaignId=await repo.createCampaign(job.job_id,job.organisation_id,job.seller_business_id,job.campaign_name,job.objective_text);
    await repo.stage(job.job_id,workerId,"CAMPAIGN_CREATED",48,{campaignId});
    await sellerService.selectCampaignObjective({organisationId:job.organisation_id,campaignId,genomeSnapshotId:persisted.genomeSnapshotId,objectiveKey:"primary_objective",requestId:randomUUID()});
    const anonymousBudget=anonymous?Math.max(0.5,Math.min(25,anonymous.lifetimeBudgetUsd)):null;
    await repo.setResearchPolicy({organisationId:job.organisation_id,campaignId,dailyBudgetUsd:anonymousBudget??num("MARKETROUTE_DEFAULT_DAILY_RESEARCH_BUDGET_USD",100,1,10000),maxJobCostUsd:anonymous?Math.min(anonymousBudget!,num("MARKETROUTE_ANONYMOUS_MAX_JOB_COST_USD",0.35,0.05,2)):num("MARKETROUTE_DEFAULT_MAX_JOB_COST_USD",0.5,0.05,25),maxConcurrentJobs:anonymous?1:Math.floor(num("MARKETROUTE_DEFAULT_RESEARCH_CONCURRENCY",2,1,20)),maxWorkUnitsPerPlan:anonymous?Math.floor(num("MARKETROUTE_ANONYMOUS_WORK_UNITS_PER_PLAN",3,1,6)):Math.floor(num("MARKETROUTE_DEFAULT_WORK_UNITS_PER_PLAN",4,1,20)),refreshHorizonHours:anonymous?Math.floor(num("MARKETROUTE_ANONYMOUS_REFRESH_HORIZON_HOURS",24,1,168)):Math.floor(num("MARKETROUTE_DEFAULT_REFRESH_HORIZON_HOURS",2,1,168))});

    const desiredCount=anonymous?.targetCount??activationTargetCount();
    const minimumBankTargets=activationMinimumBankTargets(desiredCount);
    const industryKeys=activationIndustryKeys(persisted.genome,job.target_market_text);
    const countryCodes=activationCountryCodes(persisted.genome,job.target_market_text);
    await repo.stage(job.job_id,workerId,"SELECTING_TARGETS",58,{desiredCount,minimumBankTargets,industryKeys,countryCodes});
    const sellerDomain=canonicalDomain(job.canonical_domain);
    const bankRows=industryKeys.length?await repo.bankCandidates(industryKeys,countryCodes,desiredCount):[];
    const candidates:DiscoveredTarget[]=bankRows.filter(row=>canonicalDomain(row.canonical_domain)!==sellerDomain).map(row=>({name:row.name,domain:row.canonical_domain,websiteUrl:row.website_url,countryCode:row.country_code,researchReason:`Genesis intelligence bank · ${row.industry_key} · profile:${row.profile_complete?"complete":"pending"} · routes:${row.routes_complete?"complete":"pending"} · contacts:${row.contacts_complete?"complete":"pending"}`}));
    let webMetadata:Record<string,unknown>|null=null;
    let webCandidateCount=0;
    if(anonymous?candidates.length<desiredCount:candidates.length<minimumBankTargets){
      await repo.stage(job.job_id,workerId,"DISCOVERING_TARGETS",66,{desiredCount,bankCandidateCount:candidates.length,remainingCount:Math.max(1,desiredCount-candidates.length)});
      const remaining=Math.max(1,desiredCount-candidates.length);
      const discovery=await openAITargetDiscoveryProviderFromEnvironment().discover({sellerName:job.seller_name,sellerDomain:job.canonical_domain,objectiveText:job.objective_text,targetMarketText:job.target_market_text,canonicalSellerGenome:persisted.genome,organisationId:job.organisation_id,campaignId,count:remaining,excludedDomains:candidates.map(candidate=>candidate.domain),origin:activationOrigin});
      webMetadata=discovery.metadata;
      for(const company of discovery.companies){if(candidates.some(existing=>existing.domain===company.domain))continue;candidates.push(company);webCandidateCount++;if(candidates.length>=desiredCount)break;}
    }
    if(candidates.length===0)throw new Error("MARKETROUTE_TARGET_DISCOVERY_EMPTY");
    const companyIds:string[]=[];
    const bankCandidateCount=candidates.length-webCandidateCount;
    const strategy=webCandidateCount>0?(bankCandidateCount>0?"GENESIS_BANK_PLUS_WEB":"WEB_FALLBACK"):"GENESIS_BANK_ONLY";
    await repo.stage(job.job_id,workerId,"LINKING_COMPANIES",72,{strategy,totalCount:candidates.length,linkedCount:0,bankCandidateCount,webCandidateCount});
    for(const [index,company] of candidates.entries()){
      companyIds.push(await repo.ensureCompany(job.organisation_id,campaignId,company));
      if((index+1)%3===0||index===candidates.length-1){
        await repo.stage(job.job_id,workerId,"LINKING_COMPANIES",72+Math.round(18*(index+1)/candidates.length),{strategy,totalCount:candidates.length,linkedCount:index+1,bankCandidateCount,webCandidateCount});
      }
    }
    await repo.stage(job.job_id,workerId,"FINALISING",94,{campaignId,targetCompanyCount:companyIds.length,strategy});
    const result={campaignId,genomeSnapshotId:persisted.genomeSnapshotId,semanticCompleteness:persisted.semanticCompleteness,targetCompanyCount:companyIds.length,targetCompanyIds:companyIds,discovery:{strategy,desiredCount,minimumBankTargets,industryKeys,countryCodes,bankCandidateCount,webCandidateCount,web:webMetadata}};
    await repo.complete(job.job_id,workerId,result,new Date().toISOString());
    return{status:"SUCCEEDED" as const,jobId:job.job_id,...result};
  }catch(error){
    const code=marketrouteErrorCode(error,"MARKETROUTE_ACTIVATION_FAILED");
    await repo.fail(job.job_id,workerId,code,retryable(code),new Date().toISOString()).catch(()=>undefined);
    return{status:"FAILED" as const,jobId:job.job_id,error:code};
  }
}

export async function runAnonymousDiscoveryExtensionOnce(workerId=`ANON_EXTENSION:${randomUUID()}`){
  const repo=productionActivationRepositoryFromEnvironment();
  const job=await repo.claimAnonymousExtension(workerId,new Date().toISOString());
  if(!job)return null;
  try{
    const sellerContext=await SellerGenomeRepository.fromEnvironment().getCurrentCampaignContext(job.organisation_id,job.campaign_id);
    if(!sellerContext)throw new Error("MARKETROUTE_ANONYMOUS_EXTENSION_SELLER_CONTEXT_REQUIRED");
    const desired=Math.max(0,Math.min(job.target_count,job.remaining_count*2));
    if(desired<=0){const completed=await repo.completeAnonymousExtension(job.job_id,workerId,{linkedCount:0,reason:"READY_TARGET_ALREADY_MET"},new Date().toISOString());return{status:"SUCCEEDED" as const,jobId:job.job_id,linkedCount:0,completion:completed};}
    const industryKeys=activationIndustryKeys(sellerContext.canonicalGenome,job.target_market_text);
    const countryCodes=activationCountryCodes(sellerContext.canonicalGenome,job.target_market_text);
    const existing=new Set((job.existing_domains??[]).map(canonicalDomain).filter(Boolean));
    const sellerDomain=canonicalDomain(job.canonical_domain);
    const bankRows=industryKeys.length?await repo.bankCandidates(industryKeys,countryCodes,Math.min(25,Math.max(job.target_count,desired))):[];
    const candidates:DiscoveredTarget[]=[];
    for(const row of bankRows){const d=canonicalDomain(row.canonical_domain);if(!d||d===sellerDomain||existing.has(d)||candidates.some(c=>c.domain===d))continue;candidates.push({name:row.name,domain:d,websiteUrl:row.website_url,countryCode:row.country_code,researchReason:`Genesis intelligence bank · ${row.industry_key}`});if(candidates.length>=desired)break;}
    let webMetadata:Record<string,unknown>|null=null;
    let webCandidateCount=0;
    if(candidates.length<desired&&job.attempt_count<=2){
      const discovery=await openAITargetDiscoveryProviderFromEnvironment().discover({sellerName:job.seller_name,sellerDomain:job.canonical_domain,objectiveText:job.objective_text,targetMarketText:job.target_market_text,canonicalSellerGenome:sellerContext.canonicalGenome,organisationId:job.organisation_id,campaignId:job.campaign_id,count:desired-candidates.length,excludedDomains:[...existing,...candidates.map(candidate=>candidate.domain)],origin:"ANONYMOUS_DISCOVERY_EXTENSION"});
      webMetadata=discovery.metadata;
      for(const company of discovery.companies){const d=canonicalDomain(company.domain);if(!d||d===sellerDomain||existing.has(d)||candidates.some(c=>c.domain===d))continue;candidates.push({...company,domain:d});webCandidateCount++;if(candidates.length>=desired)break;}
    }
    let linkedCount=0;let finalScoped=job.scoped_count;
    for(const company of candidates){
      const linked=await repo.linkAnonymousExtensionCompany(job.job_id,workerId,company,new Date().toISOString());
      if(!linked)break;
      finalScoped=linked.scoped_count;
      if(linked.inserted_scope){linkedCount++;existing.add(canonicalDomain(company.domain));}
    }
    const completed=await repo.completeAnonymousExtension(job.job_id,workerId,{linkedCount,bankCandidateCount:Math.max(0,candidates.length-webCandidateCount),webCandidateCount,provider:webMetadata,scopedCount:finalScoped,readyDeficitBefore:job.remaining_count,readyTarget:job.target_count},new Date().toISOString());
    return{status:"SUCCEEDED" as const,jobId:job.job_id,linkedCount,completion:completed};
  }catch(error){
    const code=marketrouteErrorCode(error,"MARKETROUTE_ANONYMOUS_EXTENSION_FAILED");
    await repo.failAnonymousExtension(job.job_id,workerId,code,retryable(code),new Date().toISOString()).catch(()=>undefined);
    return{status:"FAILED" as const,jobId:job.job_id,error:code};
  }
}


export async function runPaidCampaignRefillOnce(workerId=`PAID_REFILL:${randomUUID()}`){
  const repo=productionActivationRepositoryFromEnvironment();
  const job=await repo.claimPaidRefill(workerId,new Date().toISOString());
  if(!job)return null;
  try{
    const sellerContext=await SellerGenomeRepository.fromEnvironment().getCurrentCampaignContext(job.organisation_id,job.campaign_id);
    if(!sellerContext)throw new Error("MARKETROUTE_PAID_REFILL_SELLER_CONTEXT_REQUIRED");
    const desired=Math.max(0,Math.min(25,job.remaining_count*2));
    if(desired<=0){const completed=await repo.completePaidRefill(job.job_id,workerId,{linkedCount:0,reason:"READY_TARGET_ALREADY_MET"},new Date().toISOString());return{status:"SUCCEEDED" as const,jobId:job.job_id,linkedCount:0,completion:completed};}
    const industryKeys=activationIndustryKeys(sellerContext.canonicalGenome,job.target_market_text);
    const countryCodes=activationCountryCodes(sellerContext.canonicalGenome,job.target_market_text);
    const existing=new Set((job.existing_domains??[]).map(canonicalDomain).filter(Boolean));
    const sellerDomain=canonicalDomain(job.canonical_domain);
    const bankRows=industryKeys.length?await repo.bankCandidates(industryKeys,countryCodes,Math.min(25,Math.max(job.target_count,desired))):[];
    const candidates:DiscoveredTarget[]=[];
    for(const row of bankRows){const d=canonicalDomain(row.canonical_domain);if(!d||d===sellerDomain||existing.has(d)||candidates.some(c=>c.domain===d))continue;candidates.push({name:row.name,domain:d,websiteUrl:row.website_url,countryCode:row.country_code,researchReason:`Genesis intelligence bank · ${row.industry_key}`});if(candidates.length>=desired)break;}
    let webMetadata:Record<string,unknown>|null=null;let webCandidateCount=0;
    if(candidates.length<desired){
      const discovery=await openAITargetDiscoveryProviderFromEnvironment().discover({sellerName:job.seller_name,sellerDomain:job.canonical_domain,objectiveText:job.objective_text,targetMarketText:job.target_market_text,canonicalSellerGenome:sellerContext.canonicalGenome,organisationId:job.organisation_id,campaignId:job.campaign_id,count:desired-candidates.length,excludedDomains:[...existing,...candidates.map(candidate=>candidate.domain)],origin:"PAID_CAMPAIGN_REFILL"});
      webMetadata=discovery.metadata;
      for(const company of discovery.companies){const d=canonicalDomain(company.domain);if(!d||d===sellerDomain||existing.has(d)||candidates.some(c=>c.domain===d))continue;candidates.push({...company,domain:d});webCandidateCount++;if(candidates.length>=desired)break;}
    }
    let linkedCount=0;let finalScoped=job.scoped_count;
    for(const company of candidates){const linked=await repo.linkPaidRefillCompany(job.job_id,workerId,company,new Date().toISOString());if(!linked)break;finalScoped=linked.scoped_count;if(linked.inserted_scope){linkedCount++;existing.add(canonicalDomain(company.domain));}}
    const completed=await repo.completePaidRefill(job.job_id,workerId,{linkedCount,bankCandidateCount:Math.max(0,candidates.length-webCandidateCount),webCandidateCount,provider:webMetadata,scopedCount:finalScoped,readyDeficitBefore:job.remaining_count,readyTarget:job.target_count},new Date().toISOString());
    return{status:"SUCCEEDED" as const,jobId:job.job_id,linkedCount,completion:completed};
  }catch(error){const code=marketrouteErrorCode(error,"MARKETROUTE_PAID_REFILL_FAILED");await repo.failPaidRefill(job.job_id,workerId,code,retryable(code),new Date().toISOString()).catch(()=>undefined);return{status:"FAILED" as const,jobId:job.job_id,error:code};}
}

export async function runWorkspaceActivationCron(max=2){
  const results=[];
  for(let i=0;i<Math.max(1,Math.min(max,5));i++){const result=await runWorkspaceActivationOnce();if(!result)break;results.push(result);}
  const extensionResults=[];
  for(let i=0;i<Math.max(1,Math.min(max,2));i++){const result=await runAnonymousDiscoveryExtensionOnce();if(!result)break;extensionResults.push(result);}
  const paidRefillResults=[];
  for(let i=0;i<Math.max(1,Math.min(max,2));i++){const result=await runPaidCampaignRefillOnce();if(!result)break;paidRefillResults.push(result);}
  const failed=results.filter(result=>result.status==="FAILED").length;
  const succeeded=results.length-failed;
  const extensionFailed=extensionResults.filter(result=>result.status==="FAILED").length;
  const paidRefillFailed=paidRefillResults.filter(result=>result.status==="FAILED").length;
  const totalProcessed=results.length+extensionResults.length+paidRefillResults.length;
  const totalFailed=failed+extensionFailed+paidRefillFailed;
  const status=totalProcessed===0?"IDLE":totalFailed===0?"SUCCEEDED":totalFailed===totalProcessed?"FAILED":"PARTIAL";
  const errorCode=results.find(result=>result.status==="FAILED")?.error??extensionResults.find(result=>result.status==="FAILED")?.error??paidRefillResults.find(result=>result.status==="FAILED")?.error??null;
  return{status,processed:results.length,succeeded,failed,errorCode,results,extensionProcessed:extensionResults.length,extensionFailed,extensionResults,paidRefillProcessed:paidRefillResults.length,paidRefillFailed,paidRefillResults};
}
