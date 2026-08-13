import { randomUUID } from "node:crypto";
import { buildOpportunityProfile, opportunityParetoFrontier, type OpportunityProfile } from "../../core/opportunities/index.js";
import { OpportunityRepository, opportunityRepositoryFromEnvironment } from "../../platform/database/opportunity-repository.js";

export class OpportunityService {
  constructor(private readonly repository:OpportunityRepository){}
  async profile(command:{organisationId:string;campaignId:string;companyId:string;at?:string}){
    const at=(command.at?new Date(command.at):new Date()).toISOString();
    const db=await this.repository.profile({...command,at});
    // Re-evaluate product semantics in the pure core. Database owns authority; this checks product-layer parity only.
    return buildOpportunityProfile({
      organisationId:db.organisationId,campaignId:db.campaignId,companyId:db.companyId,opportunityId:db.opportunityId,companyName:db.companyName,canonicalDomain:db.canonicalDomain,evaluatedAt:db.evaluatedAt,
      workflowState:db.workflowState,lifecycleState:db.lifecycleState,
      authorityReady:db.authorityReady,reasonCode:db.reasonCode,nextRevalidationAt:db.nextRevalidationAt,r4Decision:db.commercialReality,r5Decision:db.routeAuthority,r6Decision:db.contactAuthority,truth:db.truth,
      structurallyOpenAccessPointCount:db.structurallyOpenAccessPointCount,authorisedAccessPointCount:db.authorisedAccessPointCount
    });
  }
  syncCompany(command:{organisationId:string;campaignId:string;companyId:string;requestId?:string;at?:string}){
    const at=(command.at?new Date(command.at):new Date()).toISOString();return this.repository.sync({...command,requestId:command.requestId??randomUUID(),at});
  }
  async listCampaign(command:{organisationId:string;campaignId:string;at?:string}){
    const at=(command.at?new Date(command.at):new Date()).toISOString();const profiles=await this.repository.list(command.organisationId,command.campaignId,at);
    return {profiles,paretoFrontier:opportunityParetoFrontier(profiles)};
  }
  async syncCurrentTargets(limit=250){const targets=await this.repository.syncTargets(limit);const results=[];const errors:{organisationId:string;campaignId:string;companyId:string;error:string}[]=[];for(const t of targets){try{results.push(await this.syncCompany({organisationId:t.organisation_id,campaignId:t.campaign_id,companyId:t.company_id}));}catch(error){errors.push({organisationId:t.organisation_id,campaignId:t.campaign_id,companyId:t.company_id,error:error instanceof Error?error.message:"MARKETROUTE_OPPORTUNITY_SYNC_UNKNOWN_FAILURE"});}}return {targetCount:targets.length,results,errors};}
}
export function opportunityServiceFromEnvironment(){return new OpportunityService(opportunityRepositoryFromEnvironment());}
