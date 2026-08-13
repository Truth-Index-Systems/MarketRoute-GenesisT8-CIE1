export const AUTHORITY_LIFECYCLE_VERSION = "MRV2-AUTHORITY-LIFECYCLE-1.0.0" as const;

export type R4Decision = "COMMERCIAL_CANDIDATE" | "RESEARCH_REQUIRED" | "NOT_ADMISSIBLE";
export type R5Decision = "ROUTE_STRUCTURALLY_OPEN" | "ROUTE_RESEARCH_REQUIRED" | "ROUTE_NOT_APPLICABLE";
export type R6Decision = "CONTACT_AUTHORISED" | "CONTACT_RESEARCH_REQUIRED" | "CONTACT_NOT_APPLICABLE";

export type AuthorityLifecycleState =
  | "R4_REVALIDATION_REQUIRED"
  | "COMMERCIAL_RESEARCH_REQUIRED"
  | "NOT_ADMISSIBLE"
  | "R5_REVALIDATION_REQUIRED"
  | "ROUTE_RESEARCH_REQUIRED"
  | "ROUTE_NOT_APPLICABLE"
  | "R6_REVALIDATION_REQUIRED"
  | "CONTACT_RESEARCH_REQUIRED"
  | "CONTACT_NOT_APPLICABLE"
  | "AUTHORITY_READY";

export interface AuthorityLayerState<D extends string> {
  current: boolean;
  decision: D | null;
  authorityRecordId?: string | null;
  authorityFingerprint?: string | null;
  validUntil?: string | null;
}

export interface AuthorityEnvelopeInput {
  r4: AuthorityLayerState<R4Decision>;
  r5: AuthorityLayerState<R5Decision>;
  r6: AuthorityLayerState<R6Decision>;
}

export interface AuthorityEnvelopeEvaluation {
  version: typeof AUTHORITY_LIFECYCLE_VERSION;
  lifecycleState: AuthorityLifecycleState;
  authorityReady: boolean;
  requiredLayer: "R4" | "R5" | "R6" | null;
  reasonCode: string;
}

export function evaluateAuthorityEnvelope(input: AuthorityEnvelopeInput): AuthorityEnvelopeEvaluation {
  if (!input.r4.current || !input.r4.decision) {
    return {version:AUTHORITY_LIFECYCLE_VERSION,lifecycleState:"R4_REVALIDATION_REQUIRED",authorityReady:false,requiredLayer:"R4",reasonCode:"CURRENT_R4_REQUIRED"};
  }
  if (input.r4.decision === "NOT_ADMISSIBLE") {
    return {version:AUTHORITY_LIFECYCLE_VERSION,lifecycleState:"NOT_ADMISSIBLE",authorityReady:false,requiredLayer:null,reasonCode:"R4_NOT_ADMISSIBLE"};
  }
  if (input.r4.decision === "RESEARCH_REQUIRED") {
    return {version:AUTHORITY_LIFECYCLE_VERSION,lifecycleState:"COMMERCIAL_RESEARCH_REQUIRED",authorityReady:false,requiredLayer:"R4",reasonCode:"R4_RESEARCH_REQUIRED"};
  }
  if (!input.r5.current || !input.r5.decision) {
    return {version:AUTHORITY_LIFECYCLE_VERSION,lifecycleState:"R5_REVALIDATION_REQUIRED",authorityReady:false,requiredLayer:"R5",reasonCode:"CURRENT_R5_REQUIRED"};
  }
  if (input.r5.decision === "ROUTE_NOT_APPLICABLE") {
    return {version:AUTHORITY_LIFECYCLE_VERSION,lifecycleState:"ROUTE_NOT_APPLICABLE",authorityReady:false,requiredLayer:null,reasonCode:"R5_ROUTE_NOT_APPLICABLE"};
  }
  if (input.r5.decision === "ROUTE_RESEARCH_REQUIRED") {
    return {version:AUTHORITY_LIFECYCLE_VERSION,lifecycleState:"ROUTE_RESEARCH_REQUIRED",authorityReady:false,requiredLayer:"R5",reasonCode:"R5_RESEARCH_REQUIRED"};
  }
  if (!input.r6.current || !input.r6.decision) {
    return {version:AUTHORITY_LIFECYCLE_VERSION,lifecycleState:"R6_REVALIDATION_REQUIRED",authorityReady:false,requiredLayer:"R6",reasonCode:"CURRENT_R6_REQUIRED"};
  }
  if (input.r6.decision === "CONTACT_NOT_APPLICABLE") {
    return {version:AUTHORITY_LIFECYCLE_VERSION,lifecycleState:"CONTACT_NOT_APPLICABLE",authorityReady:false,requiredLayer:null,reasonCode:"R6_CONTACT_NOT_APPLICABLE"};
  }
  if (input.r6.decision === "CONTACT_RESEARCH_REQUIRED") {
    return {version:AUTHORITY_LIFECYCLE_VERSION,lifecycleState:"CONTACT_RESEARCH_REQUIRED",authorityReady:false,requiredLayer:"R6",reasonCode:"R6_RESEARCH_REQUIRED"};
  }
  return {version:AUTHORITY_LIFECYCLE_VERSION,lifecycleState:"AUTHORITY_READY",authorityReady:true,requiredLayer:null,reasonCode:"R4_R5_R6_CURRENT_AND_AUTHORISED"};
}

export type OpportunityWorkflowState = "RESEARCHING" | "REVIEWABLE" | "APPROVED" | "REJECTED" | "ENGAGED" | "ARCHIVED";

export function isOpportunityExecutableNow(workflowState: OpportunityWorkflowState, envelope: AuthorityEnvelopeEvaluation): boolean {
  return workflowState === "APPROVED" && envelope.authorityReady;
}
