export const EVIDENCE_NORMALISATION_VERSION = "MRV2-EVIDENCE-NORM-1.0.0" as const;
export const EVIDENCE_FINGERPRINT_VERSION = "MRV2-EVIDENCE-FP-1.0.0" as const;
export const CLAIM_FINGERPRINT_VERSION = "MRV2-CLAIM-FP-1.0.0" as const;
export const DEPENDENCE_FAMILY_VERSION = "MRV2-DEPENDENCE-1.0.0" as const;

export type SourceKind =
  | "WEB"
  | "DOCUMENT"
  | "API"
  | "REGISTRY"
  | "USER_PROVIDED"
  | "INTERNAL"
  | "OTHER";

export type AcquisitionMethod =
  | "WEB_FETCH"
  | "SEARCH_RESULT"
  | "API"
  | "IMPORT"
  | "USER_UPLOAD"
  | "MANUAL";

export type EvidenceSubjectType =
  | "COMPANY"
  | "PERSON"
  | "SELLER_BUSINESS"
  | "CAMPAIGN"
  | "RELATIONSHIP"
  | "CHANNEL"
  | "OTHER";

export type EvidenceKind =
  | "QUOTE"
  | "STRUCTURED_FIELD"
  | "OBSERVATION"
  | "DOCUMENT_SECTION"
  | "REGISTRY_RECORD"
  | "USER_ASSERTION"
  | "OTHER";

export type ExtractionMethod = "DETERMINISTIC" | "AI_EXTRACTED" | "USER_PROVIDED" | "MIGRATED";
export type EvidencePolarity = "SUPPORTS" | "CONTRADICTS";

export interface RawSourceInput {
  sourceKind: SourceKind;
  url?: string | null;
  publisherDomain?: string | null;
  title?: string | null;
  publishedAt?: string | null;
  stableLocator?: string | null;
  metadata?: Record<string, unknown>;
}

export interface AcquisitionInput {
  method: AcquisitionMethod;
  acquiredAt?: string | null;
  observedContentFingerprint?: string | null;
  httpStatus?: number | null;
  rawLocator?: string | null;
  parserVersion?: string | null;
  requestId?: string | null;
  metadata?: Record<string, unknown>;
}

export interface RawEvidenceInput {
  tenantScopeOrganisationId?: string | null;
  subjectType: EvidenceSubjectType;
  subjectId: string;
  evidenceKind: EvidenceKind;
  excerptText?: string | null;
  structuredValue?: unknown;
  observedAt?: string | null;
  originPublishedAt?: string | null;
  extractionMethod: ExtractionMethod;
  extractionVersion?: string | null;
}

export interface RawClaimInput {
  tenantScopeOrganisationId?: string | null;
  subjectType: EvidenceSubjectType;
  subjectId: string;
  claimKey: string;
  predicate: string;
  object: unknown;
  canonicalValueText?: string | null;
}

export interface CanonicalSource {
  sourceKind: SourceKind;
  canonicalUrl: string | null;
  publisherDomain: string | null;
  title: string | null;
  publishedAt: string | null;
  stableLocator: string;
  sourceIdentityFingerprint: string;
  dependenceFamilyKey: string;
  normalisationVersion: typeof EVIDENCE_NORMALISATION_VERSION;
  metadata: Record<string, unknown>;
}

export interface CanonicalEvidence {
  tenantScopeOrganisationId: string | null;
  subjectType: EvidenceSubjectType;
  subjectId: string;
  evidenceKind: EvidenceKind;
  excerptText: string | null;
  structuredValue: unknown | null;
  observedAt: string;
  originPublishedAt: string | null;
  extractionMethod: ExtractionMethod;
  extractionVersion: string | null;
  evidenceFingerprint: string;
  fingerprintVersion: typeof EVIDENCE_FINGERPRINT_VERSION;
}

export interface CanonicalClaim {
  tenantScopeOrganisationId: string | null;
  subjectType: EvidenceSubjectType;
  subjectId: string;
  claimKey: string;
  predicate: string;
  object: unknown;
  canonicalValueText: string | null;
  claimFingerprint: string;
  fingerprintVersion: typeof CLAIM_FINGERPRINT_VERSION;
}

export interface EvidenceEnvelope {
  source: CanonicalSource;
  acquisition: AcquisitionInput;
  evidence: CanonicalEvidence;
}
