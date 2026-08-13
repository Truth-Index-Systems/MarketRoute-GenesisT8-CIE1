import type { ContactAuthorityContext, ContactAuthorityEvaluation } from "../../core/contacts/index.js";
import { PostgrestRpcClient, databaseConfigFromEnvironment } from "./postgrest-rpc.js";

interface PersistRow { r6_record_id:string; authority_record_id:string; reasoning_run_id:string; reasoning_artifact_id:string; input_fingerprint:string; authority_fingerprint:string; valid_until:string; deduplicated:boolean; }
function one<T>(value:T[]|T,code:string):T {if(Array.isArray(value)){if(value.length!==1)throw new Error(`${code}:${value.length}`);return value[0]!;}if(!value)throw new Error(`${code}:0`);return value;}

export class ContactAuthorityRepository {
  constructor(private readonly rpc:PostgrestRpcClient){}
  static fromEnvironment(){return new ContactAuthorityRepository(new PostgrestRpcClient(databaseConfigFromEnvironment()));}
  getClaimIds(input:{organisationId:string;campaignId:string;companyId:string;referenceTime:string}):Promise<Record<string,string>>{
    return this.rpc.call("marketroute_get_r6_contact_claim_ids_v1",{p_organisation_id:input.organisationId,p_campaign_id:input.campaignId,p_company_id:input.companyId,p_reference_time:input.referenceTime});
  }
  getContext(input:{organisationId:string;campaignId:string;companyId:string;referenceTime:string;claimTruthSnapshotMap:Record<string,string>}):Promise<ContactAuthorityContext>{
    return this.rpc.call("marketroute_get_r6_context_v1",{p_organisation_id:input.organisationId,p_campaign_id:input.campaignId,p_company_id:input.companyId,p_reference_time:input.referenceTime,p_contact_truth_snapshot_map:input.claimTruthSnapshotMap});
  }
  async persist(e:ContactAuthorityEvaluation,claimTruthSnapshotMap:Record<string,string>):Promise<PersistRow>{
    const value=await this.rpc.call<PersistRow[]|PersistRow>("marketroute_persist_contact_authority_r6_v1",{
      p_organisation_id:e.organisationId,p_campaign_id:e.campaignId,p_company_id:e.companyId,p_reference_time:e.referenceTime,p_parent_authority_fingerprint:e.parentAuthorityFingerprint,p_contact_claim_universe_fingerprint:e.contactClaimUniverseFingerprint,p_contact_truth_snapshot_map:claimTruthSnapshotMap,p_engine_version:e.engineVersion,p_semantics_version:e.semanticsVersion,p_decision_code:e.decision,p_bindings_json:e.bindings,p_authorised_path_fingerprints:e.authorisedPathFingerprints,p_authorised_access_point_ids:e.authorisedAccessPointIds,p_research_required_access_point_ids:e.researchRequiredAccessPointIds,p_distinct_authorised_access_point_count:e.distinctAuthorisedAccessPointCount,p_next_revalidation_at:e.nextRevalidationAt
    });return one(value,"MARKETROUTE_R6_PERSIST_ROW_COUNT");
  }
}
export function contactAuthorityRepositoryFromEnvironment(){return ContactAuthorityRepository.fromEnvironment();}
