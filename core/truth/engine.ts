import { sha256Hex, stableJson } from "../evidence/index";
import {
  TRUTH_ENGINE_VERSION,
  TRUTH_ENTITY_AGGREGATION_VERSION,
  TRUTH_SEMANTICS_VERSION,
  type TruthClaimContext,
  type TruthClaimEvaluation,
  type TruthEntityClaimInput,
  type TruthEntityEvaluation,
  type TruthEntityProfile,
  type TruthFamilyDiagnostic,
} from "./contracts";

const DAY_MS = 86_400_000;
const FUTURE_TOLERANCE_MS = 5 * 60_000;

function parseTime(value: string, code: string): number {
  const time = Date.parse(value);
  if (!Number.isFinite(time)) throw new Error(code);
  return time;
}

function finiteUnit(value: number): number {
  if (!Number.isFinite(value)) throw new Error("MARKETROUTE_TRUTH_NON_FINITE_METRIC");
  return Math.max(0, Math.min(1, value));
}

function roundMetric(value: number): number {
  return Math.round(value * 1_000_000) / 1_000_000;
}

function effectiveOrigin(evidence: TruthClaimContext["evidence"][number]): string {
  return evidence.originPublishedAt ?? evidence.sourcePublishedAt ?? evidence.observedAt;
}

interface FamilyAccumulator {
  currentSupport: number;
  currentContradiction: number;
  stale: number;
  expiries: number[];
  currentFreshness: number;
}

