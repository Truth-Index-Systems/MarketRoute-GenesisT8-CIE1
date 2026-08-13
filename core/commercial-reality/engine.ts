import { sha256Hex, stableJson } from "../evidence/index.js";
import type { CanonicalConstraintSemantic, SellerGenomeSemanticPayload } from "../seller-genome/contracts.js";
import {
  COMMERCIAL_REALITY_BOUNDARY_CONSTITUTION_VERSION,
  COMMERCIAL_REALITY_ENGINE_VERSION,
  COMMERCIAL_REALITY_MAX_AUTHORITY_HOURS,
  COMMERCIAL_REALITY_REALITY_CLASS,
  COMMERCIAL_REALITY_SEMANTICS_VERSION,
  COMMERCIAL_REALITY_WRITER_KEY,
  COMMERCIAL_REALITY_WRITER_VERSION,
  type CommercialBoundaryEvaluation,
  type CommercialRealityContext,
  type CommercialRealityEvaluation,
  type CommercialRealityTruthSnapshot,
  type HardConstraintRequirement,
} from "./contracts.js";

const HOUR_MS = 3_600_000;

const HARD_CONSTRAINT_CLAIM_KEYS: Readonly<Record<string, string>> = {
  geography: "profile.country_code",
  country: "profile.country_code",
  country_code: "profile.country_code",
  industry: "profile.industry_code",
  company_size: "profile.company_size_band",
  company_size_band: "profile.company_size_band",
  business_model: "profile.business_model_code",
};

function cleanCode(value: string): string {
  return value.trim().toLowerCase();
}

function scalarValue(snapshot: CommercialRealityTruthSnapshot): string | null {
  if (snapshot.canonicalValueText?.trim()) return snapshot.canonicalValueText.trim();
  const value = snapshot.objectJson;
  if (typeof value === "string" || typeof value === "number" || typeof value === "boolean") return String(value);
  if (value && typeof value === "object" && !Array.isArray(value) && "value" in value) {
    const nested = (value as { value?: unknown }).value;
    if (typeof nested === "string" || typeof nested === "number" || typeof nested === "boolean") return String(nested);
  }
  return null;
}

interface ResolvedTruthSet {
  state: "RESOLVED" | "UNRESOLVED" | "CONTRADICTED" | "STALE";
  value: string | null;
  sourceFingerprints: string[];
  nextRevalidationAt: string | null;
}

function resolveTruthSet(snapshots: CommercialRealityTruthSnapshot[]): ResolvedTruthSet {
  const ordered = [...snapshots].sort((a, b) => a.snapshotId.localeCompare(b.snapshotId));
  const sourceFingerprints = [...new Set(ordered.map((item) => item.snapshotFingerprint))].sort();
  if (ordered.some((item) => item.truthState === "CONTRADICTED")) {
    return { state: "CONTRADICTED", value: null, sourceFingerprints, nextRevalidationAt: earliestRevalidation(ordered) };
  }

  const positive = ordered.filter((item) => item.truthState === "KNOWN" || item.truthState === "SUPPORTED");
  const propositions = new Set(positive.map((item) => item.propositionFingerprint));
  if (propositions.size > 1) {
    return { state: "CONTRADICTED", value: null, sourceFingerprints, nextRevalidationAt: earliestRevalidation(positive) };
  }
  if (positive.length > 0) {
    const selected = [...positive].sort((a, b) => {
      const rank = (value: CommercialRealityTruthSnapshot) => value.truthState === "KNOWN" ? 0 : 1;
      return rank(a) - rank(b) || a.snapshotId.localeCompare(b.snapshotId);
    })[0]!;
    return { state: "RESOLVED", value: scalarValue(selected), sourceFingerprints, nextRevalidationAt: earliestRevalidation(positive) };
  }
  if (ordered.some((item) => item.truthState === "STALE")) {
    return { state: "STALE", value: null, sourceFingerprints, nextRevalidationAt: null };
  }
  return { state: "UNRESOLVED", value: null, sourceFingerprints, nextRevalidationAt: null };
}

function earliestRevalidation(snapshots: CommercialRealityTruthSnapshot[]): string | null {
  const times = snapshots
    .map((item) => item.nextRevalidationAt)
    .filter((value): value is string => Boolean(value))
    .map((value) => Date.parse(value))
    .filter(Number.isFinite);
  return times.length ? new Date(Math.min(...times)).toISOString() : null;
}

function baseBoundary(boundaryKey: string, reasonCode: string, state: CommercialBoundaryEvaluation["state"]): CommercialBoundaryEvaluation {
  return { boundaryKey, category: "MANDATORY", required: true, state, reasonCode, claimKey: null, observedValue: null, expectedValues: [], sourceFingerprints: [], nextRevalidationAt: null };
}

