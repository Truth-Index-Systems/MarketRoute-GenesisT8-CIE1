import type { SemanticCreditFunding } from "./semantic-telemetry";

export const MATURE_SEMANTIC_COGS_TARGET_MIN = 0.2 as const;
export const MATURE_SEMANTIC_COGS_TARGET_MAX = 0.3 as const;

export interface SemanticModelPricing {
  inputUsdPerMillionUnits: number;
  outputUsdPerMillionUnits: number;
  pricingBasis: string;
}

export interface SemanticTokenUsage {
  inputUnits: number;
  outputUnits: number;
}

export interface SemanticEconomicProjectionInput {
  operationCount: number;
  economicCostUsd: number;
  cashCostUsd: number | null;
  revenueUsd: number | null;
  creditFundingCounts: Readonly<Record<SemanticCreditFunding, number>>;
}

export type SemanticMarginState =
  | "NOT_EVALUABLE"
  | "BETTER_THAN_TARGET"
  | "WITHIN_TARGET"
  | "ABOVE_TARGET";

export interface SemanticEconomicProjection {
  operationCount: number;
  economicCostUsd: number;
  cashCostUsd: number | null;
  costPerOperationUsd: number;
  costPer100Usd: number;
  costPer1000Usd: number;
  revenueUsd: number | null;
  cogsRatio: number | null;
  grossMarginRatio: number | null;
  marginState: SemanticMarginState;
  matureCogsTarget: {
    minimum: typeof MATURE_SEMANTIC_COGS_TARGET_MIN;
    maximum: typeof MATURE_SEMANTIC_COGS_TARGET_MAX;
  };
  creditFundingCounts: Readonly<Record<SemanticCreditFunding, number>>;
}

function assertFiniteNonNegative(value: number, field: string): void {
  if (!Number.isFinite(value) || value < 0) throw new Error(`INVALID_SEMANTIC_ECONOMICS_${field}`);
}

function roundUsd(value: number): number {
  return Number(value.toFixed(8));
}

function roundRatio(value: number): number {
  return Number(value.toFixed(6));
}

export function estimateSemanticTokenCostUsd(
  usage: SemanticTokenUsage,
  pricing: SemanticModelPricing,
): number {
  if (!Number.isSafeInteger(usage.inputUnits) || usage.inputUnits < 0) {
    throw new Error("INVALID_SEMANTIC_ECONOMICS_INPUT_UNITS");
  }
  if (!Number.isSafeInteger(usage.outputUnits) || usage.outputUnits < 0) {
    throw new Error("INVALID_SEMANTIC_ECONOMICS_OUTPUT_UNITS");
  }
  assertFiniteNonNegative(pricing.inputUsdPerMillionUnits, "INPUT_PRICE");
  assertFiniteNonNegative(pricing.outputUsdPerMillionUnits, "OUTPUT_PRICE");
  if (pricing.pricingBasis.trim().length === 0) throw new Error("INVALID_SEMANTIC_ECONOMICS_PRICING_BASIS");

  const estimate =
    (usage.inputUnits / 1_000_000) * pricing.inputUsdPerMillionUnits +
    (usage.outputUnits / 1_000_000) * pricing.outputUsdPerMillionUnits;
  return roundUsd(estimate);
}

function marginStateFor(cogsRatio: number | null): SemanticMarginState {
  if (cogsRatio === null) return "NOT_EVALUABLE";
  if (cogsRatio < MATURE_SEMANTIC_COGS_TARGET_MIN) return "BETTER_THAN_TARGET";
  if (cogsRatio <= MATURE_SEMANTIC_COGS_TARGET_MAX) return "WITHIN_TARGET";
  return "ABOVE_TARGET";
}

export function projectSemanticEconomics(
  input: SemanticEconomicProjectionInput,
): SemanticEconomicProjection {
  if (!Number.isSafeInteger(input.operationCount) || input.operationCount <= 0) {
    throw new Error("INVALID_SEMANTIC_ECONOMICS_OPERATION_COUNT");
  }
  assertFiniteNonNegative(input.economicCostUsd, "ECONOMIC_COST");
  if (input.cashCostUsd !== null) assertFiniteNonNegative(input.cashCostUsd, "CASH_COST");
  if (input.revenueUsd !== null) assertFiniteNonNegative(input.revenueUsd, "REVENUE");

  const costPerOperationUsd = input.economicCostUsd / input.operationCount;
  const cogsRatio = input.revenueUsd !== null && input.revenueUsd > 0
    ? input.economicCostUsd / input.revenueUsd
    : null;
  const grossMarginRatio = cogsRatio === null ? null : 1 - cogsRatio;

  return {
    operationCount: input.operationCount,
    economicCostUsd: roundUsd(input.economicCostUsd),
    cashCostUsd: input.cashCostUsd === null ? null : roundUsd(input.cashCostUsd),
    costPerOperationUsd: roundUsd(costPerOperationUsd),
    costPer100Usd: roundUsd(costPerOperationUsd * 100),
    costPer1000Usd: roundUsd(costPerOperationUsd * 1_000),
    revenueUsd: input.revenueUsd === null ? null : roundUsd(input.revenueUsd),
    cogsRatio: cogsRatio === null ? null : roundRatio(cogsRatio),
    grossMarginRatio: grossMarginRatio === null ? null : roundRatio(grossMarginRatio),
    marginState: marginStateFor(cogsRatio),
    matureCogsTarget: {
      minimum: MATURE_SEMANTIC_COGS_TARGET_MIN,
      maximum: MATURE_SEMANTIC_COGS_TARGET_MAX,
    },
    creditFundingCounts: { ...input.creditFundingCounts },
  };
}
