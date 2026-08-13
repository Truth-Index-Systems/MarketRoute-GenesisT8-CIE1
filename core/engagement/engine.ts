import { sha256Hex } from "../evidence/index.js";
import {
  ENGAGEMENT_ENGINE_VERSION,
  ENGAGEMENT_STRATEGY_VERSION,
  type CanonicalEngagementMessage,
  type CanonicalEngagementReview,
  type EngagementChannel,
  type EngagementMessageCandidate,
  type EngagementQueueEligibilityInput,
  type EngagementReviewCandidate,
  type EngagementStrategy,
  type EngagementStrategyContext,
} from "./contracts.js";

const REASON_CODE = /^[A-Z0-9][A-Z0-9_:-]{0,95}$/;
const FORBIDDEN_DIAGNOSTIC_KEY = /(authority|executionpermission|commercialviability|routeauthority|contactauthority)/i;

function text(value: string, code: string, max: number): string {
  const v = value.normalize("NFKC").replace(/\r\n?/g, "\n").trim();
  if (!v || v.length > max) throw new Error(code);
  return v;
}
function optionalText(value: string | null | undefined, code: string, max: number): string | null {
  if (value == null) return null;
  const v = value.normalize("NFKC").replace(/\r\n?/g, "\n").trim();
  if (!v) return null;
  if (v.length > max) throw new Error(code);
  return v;
}

export function engagementChannelForAccessPointKind(kind: string): EngagementChannel {
  switch (kind) {
    case "GENERIC_EMAIL": case "DEPARTMENT_EMAIL": case "PERSONAL_EMAIL": return "EMAIL";
    case "CONTACT_FORM": case "DEPARTMENT_FORM": return "CONTACT_FORM";
    case "LINKEDIN": return "LINKEDIN";
    case "SWITCHBOARD": case "PERSONAL_PHONE": return "PHONE";
    case "OTHER": return "OTHER";
    default: throw new Error("MARKETROUTE_ENGAGEMENT_ACCESS_POINT_KIND_UNSUPPORTED");
  }
}

export function buildEngagementStrategy(context: EngagementStrategyContext): EngagementStrategy {
  if (!context.executableNow) throw new Error("MARKETROUTE_ENGAGEMENT_STRATEGY_REQUIRES_EXECUTABLE_OPPORTUNITY");
  if (!/^[a-f0-9]{64}$/.test(context.pathFingerprint)) throw new Error("MARKETROUTE_ENGAGEMENT_PATH_FINGERPRINT_INVALID");
  if (!/^[a-f0-9]{64}$/.test(context.authorityEnvelopeFingerprint)) throw new Error("MARKETROUTE_ENGAGEMENT_ENVELOPE_FINGERPRINT_INVALID");
  if (!/^[a-f0-9]{64}$/.test(context.r6AuthorityFingerprint)) throw new Error("MARKETROUTE_ENGAGEMENT_R6_FINGERPRINT_INVALID");
  const at = Date.parse(context.evaluatedAt); if (!Number.isFinite(at)) throw new Error("MARKETROUTE_ENGAGEMENT_EVALUATED_AT_INVALID");
  const channel = engagementChannelForAccessPointKind(context.accessPointKind);
  const accessPointValue = text(context.accessPointValue, "MARKETROUTE_ENGAGEMENT_ACCESS_POINT_VALUE_INVALID", 2048);
  if (context.routeMode === "NAMED_CONTACT" && !context.personId) throw new Error("MARKETROUTE_ENGAGEMENT_NAMED_ROUTE_PERSON_REQUIRED");
  if (context.routeMode === "ORGANISATIONAL_ROUTE" && context.personId) throw new Error("MARKETROUTE_ENGAGEMENT_ORGANISATIONAL_ROUTE_PERSON_FORBIDDEN");
  const semantic = {
    version: ENGAGEMENT_STRATEGY_VERSION,
    opportunityId: context.opportunityId,
    organisationId: context.organisationId,
    campaignId: context.campaignId,
    companyId: context.companyId,
    pathFingerprint: context.pathFingerprint,
    accessPointId: context.accessPointId,
    channel,
    routeMode: context.routeMode,
    accessPointValue,
    personId: context.personId,
    authorityEnvelopeFingerprint: context.authorityEnvelopeFingerprint,
    r6AuthorityRecordId: context.r6AuthorityRecordId,
    r6AuthorityFingerprint: context.r6AuthorityFingerprint,
  };
  return {
    engineVersion: ENGAGEMENT_ENGINE_VERSION,
    strategyVersion: ENGAGEMENT_STRATEGY_VERSION,
    ...semantic,
    strategyFingerprint: sha256Hex(["MRV2-ENGAGEMENT-STRATEGY-FINGERPRINT-1.0.0",semantic.opportunityId,semantic.organisationId,semantic.campaignId,semantic.companyId,semantic.pathFingerprint,semantic.accessPointId,semantic.channel,semantic.routeMode,semantic.accessPointValue,semantic.personId??"NONE",semantic.authorityEnvelopeFingerprint,semantic.r6AuthorityRecordId,semantic.r6AuthorityFingerprint].join("|")),
  };
}

