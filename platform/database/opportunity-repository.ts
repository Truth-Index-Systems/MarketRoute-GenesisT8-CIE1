import type { OpportunityProfile } from "../../core/opportunities/index.js";
import { PostgrestRpcClient, databaseConfigFromEnvironment } from "./postgrest-rpc.js";

export interface OpportunitySyncResult {
  opportunity_id:string|null; outcome_code:"NOT_MATERIALISED"|"MATERIALISED_REVIEWABLE"|"BECAME_REVIEWABLE"|"BECAME_RESEARCHING"|"UNCHANGED"|"FOUNDER_RESEARCH_HOLD";
  prior_workflow_state:string|null; resulting_workflow_state:string|null; authority_envelope_fingerprint:string; reviewable_now:boolean; deduplicated:boolean;
}
export interface OpportunitySyncTarget { organisation_id:string; campaign_id:string; company_id:string; }
function one<T>(value:T[]|T,code:string):T {if(Array.isArray(value)){if(value.length!==1)throw new Error(`${code}:${value.length}`);return value[0]!;}if(!value)throw new Error(`${code}:0`);return value;}

export class OpportunityRepository {
  constructor(private readonly rpc:PostgrestRpcClient){}
  static fromEnvironment(){return new OpportunityRepository(new PostgrestRpcClient(databaseConfigFromEnvironment()));}
  profile(input:{organisationId:string;campaignId:string;companyId:string;at:string}):Promise<OpportunityProfile>{
    return this.rpc.call("marketroute_opportunity_profile_v1",{p_organisation_id:input.organisationId,p_campaign_id:input.campaignId,p_company_id:input.companyId,p_at:input.at});
  }
  async sync(input:{organisationId:string;campaignId:string;companyId:string;requestId:string;at:string}):Promise<OpportunitySyncResult>{
    const v=await this.rpc.call<OpportunitySyncResult[]|OpportunitySyncResult>("marketroute_sync_opportunity_v1",{p_organisation_id:input.organisationId,p_campaign_id:input.campaignId,p_company_id:input.companyId,p_request_id:input.requestId,p_at:input.at});
    return one(v,"MARKETROUTE_OPPORTUNITY_SYNC_ROW_COUNT");
  }
  syncTargets(limit=250):Promise<OpportunitySyncTarget[]>{return this.rpc.call("marketroute_opportunity_sync_targets_v1",{p_limit:limit});}
  list(organisationId:string,campaignId:string,at:string):Promise<OpportunityProfile[]>{return this.rpc.call("marketroute_list_opportunity_profiles_v1",{p_organisation_id:organisationId,p_campaign_id:campaignId,p_at:at});}
}
export function opportunityRepositoryFromEnvironment(){return OpportunityRepository.fromEnvironment();}
