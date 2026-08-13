import { normaliseOptionalText, normaliseText, stableJson } from "../evidence/index";
import {
  SELLER_GENOME_CANONICALISATION_VERSION,
  SELLER_GENOME_SCHEMA_VERSION,
  type CanonicalSellerGenome,
  type CommercialObjectiveType,
  type ExplicitSellerUnknown,
  type SemanticDimensionState,
  type SellerGenomeCandidate,
  type SellerGenomeDimensionKey,
} from "./contracts";

const CODE_PATTERN = /^[a-z0-9][a-z0-9._-]{0,79}$/;
const COUNTRY_PATTERN = /^[A-Z]{2}$/;
const FORBIDDEN_AUTHORITY_KEY = /(confidence|probability|score|rank|fit|viab|authority|priority)/i;

function canonicalCode(value: string, code: string): string {
  const normalised = normaliseText(value).toLowerCase().replace(/\s+/g, "_");
  if (!CODE_PATTERN.test(normalised)) throw new Error(code);
  return normalised;
}

function canonicalCountry(value: string): string {
  const country = normaliseText(value).toUpperCase();
  if (!COUNTRY_PATTERN.test(country)) throw new Error("MARKETROUTE_SELLER_GENOME_COUNTRY_CODE_INVALID");
  return country;
}

function uniqueSorted(values: string[], mapper: (value: string) => string): string[] {
  return [...new Set(values.map(mapper))].sort((a, b) => a.localeCompare(b));
}

function assertNoAuthorityLikeFields(value: unknown, path = "candidate"): void {
  if (Array.isArray(value)) {
    value.forEach((entry, index) => assertNoAuthorityLikeFields(entry, `${path}[${index}]`));
    return;
  }
  if (!value || typeof value !== "object") return;
  for (const [key, child] of Object.entries(value as Record<string, unknown>)) {
    if (FORBIDDEN_AUTHORITY_KEY.test(key)) throw new Error(`MARKETROUTE_SELLER_GENOME_FORBIDDEN_AI_FIELD:${path}.${key}`);
    assertNoAuthorityLikeFields(child, `${path}.${key}`);
  }
}


function assertExactKeys(value: unknown, allowed: readonly string[], path: string): void {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`MARKETROUTE_SELLER_GENOME_OBJECT_REQUIRED:${path}`);
  const extras = Object.keys(value as Record<string, unknown>).filter((key) => !allowed.includes(key));
  if (extras.length > 0) throw new Error(`MARKETROUTE_SELLER_GENOME_UNKNOWN_FIELD:${path}.${extras.sort()[0]}`);
}

function assertCandidateShape(candidate: SellerGenomeCandidate): void {
  assertExactKeys(candidate, ["offerings", "capabilities", "commercialObjectives", "delivery", "serviceGeography", "targetCharacteristics", "buyerAssumptions", "constraints"], "candidate");
  for (const [name, dimension] of [["offerings", candidate.offerings], ["capabilities", candidate.capabilities], ["commercialObjectives", candidate.commercialObjectives], ["constraints", candidate.constraints]] as const) {
    assertExactKeys(dimension, ["state", "items", "unknownQuestion"], `candidate.${name}`);
  }
  assertExactKeys(candidate.delivery, ["state", "modeCodes", "notes", "unknownQuestion"], "candidate.delivery");
  assertExactKeys(candidate.serviceGeography, ["state", "countryCodes", "regionCodes", "notes", "unknownQuestion"], "candidate.serviceGeography");
  assertExactKeys(candidate.targetCharacteristics, ["state", "industryCodes", "companySizeBands", "businessModelCodes", "notes", "unknownQuestion"], "candidate.targetCharacteristics");
  assertExactKeys(candidate.buyerAssumptions, ["state", "roleCodes", "departmentCodes", "painCodes", "notes", "unknownQuestion"], "candidate.buyerAssumptions");
  candidate.offerings.items.forEach((item, i) => assertExactKeys(item, ["offeringKey", "label", "description", "problemCodes", "outcomeCodes", "deliveryModeCodes"], `candidate.offerings.items[${i}]`));
  candidate.capabilities.items.forEach((item, i) => assertExactKeys(item, ["capabilityKey", "label", "description"], `candidate.capabilities.items[${i}]`));
  candidate.commercialObjectives.items.forEach((item, i) => assertExactKeys(item, ["objectiveKey", "objectiveType", "statement", "offeringKeys", "desiredActionCode", "outcomeCodes"], `candidate.commercialObjectives.items[${i}]`));
  candidate.constraints.items.forEach((item, i) => assertExactKeys(item, ["constraintKey", "constraintType", "mode", "valueCodes", "statement"], `candidate.constraints.items[${i}]`));
}