export function canonicaliseEngagementMessage(channel: EngagementChannel, candidate: EngagementMessageCandidate): CanonicalEngagementMessage {
  const bodyText = text(candidate.bodyText, "MARKETROUTE_ENGAGEMENT_BODY_INVALID", 8000);
  const subjectText = optionalText(candidate.subjectText, "MARKETROUTE_ENGAGEMENT_SUBJECT_INVALID", 300);
  if (channel === "EMAIL" && !subjectText) throw new Error("MARKETROUTE_ENGAGEMENT_EMAIL_SUBJECT_REQUIRED");
  if (channel !== "EMAIL" && subjectText) throw new Error("MARKETROUTE_ENGAGEMENT_NON_EMAIL_SUBJECT_FORBIDDEN");
  return { subjectText, bodyText };
}

export function engagementMessageFingerprint(strategyFingerprint: string, message: CanonicalEngagementMessage): string {
  if (!/^[a-f0-9]{64}$/.test(strategyFingerprint)) throw new Error("MARKETROUTE_ENGAGEMENT_STRATEGY_FINGERPRINT_INVALID");
  return sha256Hex(`MRV2-ENGAGEMENT-MESSAGE-DIAGNOSTIC-1.0.0|${strategyFingerprint}|${message.subjectText??""}|${message.bodyText}`);
}

export function canonicaliseEngagementReview(candidate: EngagementReviewCandidate): CanonicalEngagementReview {
  if (!(["PASS", "REWRITE", "BLOCK"] as const).includes(candidate.verdict)) throw new Error("MARKETROUTE_ENGAGEMENT_REVIEW_VERDICT_INVALID");
  const reasonCodes = [...new Set(candidate.reasonCodes.map(v => v.normalize("NFKC").trim().toUpperCase()))].sort();
  if (reasonCodes.some(v => !REASON_CODE.test(v))) throw new Error("MARKETROUTE_ENGAGEMENT_REVIEW_REASON_INVALID");
  if (candidate.verdict !== "PASS" && reasonCodes.length === 0) throw new Error("MARKETROUTE_ENGAGEMENT_NONPASS_REASON_REQUIRED");
  const diagnostics: Record<string, string | number | boolean | null> = {};
  for (const [key, value] of Object.entries(candidate.diagnostics ?? {}).sort(([a], [b]) => a.localeCompare(b))) {
    if (!/^[A-Za-z][A-Za-z0-9_.-]{0,79}$/.test(key) || FORBIDDEN_DIAGNOSTIC_KEY.test(key)) throw new Error("MARKETROUTE_ENGAGEMENT_DIAGNOSTIC_KEY_INVALID");
    if (!(value === null || typeof value === "string" || typeof value === "boolean" || (typeof value === "number" && Number.isFinite(value)))) throw new Error("MARKETROUTE_ENGAGEMENT_DIAGNOSTIC_VALUE_INVALID");
    diagnostics[key] = value;
  }
  return { verdict: candidate.verdict, reasonCodes, diagnostics };
}

export function engagementReviewAllowsProgress(review: CanonicalEngagementReview): boolean {
  return review.verdict === "PASS";
}

export function engagementQueueEligible(input: EngagementQueueEligibilityInput): boolean {
  if (!input.opportunityExecutableNow || !input.strategyCurrent || input.reviewVerdict !== "PASS") return false;
  return input.policyMode === "AUTOPILOT" || input.humanApprovalDecision === "APPROVE";
}