export function evaluateTruthClaim(context: TruthClaimContext): TruthClaimEvaluation {
  if (context.policy.maxAgeDays <= 0 || !Number.isFinite(context.policy.maxAgeDays)) {
    throw new Error("MARKETROUTE_TRUTH_POLICY_MAX_AGE_INVALID");
  }
  if (!Number.isInteger(context.policy.knownSupportFamilyRequirement) || context.policy.knownSupportFamilyRequirement < 2) {
    throw new Error("MARKETROUTE_TRUTH_POLICY_KNOWN_REQUIREMENT_INVALID");
  }

  const referenceMs = parseTime(context.referenceTime, "MARKETROUTE_TRUTH_REFERENCE_TIME_INVALID");
  const maxAgeMs = context.policy.maxAgeDays * DAY_MS;
  const families = new Map<string, FamilyAccumulator>();
  let temporalAnomalyCount = 0;

  for (const evidence of context.evidence) {
    if (!evidence.dependenceFamilyKey.trim()) throw new Error("MARKETROUTE_TRUTH_DEPENDENCE_FAMILY_REQUIRED");
    const observedMs = parseTime(evidence.observedAt, "MARKETROUTE_TRUTH_EVIDENCE_OBSERVED_AT_INVALID");
    const originIso = effectiveOrigin(evidence);
    const originMs = parseTime(originIso, "MARKETROUTE_TRUTH_EVIDENCE_ORIGIN_INVALID");

    if (observedMs > referenceMs + FUTURE_TOLERANCE_MS || originMs > referenceMs + FUTURE_TOLERANCE_MS) {
      temporalAnomalyCount += 1;
      continue;
    }

    const family = families.get(evidence.dependenceFamilyKey) ?? {
      currentSupport: 0,
      currentContradiction: 0,
      stale: 0,
      expiries: [],
      currentFreshness: 0,
    };
    const ageMs = Math.max(0, referenceMs - originMs);
    const isCurrent = ageMs < maxAgeMs;
    if (isCurrent) {
      if (evidence.polarity === "SUPPORTS") family.currentSupport += 1;
      else family.currentContradiction += 1;
      family.expiries.push(originMs + maxAgeMs);
      family.currentFreshness = Math.max(family.currentFreshness, finiteUnit(1 - ageMs / maxAgeMs));
    } else {
      family.stale += 1;
    }
    families.set(evidence.dependenceFamilyKey, family);
  }

  const familyDiagnostics: TruthFamilyDiagnostic[] = [];
  let currentSupportFamilyCount = 0;
  let currentContradictionFamilyCount = 0;
  let staleFamilyCount = 0;
  const revalidationCandidates: number[] = [];
  let currentFreshnessSum = 0;

  for (const [dependenceFamilyKey, family] of [...families.entries()].sort(([a], [b]) => a.localeCompare(b))) {
    const hasSupport = family.currentSupport > 0;
    const hasContradiction = family.currentContradiction > 0;
    let currentState: TruthFamilyDiagnostic["currentState"] = "NONE";
    if (hasSupport && hasContradiction) currentState = "CONFLICT";
    else if (hasContradiction) currentState = "CONTRADICT";
    else if (hasSupport) currentState = "SUPPORT";

    if (currentState === "SUPPORT") currentSupportFamilyCount += 1;
    if (currentState === "CONTRADICT" || currentState === "CONFLICT") currentContradictionFamilyCount += 1;
    if (currentState !== "NONE") currentFreshnessSum += family.currentFreshness;
    if (currentState === "NONE" && family.stale > 0) staleFamilyCount += 1;

    const nextExpiry = family.expiries.length > 0 ? Math.min(...family.expiries) : null;
    if (nextExpiry !== null) revalidationCandidates.push(nextExpiry);
    familyDiagnostics.push({
      dependenceFamilyKey,
      currentState,
      currentEvidenceCount: family.currentSupport + family.currentContradiction,
      staleEvidenceCount: family.stale,
      nextExpiryAt: nextExpiry === null ? null : new Date(nextExpiry).toISOString(),
      currentFreshness: roundMetric(family.currentFreshness),
    });
  }

  const requirement = context.policy.knownSupportFamilyRequirement;
  const currentFamilyCount = currentSupportFamilyCount + currentContradictionFamilyCount;
  let truthState: TruthClaimEvaluation["truthState"];
  if (currentContradictionFamilyCount > 0) truthState = "CONTRADICTED";
  else if (currentSupportFamilyCount >= requirement) truthState = "KNOWN";
  else if (currentSupportFamilyCount >= 1) truthState = "SUPPORTED";
  else if (staleFamilyCount > 0) truthState = "STALE";
  else truthState = "UNRESOLVED";

  const evidenceSufficiency = finiteUnit(currentFamilyCount / requirement);
  const supportStrength = finiteUnit(currentSupportFamilyCount / requirement);
  const contradictionStrength = finiteUnit(currentContradictionFamilyCount / requirement);
  const evidenceBalance = currentFamilyCount === 0
    ? 0
    : Math.max(-1, Math.min(1, (currentSupportFamilyCount - currentContradictionFamilyCount) / currentFamilyCount));
  const freshnessCoverage = currentFamilyCount === 0
    ? 0
    : finiteUnit(currentFreshnessSum / currentFamilyCount);

  return {
    engineVersion: TRUTH_ENGINE_VERSION,
    semanticsVersion: TRUTH_SEMANTICS_VERSION,
    claimId: context.claimId,
    claimKey: context.claimKey,
    claimFingerprint: context.claimFingerprint,
    propositionFingerprint: context.propositionFingerprint,
    subjectType: context.subjectType,
    subjectId: context.subjectId,
    tenantScopeOrganisationId: context.tenantScopeOrganisationId,
    referenceTime: new Date(referenceMs).toISOString(),
    inputFingerprint: context.contextFingerprint,
    policy: context.policy,
    truthState,
    currentSupportFamilyCount,
    currentContradictionFamilyCount,
    staleFamilyCount,
    temporalAnomalyCount,
    evidenceSufficiency: roundMetric(evidenceSufficiency),
    supportStrength: roundMetric(supportStrength),
    contradictionStrength: roundMetric(contradictionStrength),
    evidenceBalance: roundMetric(evidenceBalance),
    freshnessCoverage: roundMetric(freshnessCoverage),
    truthProbability: null,
    probabilityState: "UNCALIBRATED",
    nextRevalidationAt: revalidationCandidates.length === 0 ? null : new Date(Math.min(...revalidationCandidates)).toISOString(),
    familyDiagnostics,
  };
}