function validateDimensionState(state: SemanticDimensionState, itemCount: number, dimension: SellerGenomeDimensionKey): void {
  if (state === "DECLARED" && itemCount === 0) throw new Error(`MARKETROUTE_SELLER_GENOME_DECLARED_EMPTY:${dimension}`);
  if (state !== "DECLARED" && itemCount !== 0) throw new Error(`MARKETROUTE_SELLER_GENOME_NONDECLARED_HAS_ITEMS:${dimension}`);
}

function unknownQuestion(dimension: SellerGenomeDimensionKey, supplied?: string | null): string {
  const suppliedText = normaliseOptionalText(supplied);
  if (suppliedText) return suppliedText;
  const defaults: Record<SellerGenomeDimensionKey, string> = {
    offerings: "What does this business currently sell?",
    capabilities: "What capabilities can this business reliably deliver?",
    commercialObjectives: "What commercial outcome does this business want MarketRoute to pursue?",
    delivery: "How can this business deliver its offering?",
    serviceGeography: "Where can this business commercially serve customers?",
    targetCharacteristics: "What target-company characteristics are relevant to this seller?",
    buyerAssumptions: "Which buyer roles, departments or pains are relevant to this seller?",
    constraints: "What hard constraints or preferences limit this seller's commercial motion?",
  };
  return defaults[dimension];
}

function normaliseObjectiveType(value: CommercialObjectiveType): CommercialObjectiveType {
  const allowed: CommercialObjectiveType[] = [
    "ACQUIRE_CUSTOMERS", "EXPAND_ACCOUNTS", "BUILD_PARTNERSHIPS", "ENTER_MARKET", "SOURCE_SUPPLIERS", "RECRUIT_TALENT", "OTHER",
  ];
  if (!allowed.includes(value)) throw new Error("MARKETROUTE_SELLER_GENOME_OBJECTIVE_TYPE_INVALID");
  return value;
}

