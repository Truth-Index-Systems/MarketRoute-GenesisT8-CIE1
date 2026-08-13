export const OPPORTUNITY_ENGINE_VERSION = "MRV2-OPPORTUNITY-ENGINE-1.0.0" as const;
export const OPPORTUNITY_SEMANTICS_VERSION = "MRV2-OPPORTUNITY-SEMANTICS-1.0.0" as const;

export type OpportunityWorkflowState = "RESEARCHING" | "REVIEWABLE" | "APPROVED" | "REJECTED" | "ENGAGED" | "ARCHIVED";
export type OpportunityLifecycleState =
  | "R4_REVALIDATION_REQUIRED" | "COMMERCIAL_RESEARCH_REQUIRED" | "NOT_ADMISSIBLE"
  | "R5_REVALIDATION_REQUIRED" | "ROUTE_RESEARCH_REQUIRED" | "ROUTE_NOT_APPLICABLE"
  | "R6_REVALIDATION_REQUIRED" | "CONTACT_RESEARCH_REQUIRED" | "CONTACT_NOT_APPLICABLE" | "AUTHORITY_READY";
export type OpportunityDisposition = "ACTIONABLE" | "RESEARCH_REQUIRED" | "REVALIDATION_REQUIRED" | "NOT_ADMISSIBLE" | "NOT_APPLICABLE";
export type OpportunityResearchPressure = "NONE" | "R4" | "R5" | "R6";
export type RouteRedundancy = "NONE" | "SINGLE" | "MULTIPLE";
export type ParetoRelation = "A_DOMINATES" | "B_DOMINATES" | "EQUIVALENT" | "INCOMPARABLE" | "NOT_COMPARABLE";

export interface OpportunityTruthDimensions {
  entityState: "KNOWN" | "SUPPORTED" | "PARTIAL" | "UNRESOLVED" | "CONTRADICTED" | "STALE" | null;
  currentCoverage: number | null;
  evidenceSufficiency: number | null;
  freshnessCoverage: number | null;
  coherence: number | null;
  truthIndex: number | null;
  probabilityState: "UNCALIBRATED" | null;
}

export interface OpportunityProfileInput {
  organisationId: string;
  campaignId: string;
  companyId: string;
  opportunityId?: string | null;
  companyName: string;
  canonicalDomain?: string | null;
  evaluatedAt: string;
  workflowState: OpportunityWorkflowState | null;
  lifecycleState: OpportunityLifecycleState;
  authorityReady: boolean;
  reasonCode: string;
  nextRevalidationAt?: string | null;
  r4Decision?: string | null;
  r5Decision?: string | null;
  r6Decision?: string | null;
  truth: OpportunityTruthDimensions;
  structurallyOpenAccessPointCount: number;
  authorisedAccessPointCount: number;
}

export interface OpportunityProfile {
  engineVersion: typeof OPPORTUNITY_ENGINE_VERSION;
  semanticsVersion: typeof OPPORTUNITY_SEMANTICS_VERSION;
  organisationId: string;
  campaignId: string;
  companyId: string;
  opportunityId: string | null;
  companyName: string;
  canonicalDomain: string | null;
  evaluatedAt: string;
  workflowState: OpportunityWorkflowState | null;
  lifecycleState: OpportunityLifecycleState;
  disposition: OpportunityDisposition;
  researchPressure: OpportunityResearchPressure;
  authorityReady: boolean;
  reviewableNow: boolean;
  executableNow: boolean;
  reasonCode: string;
  nextRevalidationAt: string | null;
  commercialReality: string | null;
  routeAuthority: string | null;
  contactAuthority: string | null;
  truth: OpportunityTruthDimensions;
  structurallyOpenAccessPointCount: number;
  authorisedAccessPointCount: number;
  routeRedundancy: RouteRedundancy;
}