function truthBoundary(
  boundaryKey: string,
  claimKey: string,
  snapshots: CommercialRealityTruthSnapshot[],
  validate: (value: string | null) => boolean,
  expectedValues: string[] = [],
): CommercialBoundaryEvaluation {
  const resolved = resolveTruthSet(snapshots);
  if (resolved.state !== "RESOLVED") {
    return {
      boundaryKey, category: "MANDATORY", required: true, state: resolved.state,
      reasonCode: `TARGET_${resolved.state}`, claimKey, observedValue: null, expectedValues,
      sourceFingerprints: resolved.sourceFingerprints, nextRevalidationAt: resolved.nextRevalidationAt,
    };
  }
  const ok = validate(resolved.value);
  return {
    boundaryKey, category: "MANDATORY", required: true, state: ok ? "SATISFIED" : "UNSATISFIED",
    reasonCode: ok ? "TARGET_TRUTH_SATISFIES_BOUNDARY" : "TARGET_TRUTH_VIOLATES_BOUNDARY",
    claimKey, observedValue: resolved.value, expectedValues,
    sourceFingerprints: resolved.sourceFingerprints, nextRevalidationAt: resolved.nextRevalidationAt,
  };
}

export function deriveHardConstraintRequirements(semantic: SellerGenomeSemanticPayload): HardConstraintRequirement[] {
  if (semantic.constraints.state !== "DECLARED") return [];
  return semantic.constraints.items
    .filter((item: CanonicalConstraintSemantic) => item.mode === "HARD")
    .map((item) => {
      const constraintType = cleanCode(item.constraintType);
      const claimKey = HARD_CONSTRAINT_CLAIM_KEYS[constraintType] ?? null;
      return {
        constraintKey: item.constraintKey,
        constraintType,
        claimKey,
        allowedValues: [...new Set(item.valueCodes.map(cleanCode))].sort(),
        supported: claimKey !== null,
      };
    })
    .sort((a, b) => a.constraintKey.localeCompare(b.constraintKey));
}

function evaluateHardConstraint(requirement: HardConstraintRequirement, snapshots: CommercialRealityTruthSnapshot[]): CommercialBoundaryEvaluation {
  const boundaryKey = `hard_constraint.${requirement.constraintKey}`;
  if (!requirement.supported || !requirement.claimKey) {
    return {
      boundaryKey, category: "HARD_CONSTRAINT", required: true, state: "UNRESOLVED",
      reasonCode: "UNSUPPORTED_HARD_CONSTRAINT_TYPE", claimKey: null, observedValue: null,
      expectedValues: requirement.allowedValues, sourceFingerprints: [], nextRevalidationAt: null,
    };
  }
  const resolved = resolveTruthSet(snapshots);
  if (resolved.state !== "RESOLVED") {
    return {
      boundaryKey, category: "HARD_CONSTRAINT", required: true, state: resolved.state,
      reasonCode: `HARD_CONSTRAINT_TARGET_${resolved.state}`, claimKey: requirement.claimKey,
      observedValue: null, expectedValues: requirement.allowedValues,
      sourceFingerprints: resolved.sourceFingerprints, nextRevalidationAt: resolved.nextRevalidationAt,
    };
  }
  const observed = resolved.value ? cleanCode(resolved.value) : null;
  const satisfied = observed !== null && requirement.allowedValues.includes(observed);
  return {
    boundaryKey, category: "HARD_CONSTRAINT", required: true, state: satisfied ? "SATISFIED" : "UNSATISFIED",
    reasonCode: satisfied ? "HARD_CONSTRAINT_SATISFIED" : "HARD_CONSTRAINT_VIOLATED",
    claimKey: requirement.claimKey, observedValue: resolved.value, expectedValues: requirement.allowedValues,
    sourceFingerprints: resolved.sourceFingerprints, nextRevalidationAt: resolved.nextRevalidationAt,
  };
}

function decisionFromBoundaries(boundaries: CommercialBoundaryEvaluation[]): CommercialRealityEvaluation["decision"] {
  if (boundaries.some((item) => item.state === "UNSATISFIED")) return "NOT_ADMISSIBLE";
  if (boundaries.some((item) => ["UNRESOLVED", "CONTRADICTED", "STALE"].includes(item.state))) return "RESEARCH_REQUIRED";
  return "COMMERCIAL_CANDIDATE";
}

function nextAuthorityBoundary(context: CommercialRealityContext, boundaries: CommercialBoundaryEvaluation[]): string {
  const reference = Date.parse(context.referenceTime);
  if (!Number.isFinite(reference)) throw new Error("MARKETROUTE_R4_REFERENCE_TIME_INVALID");
  const cap = reference + COMMERCIAL_REALITY_MAX_AUTHORITY_HOURS * HOUR_MS;
  const candidates = boundaries
    .map((item) => item.nextRevalidationAt)
    .filter((value): value is string => Boolean(value))
    .map((value) => Date.parse(value))
    .filter((value) => Number.isFinite(value) && value > reference);
  const entityNext = context.targetTruth.nextRevalidationAt ? Date.parse(context.targetTruth.nextRevalidationAt) : NaN;
  if (Number.isFinite(entityNext) && entityNext > reference) candidates.push(entityNext);
  return new Date(Math.min(cap, ...(candidates.length ? candidates : [cap]))).toISOString();
}