export function canonicaliseSellerGenome(
  sellerBusinessId: string,
  sellerDisplayName: string,
  candidate: SellerGenomeCandidate,
): CanonicalSellerGenome {
  if (!sellerBusinessId.trim()) throw new Error("MARKETROUTE_SELLER_GENOME_SELLER_ID_REQUIRED");
  const displayName = normaliseText(sellerDisplayName);
  if (!displayName) throw new Error("MARKETROUTE_SELLER_GENOME_SELLER_NAME_REQUIRED");
  assertNoAuthorityLikeFields(candidate);
  assertCandidateShape(candidate);

  validateDimensionState(candidate.offerings.state, candidate.offerings.items.length, "offerings");
  validateDimensionState(candidate.capabilities.state, candidate.capabilities.items.length, "capabilities");
  validateDimensionState(candidate.commercialObjectives.state, candidate.commercialObjectives.items.length, "commercialObjectives");
  validateDimensionState(candidate.constraints.state, candidate.constraints.items.length, "constraints");

  for (const [dimension, state, count] of [
    ["delivery", candidate.delivery.state, candidate.delivery.modeCodes.length],
    ["serviceGeography", candidate.serviceGeography.state, candidate.serviceGeography.countryCodes.length + (candidate.serviceGeography.regionCodes?.length ?? 0)],
    ["targetCharacteristics", candidate.targetCharacteristics.state, (candidate.targetCharacteristics.industryCodes?.length ?? 0) + (candidate.targetCharacteristics.companySizeBands?.length ?? 0) + (candidate.targetCharacteristics.businessModelCodes?.length ?? 0)],
    ["buyerAssumptions", candidate.buyerAssumptions.state, (candidate.buyerAssumptions.roleCodes?.length ?? 0) + (candidate.buyerAssumptions.departmentCodes?.length ?? 0) + (candidate.buyerAssumptions.painCodes?.length ?? 0)],
  ] as const) {
    if (state === "DECLARED" && count === 0) throw new Error(`MARKETROUTE_SELLER_GENOME_DECLARED_EMPTY:${dimension}`);
    if (state !== "DECLARED" && count !== 0) throw new Error(`MARKETROUTE_SELLER_GENOME_NONDECLARED_HAS_VALUES:${dimension}`);
  }

  const offerings = candidate.offerings.items.map((item) => ({
    semantic: {
      offeringKey: canonicalCode(item.offeringKey, "MARKETROUTE_SELLER_GENOME_OFFERING_KEY_INVALID"),
      problemCodes: uniqueSorted(item.problemCodes ?? [], (v) => canonicalCode(v, "MARKETROUTE_SELLER_GENOME_PROBLEM_CODE_INVALID")),
      outcomeCodes: uniqueSorted(item.outcomeCodes ?? [], (v) => canonicalCode(v, "MARKETROUTE_SELLER_GENOME_OUTCOME_CODE_INVALID")),
      deliveryModeCodes: uniqueSorted(item.deliveryModeCodes ?? [], (v) => canonicalCode(v, "MARKETROUTE_SELLER_GENOME_DELIVERY_CODE_INVALID")),
    },
    copy: {
      label: normaliseText(item.label),
      description: normaliseOptionalText(item.description),
    },
  }));
  const offeringKeys = new Set(offerings.map((item) => item.semantic.offeringKey));
  if (offeringKeys.size !== offerings.length) throw new Error("MARKETROUTE_SELLER_GENOME_DUPLICATE_OFFERING_KEY");

  const capabilities = candidate.capabilities.items.map((item) => ({
    semantic: { capabilityKey: canonicalCode(item.capabilityKey, "MARKETROUTE_SELLER_GENOME_CAPABILITY_KEY_INVALID") },
    copy: { label: normaliseText(item.label), description: normaliseOptionalText(item.description) },
  }));
  if (new Set(capabilities.map((item) => item.semantic.capabilityKey)).size !== capabilities.length) {
    throw new Error("MARKETROUTE_SELLER_GENOME_DUPLICATE_CAPABILITY_KEY");
  }

  const objectives = candidate.commercialObjectives.items.map((item) => {
    const objectiveOfferingKeys = uniqueSorted(item.offeringKeys ?? [], (v) => canonicalCode(v, "MARKETROUTE_SELLER_GENOME_OBJECTIVE_OFFERING_KEY_INVALID"));
    for (const key of objectiveOfferingKeys) {
      if (!offeringKeys.has(key)) throw new Error(`MARKETROUTE_SELLER_GENOME_OBJECTIVE_UNKNOWN_OFFERING:${key}`);
    }
    return {
      semantic: {
        objectiveKey: canonicalCode(item.objectiveKey, "MARKETROUTE_SELLER_GENOME_OBJECTIVE_KEY_INVALID"),
        objectiveType: normaliseObjectiveType(item.objectiveType),
        offeringKeys: objectiveOfferingKeys,
        desiredActionCode: canonicalCode(item.desiredActionCode, "MARKETROUTE_SELLER_GENOME_DESIRED_ACTION_INVALID"),
        outcomeCodes: uniqueSorted(item.outcomeCodes ?? [], (v) => canonicalCode(v, "MARKETROUTE_SELLER_GENOME_OBJECTIVE_OUTCOME_INVALID")),
      },
      copy: { statement: normaliseText(item.statement) },
    };
  });
  if (new Set(objectives.map((item) => item.semantic.objectiveKey)).size !== objectives.length) {
    throw new Error("MARKETROUTE_SELLER_GENOME_DUPLICATE_OBJECTIVE_KEY");
  }

  const constraints = candidate.constraints.items.map((item) => {
    const valueCodes = uniqueSorted(item.valueCodes ?? [], (v) => canonicalCode(v, "MARKETROUTE_SELLER_GENOME_CONSTRAINT_VALUE_INVALID"));
    if (valueCodes.length === 0) throw new Error("MARKETROUTE_SELLER_GENOME_CONSTRAINT_VALUE_REQUIRED");
    if (item.mode !== "HARD" && item.mode !== "PREFERENCE") throw new Error("MARKETROUTE_SELLER_GENOME_CONSTRAINT_MODE_INVALID");
    return {
      semantic: {
        constraintKey: canonicalCode(item.constraintKey, "MARKETROUTE_SELLER_GENOME_CONSTRAINT_KEY_INVALID"),
        constraintType: canonicalCode(item.constraintType, "MARKETROUTE_SELLER_GENOME_CONSTRAINT_TYPE_INVALID"),
        mode: item.mode,
        valueCodes,
      },
      copy: { statement: normaliseText(item.statement) },
    };
  });
  if (new Set(constraints.map((item) => item.semantic.constraintKey)).size !== constraints.length) {
    throw new Error("MARKETROUTE_SELLER_GENOME_DUPLICATE_CONSTRAINT_KEY");
  }

  const semantic = {
    offerings: { state: candidate.offerings.state, items: offerings.map((item) => item.semantic).sort((a, b) => a.offeringKey.localeCompare(b.offeringKey)) },
    capabilities: { state: candidate.capabilities.state, items: capabilities.map((item) => item.semantic).sort((a, b) => a.capabilityKey.localeCompare(b.capabilityKey)) },
    commercialObjectives: { state: candidate.commercialObjectives.state, items: objectives.map((item) => item.semantic).sort((a, b) => a.objectiveKey.localeCompare(b.objectiveKey)) },
    delivery: {
      state: candidate.delivery.state,
      modeCodes: uniqueSorted(candidate.delivery.modeCodes, (v) => canonicalCode(v, "MARKETROUTE_SELLER_GENOME_DELIVERY_CODE_INVALID")),
    },
    serviceGeography: {
      state: candidate.serviceGeography.state,
      countryCodes: uniqueSorted(candidate.serviceGeography.countryCodes, canonicalCountry),
      regionCodes: uniqueSorted(candidate.serviceGeography.regionCodes ?? [], (v) => canonicalCode(v, "MARKETROUTE_SELLER_GENOME_REGION_CODE_INVALID")),
    },
    targetCharacteristics: {
      state: candidate.targetCharacteristics.state,
      industryCodes: uniqueSorted(candidate.targetCharacteristics.industryCodes ?? [], (v) => canonicalCode(v, "MARKETROUTE_SELLER_GENOME_INDUSTRY_CODE_INVALID")),
      companySizeBands: uniqueSorted(candidate.targetCharacteristics.companySizeBands ?? [], (v) => canonicalCode(v, "MARKETROUTE_SELLER_GENOME_SIZE_BAND_INVALID")),
      businessModelCodes: uniqueSorted(candidate.targetCharacteristics.businessModelCodes ?? [], (v) => canonicalCode(v, "MARKETROUTE_SELLER_GENOME_BUSINESS_MODEL_INVALID")),
    },
    buyerAssumptions: {
      state: candidate.buyerAssumptions.state,
      roleCodes: uniqueSorted(candidate.buyerAssumptions.roleCodes ?? [], (v) => canonicalCode(v, "MARKETROUTE_SELLER_GENOME_ROLE_CODE_INVALID")),
      departmentCodes: uniqueSorted(candidate.buyerAssumptions.departmentCodes ?? [], (v) => canonicalCode(v, "MARKETROUTE_SELLER_GENOME_DEPARTMENT_CODE_INVALID")),
      painCodes: uniqueSorted(candidate.buyerAssumptions.painCodes ?? [], (v) => canonicalCode(v, "MARKETROUTE_SELLER_GENOME_PAIN_CODE_INVALID")),
    },
    constraints: { state: candidate.constraints.state, items: constraints.map((item) => item.semantic).sort((a, b) => a.constraintKey.localeCompare(b.constraintKey)) },
  } satisfies CanonicalSellerGenome["semantic"];

  const dimensionStates: Array<[SellerGenomeDimensionKey, SemanticDimensionState, string | null | undefined]> = [
    ["offerings", candidate.offerings.state, candidate.offerings.unknownQuestion],
    ["capabilities", candidate.capabilities.state, candidate.capabilities.unknownQuestion],
    ["commercialObjectives", candidate.commercialObjectives.state, candidate.commercialObjectives.unknownQuestion],
    ["delivery", candidate.delivery.state, candidate.delivery.unknownQuestion],
    ["serviceGeography", candidate.serviceGeography.state, candidate.serviceGeography.unknownQuestion],
    ["targetCharacteristics", candidate.targetCharacteristics.state, candidate.targetCharacteristics.unknownQuestion],
    ["buyerAssumptions", candidate.buyerAssumptions.state, candidate.buyerAssumptions.unknownQuestion],
    ["constraints", candidate.constraints.state, candidate.constraints.unknownQuestion],
  ];
  const missingDimensions = dimensionStates.filter(([, state]) => state === "UNKNOWN").map(([dimension]) => dimension);
  const explicitUnknowns: ExplicitSellerUnknown[] = dimensionStates
    .filter(([, state]) => state === "UNKNOWN")
    .map(([dimension, , question]) => ({ dimension, question: unknownQuestion(dimension, question) }));

  const canonical: CanonicalSellerGenome = {
    schemaVersion: SELLER_GENOME_SCHEMA_VERSION,
    canonicalisationVersion: SELLER_GENOME_CANONICALISATION_VERSION,
    sellerBusinessId,
    semantic,
    explanatory: {
      sellerDisplayName: displayName,
      offeringCopy: offerings.map((item) => ({ offeringKey: item.semantic.offeringKey, ...item.copy })).sort((a, b) => a.offeringKey.localeCompare(b.offeringKey)),
      capabilityCopy: capabilities.map((item) => ({ capabilityKey: item.semantic.capabilityKey, ...item.copy })).sort((a, b) => a.capabilityKey.localeCompare(b.capabilityKey)),
      objectiveCopy: objectives.map((item) => ({ objectiveKey: item.semantic.objectiveKey, ...item.copy })).sort((a, b) => a.objectiveKey.localeCompare(b.objectiveKey)),
      constraintCopy: constraints.map((item) => ({ constraintKey: item.semantic.constraintKey, ...item.copy })).sort((a, b) => a.constraintKey.localeCompare(b.constraintKey)),
      deliveryNotes: normaliseOptionalText(candidate.delivery.notes),
      geographyNotes: normaliseOptionalText(candidate.serviceGeography.notes),
      targetNotes: normaliseOptionalText(candidate.targetCharacteristics.notes),
      buyerNotes: normaliseOptionalText(candidate.buyerAssumptions.notes),
    },
    semanticCompleteness: missingDimensions.length === 0 ? "COMPLETE" : "PARTIAL",
    missingDimensions,
    explicitUnknowns,
  };

  // Force the complete result through the stable JSON serializer here so unsupported
  // values (undefined, NaN, functions) fail before persistence.
  stableJson(canonical);
  return canonical;
}

export function sellerGenomeSemanticIdentity(genome: CanonicalSellerGenome): string {
  return stableJson({
    schemaVersion: genome.schemaVersion,
    canonicalisationVersion: genome.canonicalisationVersion,
    sellerBusinessId: genome.sellerBusinessId,
    semantic: genome.semantic,
  });
}
