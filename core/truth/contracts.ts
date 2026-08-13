export const TRUTH_ENGINE_VERSION = "MRV2-TRUTH-1.0.0" as const;
export const TRUTH_SEMANTICS_VERSION = "MRV2-TRUTH-SEM-1.0.0" as const;
export const TRUTH_ENTITY_AGGREGATION_VERSION = "MRV2-TRUTH-ENTITY-1.0.0" as const;

export type TruthState = "KNOWN" | "SUPPORTED" | "UNRESOLVED" | "CONTRADICTED" | "STALE";
export type TruthEntityState = "KNOWN" | "SUPPORTED" | "PARTIAL" | "UNRESOLVED" | "CONTRADICTED" | "STALE";
export type TruthProbabilityState = "UNCALIBRATED";
export type TruthEvidencePolarity = "SUPPORTS" | "CONTRADICTS";

export interface TruthClaimPolicy {
  policyKey: string;
  policyVersion: string;
  maxAgeDays: number;
  knownSupportFamilyRequirement: number;
}

export interface TruthEvidenceInput {
  evidenceItemId: string;
  evidenceFingerprint: string;
  polarity: TruthEvidencePolarity;
  dependenceFamilyKey: string;
  observedAt: string;
  originPublishedAt: string | null;
  sourcePublishedAt: string | null;
}

export interface TruthClaimContext {
  claimId: string;
  tenantScopeOrganisationId: string | null;
  subjectType: string;
  subjectId: string;
  claimKey: string;
  claimFingerprint: string;
  propositionFingerprint: string;
  referenceTime: string;
  contextFingerprint: string;
  policy: TruthClaimPolicy;
  evidence: TruthEvidenceInput[];
}

export interface TruthFamilyDiagnostic {
  dependenceFamilyKey: string;
  currentState: "SUPPORT" | "CONTRADICT" | "CONFLICT" | "NONE";
  currentEvidenceCount: number;
  staleEvidenceCount: number;
  nextExpiryAt: string | null;
  currentFreshness: number;
}

export interface TruthClaimEvaluation {
  engineVersion: typeof TRUTH_ENGINE_VERSION;
  semanticsVersion: typeof TRUTH_SEMANTICS_VERSION;
  claimId: string;
  claimKey: string;
  claimFingerprint: string;
  propositionFingerprint: string;
  subjectType: string;
  subjectId: string;
  tenantScopeOrganisationId: string | null;
  referenceTime: string;
  inputFingerprint: string;
  policy: TruthClaimPolicy;
  truthState: TruthState;
  currentSupportFamilyCount: number;
  currentContradictionFamilyCount: number;
  staleFamilyCount: number;
  temporalAnomalyCount: number;
  evidenceSufficiency: number;
  supportStrength: number;
  contradictionStrength: number;
  evidenceBalance: number;
  freshnessCoverage: number;
  truthProbability: null;
  probabilityState: TruthProbabilityState;
  nextRevalidationAt: string | null;
  familyDiagnostics: TruthFamilyDiagnostic[];
}

export interface TruthEntityProfile {
  profileKey: string;
  profileVersion: string;
  subjectType: string;
  requiredClaimKeys: string[];
}

export interface TruthEntityClaimInput {
  claimKey: string;
  evaluations: TruthClaimEvaluation[];
}

export interface TruthEntityEvaluation {
  aggregationVersion: typeof TRUTH_ENTITY_AGGREGATION_VERSION;
  semanticsVersion: typeof TRUTH_SEMANTICS_VERSION;
  subjectType: string;
  subjectId: string;
  referenceTime: string;
  profile: TruthEntityProfile;
  entityState: TruthEntityState;
  requiredClaimCount: number;
  knownClaimCount: number;
  supportedClaimCount: number;
  contradictedClaimCount: number;
  staleClaimCount: number;
  unresolvedClaimCount: number;
  coverage: number;
  currentCoverage: number;
  evidenceSufficiency: number;
  freshnessCoverage: number;
  coherence: number;
  truthIndex: number;
  truthProbability: null;
  probabilityState: TruthProbabilityState;
  nextRevalidationAt: string | null;
}