export function evaluateCommercialReality(context: CommercialRealityContext): CommercialRealityEvaluation {
  const objective = context.seller.semantic.commercialObjectives.items.find((item) => item.objectiveKey === context.seller.objectiveKey);
  const boundaries: CommercialBoundaryEvaluation[] = [];

  boundaries.push(baseBoundary(
    "seller.offering_present",
    context.seller.semantic.offerings.state === "DECLARED" && context.seller.semantic.offerings.items.length > 0 ? "SELLER_OFFERING_DECLARED" : "SELLER_OFFERING_UNRESOLVED",
    context.seller.semantic.offerings.state === "DECLARED" && context.seller.semantic.offerings.items.length > 0 ? "SATISFIED" : "UNRESOLVED",
  ));
  boundaries.push(baseBoundary(
    "seller.objective_selected",
    objective ? "SELLER_OBJECTIVE_SELECTED" : "SELLER_OBJECTIVE_UNRESOLVED",
    objective ? "SATISFIED" : "UNRESOLVED",
  ));
  boundaries.push(baseBoundary(
    "seller.constraints_known",
    context.seller.semantic.constraints.state === "UNKNOWN" ? "SELLER_CONSTRAINTS_UNKNOWN" : "SELLER_CONSTRAINTS_REPRESENTED",
    context.seller.semantic.constraints.state === "UNKNOWN" ? "UNRESOLVED" : "SATISFIED",
  ));

  boundaries.push(truthBoundary(
    "target.identity",
    "identity.canonical_name",
    context.targetTruth.coreClaims["identity.canonical_name"] ?? [],
    (value) => Boolean(value?.trim()),
  ));
  boundaries.push(truthBoundary(
    "target.canonical_domain",
    "identity.canonical_domain",
    context.targetTruth.coreClaims["identity.canonical_domain"] ?? [],
    (value) => Boolean(value?.trim() && value.includes(".")),
  ));
  boundaries.push(truthBoundary(
    "target.current_operation",
    "operation.current",
    context.targetTruth.coreClaims["operation.current"] ?? [],
    (value) => value?.trim().toLowerCase() === "true",
    ["true"],
  ));

  for (const requirement of deriveHardConstraintRequirements(context.seller.semantic)) {
    boundaries.push(evaluateHardConstraint(requirement, requirement.claimKey ? (context.targetTruth.constraintClaims[requirement.claimKey] ?? []) : []));
  }

  const decision = decisionFromBoundaries(boundaries);
  const nextRevalidationAt = nextAuthorityBoundary(context, boundaries);
  const diagnosticInputFingerprint = sha256Hex(stableJson({
    version: "MRV2-R4-DIAGNOSTIC-INPUT-1.0.0",
    organisationId: context.organisationId,
    campaignId: context.campaignId,
    companyId: context.companyId,
    referenceTime: context.referenceTime,
    sellerSelectionId: context.seller.selectionId,
    sellerSemanticContextFingerprint: context.seller.semanticContextFingerprint,
    targetEntitySnapshotFingerprint: context.targetTruth.entitySnapshotFingerprint,
    constraintSnapshotFingerprints: Object.fromEntries(Object.entries(context.targetTruth.constraintClaims).sort(([a], [b]) => a.localeCompare(b)).map(([key, values]) => [key, values.map((v) => v.snapshotFingerprint).sort()])),
    boundaryConstitutionVersion: COMMERCIAL_REALITY_BOUNDARY_CONSTITUTION_VERSION,
    realityClass: COMMERCIAL_REALITY_REALITY_CLASS,
  }));

  return {
    engineVersion: COMMERCIAL_REALITY_ENGINE_VERSION,
    semanticsVersion: COMMERCIAL_REALITY_SEMANTICS_VERSION,
    boundaryConstitutionVersion: COMMERCIAL_REALITY_BOUNDARY_CONSTITUTION_VERSION,
    realityClass: COMMERCIAL_REALITY_REALITY_CLASS,
    writerKey: COMMERCIAL_REALITY_WRITER_KEY,
    writerVersion: COMMERCIAL_REALITY_WRITER_VERSION,
    organisationId: context.organisationId,
    campaignId: context.campaignId,
    companyId: context.companyId,
    referenceTime: new Date(Date.parse(context.referenceTime)).toISOString(),
    decision,
    boundaries,
    nextRevalidationAt,
    diagnosticInputFingerprint,
  };
}
