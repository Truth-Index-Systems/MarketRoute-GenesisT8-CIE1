export const ENGAGEMENT_ENGINE_VERSION = "MRV2-ENGAGEMENT-ENGINE-1.0.0" as const;
export const ENGAGEMENT_STRATEGY_VERSION = "MRV2-ENGAGEMENT-STRATEGY-1.0.0" as const;
export const ENGAGEMENT_GENERATION_CONTRACT_VERSION = "MRV2-ENGAGEMENT-GENERATION-1.0.0" as const;
export const ENGAGEMENT_REVIEW_CONTRACT_VERSION = "MRV2-ENGAGEMENT-REVIEW-1.0.0" as const;
export const ENGAGEMENT_POLICY_VERSION = "MRV2-ENGAGEMENT-POLICY-1.0.0" as const;
export const ENGAGEMENT_DELIVERY_CONTRACT_VERSION = "MRV2-ENGAGEMENT-DELIVERY-1.0.0" as const;
export const ENGAGEMENT_MAX_REWRITES = 2 as const;

export type EngagementChannel = "EMAIL" | "CONTACT_FORM" | "LINKEDIN" | "PHONE" | "OTHER";
export type EngagementRouteMode = "ORGANISATIONAL_ROUTE" | "NAMED_CONTACT";
export type EngagementPolicyMode = "HUMAN_ONLY" | "AUTOPILOT";
export type EngagementReviewVerdict = "PASS" | "REWRITE" | "BLOCK";
export type EngagementApprovalDecision = "APPROVE" | "REJECT";

export interface EngagementStrategyContext {
  opportunityId: string;
  organisationId: string;
  campaignId: string;
  companyId: string;
  companyName: string;
  canonicalDomain: string | null;
  pathFingerprint: string;
  accessPointId: string;
  accessPointKind: string;
  accessPointValue: string;
  routeMode: EngagementRouteMode;
  personId: string | null;
  personName: string | null;
  sellerObjectiveKey: string;
  sellerObjectiveStatement: string | null;
  sellerOfferingLabels: string[];
  sellerOfferings: Array<{ offeringKey: string; label: string; description: string | null }>;
  commercialBoundaryFacts: Array<{ boundaryKey: string; claimKey: string; observedValue: string }>;
  authorityEnvelopeFingerprint: string;
  r6AuthorityRecordId: string;
  r6AuthorityFingerprint: string;
  evaluatedAt: string;
  executableNow: boolean;
}

export interface EngagementStrategy {
  engineVersion: typeof ENGAGEMENT_ENGINE_VERSION;
  strategyVersion: typeof ENGAGEMENT_STRATEGY_VERSION;
  opportunityId: string;
  organisationId: string;
  campaignId: string;
  companyId: string;
  pathFingerprint: string;
  accessPointId: string;
  channel: EngagementChannel;
  routeMode: EngagementRouteMode;
  accessPointValue: string;
  personId: string | null;
  authorityEnvelopeFingerprint: string;
  r6AuthorityRecordId: string;
  r6AuthorityFingerprint: string;
  strategyFingerprint: string;
}

export interface EngagementMessageCandidate {
  subjectText?: string | null;
  bodyText: string;
}

export interface CanonicalEngagementMessage {
  subjectText: string | null;
  bodyText: string;
}

export type EngagementDiagnosticValue = string | number | boolean | null;
export interface EngagementReviewCandidate {
  verdict: EngagementReviewVerdict;
  reasonCodes: string[];
  diagnostics?: Record<string, EngagementDiagnosticValue>;
}

export interface CanonicalEngagementReview {
  verdict: EngagementReviewVerdict;
  reasonCodes: string[];
  diagnostics: Record<string, EngagementDiagnosticValue>;
}

export interface EngagementQueueEligibilityInput {
  opportunityExecutableNow: boolean;
  strategyCurrent: boolean;
  reviewVerdict: EngagementReviewVerdict;
  policyMode: EngagementPolicyMode;
  humanApprovalDecision?: EngagementApprovalDecision | null;
}
