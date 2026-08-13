import type { AcquisitionInput, EvidencePolarity, RawClaimInput, RawEvidenceInput, RawSourceInput } from "../evidence/contracts.js";
import type { RawRelationshipInput } from "../relationships/contracts.js";
import type { RawContactClaimInput } from "../contacts/contracts.js";
export const RESEARCH_PLANNER_VERSION = "MRV2-RESEARCH-PLANNER-1.0.0" as const;
export const RESEARCH_SEMANTICS_VERSION = "MRV2-RESEARCH-SEMANTICS-1.0.0" as const;
export const RESEARCH_PROVIDER_TIMEOUT_MS = 180_000 as const;

export type ResearchLayer = "R4" | "R5" | "R6";
export type ResearchTier = "DECISION_BLOCKER" | "CURRENTNESS_REPAIR" | "EXPIRING_SOON" | "ENRICHMENT";
export type ResearchAction =
  | "ACQUIRE_CLAIM_EVIDENCE"
  | "DISCOVER_ROUTE_STRUCTURE"
  | "RESEARCH_CONTACT_BINDING"
  | "REVALIDATE_R4"
  | "REVALIDATE_R5"
  | "REVALIDATE_R6";
export type ResearchSubjectType = "COMPANY" | "PERSON" | "RELATIONSHIP" | "CHANNEL" | "CAMPAIGN";

export interface ResearchGapCandidate {
  gapKey: string;
  layer: ResearchLayer;
  tier: ResearchTier;
  action: ResearchAction;
  subjectType: ResearchSubjectType;
  subjectId: string;
  claimKey?: string | null;
  reasonCode: string;
  queryHints?: string[];
  metadata?: Record<string, unknown>;
}

export interface ResearchBudgetPolicy {
  dailyBudgetUsd: number;
  maxJobCostUsd: number;
  maxConcurrentJobs: number;
  maxWorkUnitsPerPlan: number;
  refreshHorizonHours: number;
}

export interface ResearchBudgetSnapshot {
  spentTodayUsd: number;
  reservedTodayUsd: number;
  activeJobs: number;
}

export interface ResearchPlannerContext {
  organisationId: string;
  campaignId: string;
  companyId: string;
  referenceTime: string;
  lifecycleState: string;
  authorityEnvelopeFingerprint: string;
  gapSetFingerprint?: string;
  candidates: ResearchGapCandidate[];
  policy: ResearchBudgetPolicy;
  budget: ResearchBudgetSnapshot;
}

export interface ResearchWorkUnit {
  ordinal: number;
  gapKey: string;
  layer: ResearchLayer;
  tier: ResearchTier;
  action: ResearchAction;
  subjectType: ResearchSubjectType;
  subjectId: string;
  claimKey: string | null;
  reasonCode: string;
  queryHints: string[];
  costCeilingUsd: number;
  dedupeKey: string;
  payload: Record<string, unknown>;
}

export interface ResearchPlan {
  plannerVersion: typeof RESEARCH_PLANNER_VERSION;
  semanticsVersion: typeof RESEARCH_SEMANTICS_VERSION;
  organisationId: string;
  campaignId: string;
  companyId: string;
  referenceTime: string;
  lifecycleState: string;
  authorityEnvelopeFingerprint: string;
  gapSetFingerprint: string;
  planFingerprint: string;
  workUnits: ResearchWorkUnit[];
  budgetExhausted: boolean;
  concurrencyLimited: boolean;
}

export interface ClaimEvidenceFindingPayload {
  source: RawSourceInput; acquisition: AcquisitionInput; evidence: RawEvidenceInput; claim: RawClaimInput; polarity: EvidencePolarity;
}
export interface RelationshipEvidenceFindingPayload {
  relationship: RawRelationshipInput; source: RawSourceInput; acquisition: AcquisitionInput; evidence: Omit<RawEvidenceInput,"subjectType"|"subjectId"|"tenantScopeOrganisationId">; polarity: EvidencePolarity;
}
export interface ContactEvidenceFindingPayload {
  claim: RawContactClaimInput; source: RawSourceInput; acquisition: AcquisitionInput; evidence: Omit<RawEvidenceInput,"subjectType"|"subjectId"|"tenantScopeOrganisationId">; polarity: EvidencePolarity;
}
export type ResearchFinding =
  | { kind: "CLAIM_EVIDENCE"; payload: ClaimEvidenceFindingPayload }
  | { kind: "RELATIONSHIP_EVIDENCE"; payload: RelationshipEvidenceFindingPayload }
  | { kind: "CONTACT_EVIDENCE"; payload: ContactEvidenceFindingPayload };

export interface ResearchProviderResult {
  findings: ResearchFinding[];
  costUsd: number;
  metadata?: Record<string, unknown>;
}

export interface ResearchProviderExecutionContext { signal: AbortSignal; timeoutMs: number; }
export interface ResearchProvider {
  execute(unit: ResearchWorkUnit, context: ResearchProviderExecutionContext): Promise<ResearchProviderResult>;
}
