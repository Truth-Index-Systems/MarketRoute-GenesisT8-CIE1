import { PostgrestRpcClient, databaseConfigFromEnvironment } from "./postgrest-rpc";

export interface EngagementGenerationContextRow {
  contextFingerprint: string;
  context: {
    opportunityId:string; organisationId:string; campaignId:string; companyId:string; companyName:string; canonicalDomain:string|null;
    pathFingerprint:string; accessPointId:string; accessPointKind:string; accessPointValue:string; routeMode:"ORGANISATIONAL_ROUTE"|"NAMED_CONTACT";
    personId:string|null; personName:string|null; sellerObjectiveKey:string; sellerObjectiveStatement:string|null; sellerOfferingLabels:string[]; sellerOfferings:Array<{offeringKey:string;label:string;description:string|null}>; commercialBoundaryFacts:Array<{boundaryKey:string;claimKey:string;observedValue:string}>;
    authorityEnvelopeFingerprint:string; r6AuthorityRecordId:string; r6AuthorityFingerprint:string; evaluatedAt:string; executableNow:boolean;
  };
}
export interface EngagementStrategyRow { strategy_id:string; strategy_fingerprint:string; channel_kind:"EMAIL"|"CONTACT_FORM"|"LINKEDIN"|"PHONE"|"OTHER"; deduplicated:boolean; }
export interface EngagementMessageRow { message_id:string; message_fingerprint:string; deduplicated:boolean; }
export interface EngagementReviewRow { review_id:string; verdict:"PASS"|"REWRITE"|"BLOCK"; review_fingerprint:string; deduplicated:boolean; }
export interface EngagementApprovalRow { approval_id:string; decision:"APPROVE"|"REJECT"; approval_mode:"HUMAN"; deduplicated:boolean; }
export interface EngagementQueueRow { queue_item_id:string; job_id:string; approval_mode:"HUMAN"|"AUTOPILOT"; deduplicated:boolean; }
export interface EngagementClaimRow { queue_item_id:string; job_id:string; attempt_number:number; send_gate_fingerprint:string; delivery_payload:{queueItemId:string;idempotencyKey:string;channel:"EMAIL"|"CONTACT_FORM"|"LINKEDIN"|"PHONE"|"OTHER";accessPointValue:string;subjectText:string|null;bodyText:string}; }

function one<T>(v:T[]|T,code:string):T {if(Array.isArray(v)){if(v.length!==1)throw new Error(`${code}:${v.length}`);return v[0]!;}if(!v)throw new Error(`${code}:0`);return v;}