export function truthClaimOutputFingerprint(evaluation: TruthClaimEvaluation): string {
  return sha256Hex(stableJson({
    engineVersion: evaluation.engineVersion,
    semanticsVersion: evaluation.semanticsVersion,
    claimId: evaluation.claimId,
    propositionFingerprint: evaluation.propositionFingerprint,
    inputFingerprint: evaluation.inputFingerprint,
    truthState: evaluation.truthState,
    currentSupportFamilyCount: evaluation.currentSupportFamilyCount,
    currentContradictionFamilyCount: evaluation.currentContradictionFamilyCount,
    staleFamilyCount: evaluation.staleFamilyCount,
    temporalAnomalyCount: evaluation.temporalAnomalyCount,
    evidenceSufficiency: evaluation.evidenceSufficiency,
    supportStrength: evaluation.supportStrength,
    contradictionStrength: evaluation.contradictionStrength,
    evidenceBalance: evaluation.evidenceBalance,
    freshnessCoverage: evaluation.freshnessCoverage,
    probabilityState: evaluation.probabilityState,
    truthProbability: evaluation.truthProbability,
    nextRevalidationAt: evaluation.nextRevalidationAt,
  }));
}

export function evaluateTruthEntity(
  subjectId: string,
  referenceTime: string,
  profile: TruthEntityProfile,
  claims: TruthEntityClaimInput[],
): TruthEntityEvaluation {
  const referenceMs = parseTime(referenceTime, "MARKETROUTE_TRUTH_ENTITY_REFERENCE_TIME_INVALID");
  if (profile.requiredClaimKeys.length === 0) throw new Error("MARKETROUTE_TRUTH_ENTITY_PROFILE_EMPTY");
  if (new Set(profile.requiredClaimKeys).size !== profile.requiredClaimKeys.length) {
    throw new Error("MARKETROUTE_TRUTH_ENTITY_PROFILE_DUPLICATE_KEY");
  }

  const byKey = new Map(claims.map((item) => [item.claimKey, item.evaluations]));
  let known = 0;
  let supported = 0;
  let contradicted = 0;
  let stale = 0;
  let unresolved = 0;
  let represented = 0;
  let currentRepresented = 0;
  let sufficiencySum = 0;
  let freshnessSum = 0;
  const nextRevalidation: number[] = [];

  for (const claimKey of profile.requiredClaimKeys) {
    const evaluations = byKey.get(claimKey) ?? [];
    for (const evaluation of evaluations) {
      if (evaluation.subjectType !== profile.subjectType || evaluation.subjectId !== subjectId || evaluation.claimKey !== claimKey) {
        throw new Error("MARKETROUTE_TRUTH_ENTITY_CLAIM_SCOPE_MISMATCH");
      }
      if (parseTime(evaluation.referenceTime, "MARKETROUTE_TRUTH_ENTITY_CLAIM_REFERENCE_INVALID") !== referenceMs) {
        throw new Error("MARKETROUTE_TRUTH_ENTITY_REFERENCE_MISMATCH");
      }
      if (evaluation.nextRevalidationAt) nextRevalidation.push(parseTime(evaluation.nextRevalidationAt, "MARKETROUTE_TRUTH_ENTITY_REVALIDATION_INVALID"));
    }

    const positive = evaluations.filter((evaluation) => evaluation.truthState === "KNOWN" || evaluation.truthState === "SUPPORTED");
    const positiveByProposition = new Map<string, TruthClaimEvaluation[]>();
    for (const evaluation of positive) {
      const group = positiveByProposition.get(evaluation.propositionFingerprint) ?? [];
      group.push(evaluation);
      positiveByProposition.set(evaluation.propositionFingerprint, group);
    }
    const contradictedEvaluations = evaluations.filter((evaluation) => evaluation.truthState === "CONTRADICTED");
    const staleEvaluations = evaluations.filter((evaluation) => evaluation.truthState === "STALE");

    // Any explicit current contradiction at a required boundary outranks positive evidence.
    // More than one distinct currently supported proposition is also an entity-level contradiction.
    if (contradictedEvaluations.length > 0) {
      const currentCandidates = [...positive, ...contradictedEvaluations];
      contradicted += 1;
      represented += 1;
      currentRepresented += 1;
      sufficiencySum += Math.max(...currentCandidates.map((evaluation) => evaluation.evidenceSufficiency));
      freshnessSum += Math.max(...currentCandidates.map((evaluation) => evaluation.freshnessCoverage));
      continue;
    }

    if (positiveByProposition.size > 1) {
      contradicted += 1;
      represented += 1;
      currentRepresented += 1;
      sufficiencySum += Math.max(...positive.map((evaluation) => evaluation.evidenceSufficiency));
      freshnessSum += Math.max(...positive.map((evaluation) => evaluation.freshnessCoverage));
      continue;
    }

    if (positiveByProposition.size === 1) {
      const candidates = [...positiveByProposition.values()][0]!;
      const chosen = [...candidates].sort((a, b) => {
        if (a.truthState !== b.truthState) return a.truthState === "KNOWN" ? -1 : 1;
        if (a.evidenceSufficiency !== b.evidenceSufficiency) return b.evidenceSufficiency - a.evidenceSufficiency;
        return b.freshnessCoverage - a.freshnessCoverage;
      })[0]!;
      if (chosen.truthState === "KNOWN") known += 1;
      else supported += 1;
      represented += 1;
      currentRepresented += 1;
      sufficiencySum += Math.max(...candidates.map((evaluation) => evaluation.evidenceSufficiency));
      freshnessSum += Math.max(...candidates.map((evaluation) => evaluation.freshnessCoverage));
      continue;
    }

    if (staleEvaluations.length > 0) {
      stale += 1;
      represented += 1;
      sufficiencySum += Math.max(...staleEvaluations.map((evaluation) => evaluation.evidenceSufficiency));
      freshnessSum += Math.max(...staleEvaluations.map((evaluation) => evaluation.freshnessCoverage));
      continue;
    }

    unresolved += 1;
  }

  const required = profile.requiredClaimKeys.length;
  const coverage = finiteUnit(represented / required);
  const currentCoverage = finiteUnit(currentRepresented / required);
  const evidenceSufficiency = finiteUnit(sufficiencySum / required);
  const freshnessCoverage = finiteUnit(freshnessSum / required);
  const coherence = finiteUnit(1 - contradicted / required);
  const truthIndex = Math.round(Math.min(currentCoverage, evidenceSufficiency, freshnessCoverage, coherence) * 10_000) / 100;

  let entityState: TruthEntityEvaluation["entityState"];
  if (contradicted > 0) entityState = "CONTRADICTED";
  else if (known === required) entityState = "KNOWN";
  else if (known + supported === required) entityState = "SUPPORTED";
  else if (currentRepresented === 0 && stale > 0) entityState = "STALE";
  else if (represented === 0) entityState = "UNRESOLVED";
  else entityState = "PARTIAL";

  return {
    aggregationVersion: TRUTH_ENTITY_AGGREGATION_VERSION,
    semanticsVersion: TRUTH_SEMANTICS_VERSION,
    subjectType: profile.subjectType,
    subjectId,
    referenceTime: new Date(referenceMs).toISOString(),
    profile,
    entityState,
    requiredClaimCount: required,
    knownClaimCount: known,
    supportedClaimCount: supported,
    contradictedClaimCount: contradicted,
    staleClaimCount: stale,
    unresolvedClaimCount: unresolved,
    coverage: roundMetric(coverage),
    currentCoverage: roundMetric(currentCoverage),
    evidenceSufficiency: roundMetric(evidenceSufficiency),
    freshnessCoverage: roundMetric(freshnessCoverage),
    coherence: roundMetric(coherence),
    truthIndex,
    truthProbability: null,
    probabilityState: "UNCALIBRATED",
    nextRevalidationAt: nextRevalidation.length === 0 ? null : new Date(Math.min(...nextRevalidation)).toISOString(),
  };
}
export function truthEntityOutputFingerprint(evaluation: TruthEntityEvaluation, claimInputFingerprints: string[]): string {
  return sha256Hex(stableJson({
    aggregationVersion: evaluation.aggregationVersion,
    semanticsVersion: evaluation.semanticsVersion,
    subjectType: evaluation.subjectType,
    subjectId: evaluation.subjectId,
    referenceTime: evaluation.referenceTime,
    profileKey: evaluation.profile.profileKey,
    profileVersion: evaluation.profile.profileVersion,
    requiredClaimKeys: evaluation.profile.requiredClaimKeys,
    claimInputFingerprints: [...claimInputFingerprints].sort(),
    entityState: evaluation.entityState,
    truthIndex: evaluation.truthIndex,
    coverage: evaluation.coverage,
    currentCoverage: evaluation.currentCoverage,
    evidenceSufficiency: evaluation.evidenceSufficiency,
    freshnessCoverage: evaluation.freshnessCoverage,
    coherence: evaluation.coherence,
    probabilityState: evaluation.probabilityState,
    truthProbability: evaluation.truthProbability,
  }));
}
