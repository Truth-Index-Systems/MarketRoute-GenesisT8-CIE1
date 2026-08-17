import { sha256Hex, stableJson } from "../evidence/index";
import {
  RESEARCH_PLANNER_VERSION,
  RESEARCH_SEMANTICS_VERSION,
  type ResearchGapCandidate,
  type ResearchOrigin,
  type ResearchPlan,
  type ResearchPlannerContext,
  type ResearchTier,
  type ResearchWorkUnit,
} from "./contracts";

const TIER_ORDER: Record<ResearchTier, number> = {
  DECISION_BLOCKER: 0,
  CURRENTNESS_REPAIR: 1,
  EXPIRING_SOON: 2,
  ENRICHMENT: 3,
};
const ACTION_ORDER: Record<string, number> = {
  REVALIDATE_R4: 0,
  ACQUIRE_CLAIM_EVIDENCE: 1,
  REVALIDATE_R5: 2,
  DISCOVER_ROUTE_STRUCTURE: 3,
  REVALIDATE_R6: 4,
  RESEARCH_CONTACT_BINDING: 5,
};

function positiveMoney(value: number, code: string): number {
  if (!Number.isFinite(value) || value < 0) throw new Error(code);
  return Math.round(value * 1e8) / 1e8;
}
function positiveInteger(value: number, code: string): number {
  if (!Number.isInteger(value) || value < 0) throw new Error(code);
  return value;
}
function normalHints(values: string[] | undefined): string[] {
  return [...new Set((values ?? []).map((v) => v.normalize("NFKC").trim()).filter(Boolean))].sort();
}

function researchOrigin(candidate: ResearchGapCandidate): ResearchOrigin {
  return candidate.tier === "CURRENTNESS_REPAIR" || candidate.tier === "EXPIRING_SOON"
    ? "CUSTOMER_REFRESH"
    : "CUSTOMER_CAMPAIGN";
}

function canonicalCandidate(candidate: ResearchGapCandidate): ResearchGapCandidate {
  if (!candidate.gapKey.trim() || !candidate.subjectId.trim() || !candidate.reasonCode.trim()) throw new Error("MARKETROUTE_RESEARCH_GAP_IDENTITY_REQUIRED");
  return {
    ...candidate,
    gapKey: candidate.gapKey.normalize("NFKC").trim(),
    subjectId: candidate.subjectId.normalize("NFKC").trim(),
    claimKey: candidate.claimKey?.normalize("NFKC").trim() || null,
    reasonCode: candidate.reasonCode.normalize("NFKC").trim().toUpperCase(),
    queryHints: normalHints(candidate.queryHints),
    metadata: candidate.metadata ?? {},
  };
}