export class EngagementRepository {
  constructor(private readonly rpc:PostgrestRpcClient){}
  static fromEnvironment(){return new EngagementRepository(new PostgrestRpcClient(databaseConfigFromEnvironment()));}
  async generationContext(opportunityId:string,pathFingerprint:string,at:string):Promise<EngagementGenerationContextRow>{
    const context=await this.rpc.call<EngagementGenerationContextRow["context"]>("marketroute_engagement_generation_context_v1",{p_opportunity_id:opportunityId,p_path_fingerprint:pathFingerprint,p_at:at});
    const contextFingerprint=await this.rpc.call<string>("marketroute_engagement_generation_context_fingerprint_v1",{p_context:context});
    return {contextFingerprint,context};
  }
  async createStrategy(input:{opportunityId:string;pathFingerprint:string;requestId:string;contextFingerprint:string;strategyFingerprint:string;strategyVersion:string;at:string}){
    return one(await this.rpc.call<EngagementStrategyRow[]|EngagementStrategyRow>("marketroute_create_engagement_strategy_v1",{p_opportunity_id:input.opportunityId,p_path_fingerprint:input.pathFingerprint,p_request_id:input.requestId,p_context_fingerprint:input.contextFingerprint,p_strategy_fingerprint:input.strategyFingerprint,p_strategy_version:input.strategyVersion,p_at:input.at}),"MARKETROUTE_ENGAGEMENT_STRATEGY_ROW_COUNT");
  }
  async persistMessage(input:{strategyId:string;previousMessageId?:string|null;requestId:string;contextFingerprint:string;generationContractVersion:string;generatorVersion:string;subjectText:string|null;bodyText:string;messageFingerprint?:string;at:string}){
    return one(await this.rpc.call<EngagementMessageRow[]|EngagementMessageRow>("marketroute_record_engagement_message_v1",{p_strategy_id:input.strategyId,p_previous_message_id:input.previousMessageId??null,p_request_id:input.requestId,p_context_fingerprint:input.contextFingerprint,p_generation_contract_version:input.generationContractVersion,p_generator_version:input.generatorVersion,p_subject_text:input.subjectText,p_body_text:input.bodyText,p_at:input.at}),"MARKETROUTE_ENGAGEMENT_MESSAGE_ROW_COUNT");
  }
  async persistReview(input:{messageId:string;requestId:string;reviewContractVersion:string;reviewerVersion:string;verdict:string;reasonCodes:string[];diagnostics:Record<string,unknown>;at:string}){
    return one(await this.rpc.call<EngagementReviewRow[]|EngagementReviewRow>("marketroute_record_engagement_ai_review_v1",{p_message_id:input.messageId,p_request_id:input.requestId,p_review_contract_version:input.reviewContractVersion,p_reviewer_version:input.reviewerVersion,p_verdict:input.verdict,p_reason_codes:input.reasonCodes,p_diagnostics_json:input.diagnostics,p_at:input.at}),"MARKETROUTE_ENGAGEMENT_REVIEW_ROW_COUNT");
  }
  async setPolicy(input:{organisationId:string;campaignId:string;actorUserId:string;mode:"HUMAN_ONLY"|"AUTOPILOT";requestId:string;at:string}){
    return this.rpc.call("marketroute_record_engagement_policy_v1",{p_organisation_id:input.organisationId,p_campaign_id:input.campaignId,p_actor_user_id:input.actorUserId,p_policy_mode:input.mode,p_request_id:input.requestId,p_at:input.at});
  }
  async approveMessage(input:{messageId:string;actorUserId:string;decision:"APPROVE"|"REJECT";requestId:string;at:string}){
    return one(await this.rpc.call<EngagementApprovalRow[]|EngagementApprovalRow>("marketroute_record_engagement_message_approval_v1",{p_message_id:input.messageId,p_actor_user_id:input.actorUserId,p_decision:input.decision,p_request_id:input.requestId,p_at:input.at}),"MARKETROUTE_ENGAGEMENT_APPROVAL_ROW_COUNT");
  }
  async queue(input:{messageId:string;requestId:string;at:string}){
    return one(await this.rpc.call<EngagementQueueRow[]|EngagementQueueRow>("marketroute_queue_engagement_v1",{p_message_id:input.messageId,p_request_id:input.requestId,p_at:input.at}),"MARKETROUTE_ENGAGEMENT_QUEUE_ROW_COUNT");
  }
  async claimDelivery(input:{workerId:string;at:string}){
    const rows=await this.rpc.call<EngagementClaimRow[]>("marketroute_claim_engagement_delivery_v1",{p_worker_id:input.workerId,p_at:input.at});return rows[0]??null;
  }
  completeDelivery(input:{queueItemId:string;workerId:string;providerMessageId:string|null;metadata:Record<string,unknown>;at:string}){
    return this.rpc.call("marketroute_complete_engagement_delivery_v1",{p_queue_item_id:input.queueItemId,p_worker_id:input.workerId,p_provider_message_id:input.providerMessageId,p_provider_metadata_json:input.metadata,p_at:input.at});
  }
  failDelivery(input:{queueItemId:string;workerId:string;errorCode:string;deliveryStateUnknown:boolean;at:string}){
    return this.rpc.call("marketroute_fail_engagement_delivery_v1",{p_queue_item_id:input.queueItemId,p_worker_id:input.workerId,p_error_code:input.errorCode,p_delivery_state_unknown:input.deliveryStateUnknown,p_at:input.at});
  }
}
export function engagementRepositoryFromEnvironment(){return EngagementRepository.fromEnvironment();}
