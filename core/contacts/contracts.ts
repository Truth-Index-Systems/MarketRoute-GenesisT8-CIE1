export const CONTACT_AUTHORITY_ENGINE_VERSION = "MRV2-R6-ENGINE-1.0.0" as const;
export const CONTACT_AUTHORITY_SEMANTICS_VERSION = "MRV2-R6-SEMANTICS-1.0.0" as const;
export const CONTACT_AUTHORITY_WRITER_KEY = "marketroute.r6.contact-truth" as const;
export const CONTACT_AUTHORITY_WRITER_VERSION = "1.0.0" as const;
export const CONTACT_AUTHORITY_MAX_HOURS = 8 as const;

export type ContactAuthorityDecision = "CONTACT_AUTHORISED" | "CONTACT_RESEARCH_REQUIRED" | "CONTACT_NOT_APPLICABLE";
export type ContactTruthState = "KNOWN" | "SUPPORTED" | "UNRESOLVED" | "CONTRADICTED" | "STALE";
export type ContactPathAuthorityState = "AUTHORISED" | "CONTACT_TRUTH_REQUIRED";
export type ContactPathMode = "ORGANISATIONAL_ROUTE" | "NAMED_CONTACT";
export type ContactClaimKind = "IDENTITY" | "CURRENT_EMPLOYMENT" | "CURRENT_ROLE" | "CHANNEL_OWNERSHIP";

export interface ContactClaimTruthRef {
  claimId: string;
  snapshotId: string;
  snapshotFingerprint: string;
  truthState: ContactTruthState;
  nextRevalidationAt: string | null;
  roleTitle?: string | null;
  canonicalValueText?: string | null;
  objectJson?: Record<string, unknown> | null;
}

export interface ContactPathContext {
  pathFingerprint: string;
  terminalAccessPointId: string;
  r5PathState: "ORGANISATIONAL_OPEN" | "CONTACT_TRUTH_REQUIRED";
  personId: string | null;
  expectedPersonName: string | null;
  personLifecycleState: "ACTIVE" | "MERGED" | "ARCHIVED" | null;
  employerCompanyId: string | null;
  accessPointKind: string | null;
  accessPointValue: string | null;
  identityClaims: ContactClaimTruthRef[];
  employmentClaims: ContactClaimTruthRef[];
  roleClaims: ContactClaimTruthRef[];
  channelOwnershipClaims: ContactClaimTruthRef[];
}

export interface ContactAuthorityContext {
  organisationId: string;
  campaignId: string;
  companyId: string;
  referenceTime: string;
  parentR5: {
    authorityRecordId: string;
    authorityFingerprint: string;
    decisionCode: "ROUTE_STRUCTURALLY_OPEN" | "ROUTE_RESEARCH_REQUIRED" | "ROUTE_NOT_APPLICABLE";
    validUntil: string;
    current: boolean;
  };
  contactClaimUniverseFingerprint: string;
  paths: ContactPathContext[];
}

export interface ContactPathBinding {
  pathFingerprint: string;
  terminalAccessPointId: string;
  mode: ContactPathMode;
  authorityState: ContactPathAuthorityState;
  personId: string | null;
  employerCompanyId: string | null;
  reasonCode: string;
}

export interface ContactAuthorityEvaluation {
  engineVersion: typeof CONTACT_AUTHORITY_ENGINE_VERSION;
  semanticsVersion: typeof CONTACT_AUTHORITY_SEMANTICS_VERSION;
  writerKey: typeof CONTACT_AUTHORITY_WRITER_KEY;
  writerVersion: typeof CONTACT_AUTHORITY_WRITER_VERSION;
  organisationId: string;
  campaignId: string;
  companyId: string;
  referenceTime: string;
  parentAuthorityFingerprint: string;
  contactClaimUniverseFingerprint: string;
  decision: ContactAuthorityDecision;
  bindings: ContactPathBinding[];
  authorisedPathFingerprints: string[];
  authorisedAccessPointIds: string[];
  researchRequiredAccessPointIds: string[];
  distinctAuthorisedAccessPointCount: number;
  nextRevalidationAt: string;
  diagnosticInputFingerprint: string;
}

export type RawContactClaimInput =
  | { kind: "IDENTITY"; tenantScopeOrganisationId?: string | null; personId: string; canonicalName: string }
  | { kind: "CURRENT_EMPLOYMENT"; tenantScopeOrganisationId?: string | null; personId: string; companyId: string }
  | { kind: "CURRENT_ROLE"; tenantScopeOrganisationId?: string | null; personId: string; companyId: string; roleTitle: string }
  | { kind: "CHANNEL_OWNERSHIP"; tenantScopeOrganisationId?: string | null; accessPointId: string; personId: string };
