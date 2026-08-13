import { PostgrestRpcClient, databaseConfigFromEnvironment } from "./postgrest-rpc";

export type AuthorityLifecycleState =
  | "R4_REVALIDATION_REQUIRED" | "COMMERCIAL_RESEARCH_REQUIRED" | "NOT_ADMISSIBLE"
  | "R5_REVALIDATION_REQUIRED" | "ROUTE_RESEARCH_REQUIRED" | "ROUTE_NOT_APPLICABLE"
  | "R6_REVALIDATION_REQUIRED" | "CONTACT_RESEARCH_REQUIRED" | "CONTACT_NOT_APPLICABLE" | "AUTHORITY_READY";

export interface AuthorityEnvelopeLayer {
  current:boolean;
  decision:string|null;
  authorityRecordId:string|null;
  authorityFingerprint:string|null;
  parentAuthorityRecordId?:string|null;
  validUntil:string|null;
}
export interface AuthorityEnvelope {
  version:"MRV2-AUTHORITY-LIFECYCLE-1.0.0";
  organisationId:string; campaignId:string; companyId:string; evaluatedAt:string;
  lifecycleState:AuthorityLifecycleState; authorityReady:boolean; requiredLayer:"R4"|"R5"|"R6"|null; reasonCode:string;
  nextRevalidationAt:string|null;
  r4:AuthorityEnvelopeLayer; r5:AuthorityEnvelopeLayer; r6:AuthorityEnvelopeLayer;
}
export interface OpportunityReviewResult {
  review_id:string; workflow_event_id:string; prior_workflow_state:string; resulting_workflow_state:string;
  authority_envelope_fingerprint:string; executable_now:boolean; deduplicated:boolean;
}
function one<T>(v:T[]|T,code:string):T { if(Array.isArray(v)){if(v.length!==1)throw new Error(`${code}:${v.length}`);return v[0]!;} if(!v)throw new Error(`${code}:0`); return v; }

export class AuthorityLifecycleRepository {
  constructor(private readonly rpc:PostgrestRpcClient){}
  static fromEnvironment(){return new AuthorityLifecycleRepository(new PostgrestRpcClient(databaseConfigFromEnvironment()));}
  getEnvelope(input:{organisationId:string;campaignId:string;companyId:string;at:string}):Promise<AuthorityEnvelope>{
    return this.rpc.call("marketroute_authority_envelope_v1",{p_organisation_id:input.organisationId,p_campaign_id:input.campaignId,p_company_id:input.companyId,p_at:input.at});
  }
  isOpportunityExecutableNow(opportunityId:string,at:string):Promise<boolean>{
    return this.rpc.call("marketroute_opportunity_executable_now_v1",{p_opportunity_id:opportunityId,p_at:at});
  }
  async recordReview(input:{opportunityId:string;reviewerUserId:string;decision:"APPROVE"|"REJECT"|"RETURN_TO_RESEARCH";note?:string|null;requestId:string;reviewedAt:string}):Promise<OpportunityReviewResult>{
    const result=await this.rpc.call<OpportunityReviewResult[]|OpportunityReviewResult>("marketroute_record_opportunity_review_v1",{
      p_opportunity_id:input.opportunityId,p_reviewer_user_id:input.reviewerUserId,p_decision:input.decision,p_note:input.note??null,p_request_id:input.requestId,p_reviewed_at:input.reviewedAt
    }); return one(result,"MARKETROUTE_REVIEW_ROW_COUNT");
  }
}
export function authorityLifecycleRepositoryFromEnvironment(){return AuthorityLifecycleRepository.fromEnvironment();}
