import type { SellerGenomeSemanticPayload } from "../seller-genome/contracts.js";
import type { TruthState } from "../truth/contracts.js";

export const COMMERCIAL_REALITY_ENGINE_VERSION = "MRV2-R4-1.0.0" as const;
export const COMMERCIAL_REALITY_SEMANTICS_VERSION = "MRV2-R4-SEM-1.0.0" as const;
export const COMMERCIAL_REALITY_BOUNDARY_CONSTITUTION_VERSION = "MRV2-R4-BOUNDARIES-1.0.0" as const;
export const COMMERCIAL_REALITY_REALITY_CLASS = "SELLER_TO_TARGET_COMMERCIAL_ENGAGEMENT_V1" as const;
export const COMMERCIAL_REALITY_WRITER_KEY = "marketroute.r4.commercial-reality" as const;
export const COMMERCIAL_REALITY_WRITER_VERSION = "1.0.0" as const;
export const COMMERCIAL_REALITY_MAX_AUTHORITY_HOURS = 24 as const;

export type CommercialRealityDecision = "COMMERCIAL_CANDIDATE" | "RESEARCH_REQUIRED" | "NOT_ADMISSIBLE";
export type CommercialBoundaryState = "SATISFIED" | "UNSATISFIED" | "UNRESOLVED" | "CONTRADICTED" | "STALE";
export type CommercialBoundaryCategory = "MANDATORY" | "HARD_CONSTRAINT";

export interface CommercialRealityTruthSnapshot {
  snapshotId: string;
  snapshotFingerprint: string;
  claimId: string;
  claimKey: string;
  propositionFingerprint: string;
  truthState: TruthState;
  canonicalValueText: string | null;
  objectJson: unknown;
  nextRevalidationAt: string | null;
}

export interface CommercialRealityTargetTruth {
  entitySnapshotId: string;
  entitySnapshotFingerprint: string;
  entityState: "KNOWN" | "SUPPORTED" | "PARTIAL" | "UNRESOLVED" | "CONTRADICTED" | "STALE";
  nextRevalidationAt: string | null;
  coreClaims: Record<string, CommercialRealityTruthSnapshot[]>;
  constraintClaims: Record<string, CommercialRealityTruthSnapshot[]>;
}

export interface CommercialRealitySellerContext {
  selectionId: string;
  semanticContextFingerprint: string;
  semanticCompleteness: "COMPLETE" | "PARTIAL";
  objectiveKey: string;
  semantic: SellerGenomeSemanticPayload;
}

export interface CommercialRealityContext {
  organisationId: string;
  campaignId: string;
  companyId: string;
  referenceTime: string;
  seller: CommercialRealitySellerContext;
  targetTruth: CommercialRealityTargetTruth;
}

export interface HardConstraintRequirement {
  constraintKey: string;
  constraintType: string;
  claimKey: string | null;
  allowedValues: string[];
  supported: boolean;
}

export interface CommercialBoundaryEvaluation {
  boundaryKey: string;
  category: CommercialBoundaryCategory;
  required: true;
  state: CommercialBoundaryState;
  reasonCode: string;
  claimKey: string | null;
  observedValue: string | null;
  expectedValues: string[];
  sourceFingerprints: string[];
  nextRevalidationAt: string | null;
}

export interface CommercialRealityEvaluation {
  engineVersion: typeof COMMERCIAL_REALITY_ENGINE_VERSION;
  semanticsVersion: typeof COMMERCIAL_REALITY_SEMANTICS_VERSION;
  boundaryConstitutionVersion: typeof COMMERCIAL_REALITY_BOUNDARY_CONSTITUTION_VERSION;
  realityClass: typeof COMMERCIAL_REALITY_REALITY_CLASS;
  writerKey: typeof COMMERCIAL_REALITY_WRITER_KEY;
  writerVersion: typeof COMMERCIAL_REALITY_WRITER_VERSION;
  organisationId: string;
  campaignId: string;
  companyId: string;
  referenceTime: string;
  decision: CommercialRealityDecision;
  boundaries: CommercialBoundaryEvaluation[];
  nextRevalidationAt: string;
  diagnosticInputFingerprint: string;
}