export function planResearch(context: ResearchPlannerContext): ResearchPlan {
  const reference = new Date(context.referenceTime);
  if (Number.isNaN(reference.getTime())) throw new Error("MARKETROUTE_RESEARCH_REFERENCE_TIME_INVALID");
  const policy = {
    dailyBudgetUsd: positiveMoney(context.policy.dailyBudgetUsd, "MARKETROUTE_RESEARCH_DAILY_BUDGET_INVALID"),
    maxJobCostUsd: positiveMoney(context.policy.maxJobCostUsd, "MARKETROUTE_RESEARCH_JOB_BUDGET_INVALID"),
    maxConcurrentJobs: positiveInteger(context.policy.maxConcurrentJobs, "MARKETROUTE_RESEARCH_CONCURRENCY_INVALID"),
    maxWorkUnitsPerPlan: positiveInteger(context.policy.maxWorkUnitsPerPlan, "MARKETROUTE_RESEARCH_PLAN_LIMIT_INVALID"),
    refreshHorizonHours: positiveInteger(context.policy.refreshHorizonHours, "MARKETROUTE_RESEARCH_REFRESH_HORIZON_INVALID"),
  };
  const spent = positiveMoney(context.budget.spentTodayUsd, "MARKETROUTE_RESEARCH_SPEND_INVALID");
  const reserved = positiveMoney(context.budget.reservedTodayUsd, "MARKETROUTE_RESEARCH_RESERVED_INVALID");
  const active = positiveInteger(context.budget.activeJobs, "MARKETROUTE_RESEARCH_ACTIVE_JOBS_INVALID");
  const remainingBudget = Math.max(0, policy.dailyBudgetUsd - spent - reserved);
  const availableSlots = Math.max(0, policy.maxConcurrentJobs - active);
  const maxUnits = Math.min(policy.maxWorkUnitsPerPlan, availableSlots);

  const byGap = new Map<string, ResearchGapCandidate>();
  for (const raw of context.candidates) {
    const c = canonicalCandidate(raw);
    const prior = byGap.get(c.gapKey);
    if (prior && stableJson(prior) !== stableJson(c)) throw new Error("MARKETROUTE_RESEARCH_GAP_KEY_COLLISION");
    byGap.set(c.gapKey, c);
  }
  const candidates = [...byGap.values()].sort((a, b) =>
    TIER_ORDER[a.tier] - TIER_ORDER[b.tier]
    || (ACTION_ORDER[a.action] ?? 99) - (ACTION_ORDER[b.action] ?? 99)
    || a.layer.localeCompare(b.layer)
    || a.gapKey.localeCompare(b.gapKey)
  );
  const gapSetFingerprint = context.gapSetFingerprint ?? sha256Hex(`MRV2-RESEARCH-GAP-SET-1.0.0|${stableJson(candidates)}`);

  let remaining = remainingBudget;
  const workUnits: ResearchWorkUnit[] = [];
  for (const candidate of candidates) {
    if (workUnits.length >= maxUnits) break;
    const revalidationOnly = candidate.action === "REVALIDATE_R4" || candidate.action === "REVALIDATE_R5" || candidate.action === "REVALIDATE_R6";
    if (!revalidationOnly && (remaining <= 0 || policy.maxJobCostUsd <= 0)) break;
    const ceiling = revalidationOnly ? 0 : Math.min(policy.maxJobCostUsd, remaining);
    const dedupeKey = sha256Hex(`MRV2-RESEARCH-WORK-1.0.0|${context.organisationId}|${context.campaignId}|${context.companyId}|${gapSetFingerprint}|${reference.toISOString()}|${candidate.gapKey}|${Math.round(ceiling * 1e8) / 1e8}`);
    workUnits.push({
      ordinal: workUnits.length + 1,
      gapKey: candidate.gapKey,
      layer: candidate.layer,
      tier: candidate.tier,
      action: candidate.action,
      subjectType: candidate.subjectType,
      subjectId: candidate.subjectId,
      claimKey: candidate.claimKey ?? null,
      reasonCode: candidate.reasonCode,
      queryHints: normalHints(candidate.queryHints),
      costCeilingUsd: Math.round(ceiling * 1e8) / 1e8,
      dedupeKey,
      payload: { metadata: candidate.metadata ?? {}, authorityEnvelopeFingerprint: context.authorityEnvelopeFingerprint, researchOrigin: researchOrigin(candidate) },
    });
    if (!revalidationOnly) remaining = Math.max(0, Math.round((remaining - ceiling) * 1e8) / 1e8);
  }
  const planFingerprint = sha256Hex(`MRV2-RESEARCH-PLAN-1.0.0|${stableJson({organisationId:context.organisationId,campaignId:context.campaignId,companyId:context.companyId,referenceTime:reference.toISOString(),lifecycleState:context.lifecycleState,authorityEnvelopeFingerprint:context.authorityEnvelopeFingerprint,gapSetFingerprint,workUnits})}`);
  return {
    plannerVersion: RESEARCH_PLANNER_VERSION,
    semanticsVersion: RESEARCH_SEMANTICS_VERSION,
    organisationId: context.organisationId,
    campaignId: context.campaignId,
    companyId: context.companyId,
    referenceTime: reference.toISOString(),
    lifecycleState: context.lifecycleState,
    authorityEnvelopeFingerprint: context.authorityEnvelopeFingerprint,
    gapSetFingerprint,
    planFingerprint,
    workUnits,
    budgetExhausted: remainingBudget <= 0 || (candidates.length > workUnits.length && remaining <= 0),
    concurrencyLimited: availableSlots <= 0 || (candidates.length > workUnits.length && workUnits.length >= maxUnits && availableSlots <= policy.maxWorkUnitsPerPlan),
  };
}

const FORBIDDEN_RESULT_KEYS = /(?:^|_)(confidence|probability|score|rank|weight|authority|viability)(?:$|_)/i;
export function assertResearchProviderResultSafe(value: unknown): void {
  const visit = (node: unknown, depth: number) => {
    if (depth > 24) throw new Error("MARKETROUTE_RESEARCH_PROVIDER_RESULT_TOO_DEEP");
    if (Array.isArray(node)) return node.forEach((v) => visit(v, depth + 1));
    if (!node || typeof node !== "object") return;
    for (const [key, child] of Object.entries(node as Record<string, unknown>)) {
      if (FORBIDDEN_RESULT_KEYS.test(key)) throw new Error(`MARKETROUTE_RESEARCH_PROVIDER_AUTHORITY_FIELD_FORBIDDEN:${key}`);
      visit(child, depth + 1);
    }
  };
  visit(value, 0);
}
