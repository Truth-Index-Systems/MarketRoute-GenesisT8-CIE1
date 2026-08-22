import {
  estimateSemanticTokenCostUsd,
  projectSemanticEconomics,
  type SemanticEconomicProjection,
  type SemanticModelPricing,
} from "../../core/ai/semantic-economics";
import type {
  SemanticCreditFunding,
  SemanticOperationTelemetry,
} from "../../core/ai/semantic-telemetry";

export interface SemanticMarginProofInput {
  events: readonly SemanticOperationTelemetry[];
  pricing: SemanticModelPricing;
  revenueUsd?: number | null;
}

export interface SemanticMarginProof {
  totalOperationCount: number;
  pricedOperationCount: number;
  unpricedOperationCount: number;
  cashAttributedOperationCount: number;
  completeEconomicCoverage: boolean;
  completeCashCoverage: boolean;
  projection: SemanticEconomicProjection | null;
}

function newFundingCounts(): Record<SemanticCreditFunding, number> {
  return {
    UNKNOWN: 0,
    CREDIT_FUNDED: 0,
    CASH_FUNDED: 0,
    MIXED: 0,
  };
}

function incrementFundingCount(
  counts: Record<SemanticCreditFunding, number>,
  funding: unknown,
): void {
  switch (funding) {
    case "UNKNOWN":
    case "CREDIT_FUNDED":
    case "CASH_FUNDED":
    case "MIXED":
      counts[funding] += 1;
      return;
    default:
      throw new Error("INVALID_SEMANTIC_ECONOMICS_CREDIT_FUNDING");
  }
}

function economicCostFor(
  event: Readonly<SemanticOperationTelemetry>,
  pricing: SemanticModelPricing,
): number | null {
  if (event.estimatedEquivalentCostUsd !== null) return event.estimatedEquivalentCostUsd;
  if (event.usageUnit !== "TOKEN" || event.inputUnits === null || event.outputUnits === null) return null;
  return estimateSemanticTokenCostUsd(
    { inputUnits: event.inputUnits, outputUnits: event.outputUnits },
    pricing,
  );
}

export function buildSemanticMarginProof(input: SemanticMarginProofInput): SemanticMarginProof {
  if (!Array.isArray(input.events) || input.events.length === 0) {
    throw new Error("SEMANTIC_MARGIN_PROOF_REQUIRES_EVENTS");
  }

  const fundingCounts = newFundingCounts();
  let economicCostUsd = 0;
  let cashCostUsd = 0;
  let pricedOperationCount = 0;
  let cashAttributedOperationCount = 0;

  for (const event of input.events) {
    incrementFundingCount(fundingCounts, event.creditFunding);

    const economicCost = economicCostFor(event, input.pricing);
    if (economicCost !== null) {
      economicCostUsd += economicCost;
      pricedOperationCount += 1;
    }

    if (event.actualAttributedCostUsd !== null) {
      cashCostUsd += event.actualAttributedCostUsd;
      cashAttributedOperationCount += 1;
    }
  }

  const totalOperationCount = input.events.length;
  const unpricedOperationCount = totalOperationCount - pricedOperationCount;
  const completeEconomicCoverage = pricedOperationCount === totalOperationCount;
  const completeCashCoverage = cashAttributedOperationCount === totalOperationCount;

  const projection = completeEconomicCoverage
    ? projectSemanticEconomics({
        operationCount: totalOperationCount,
        economicCostUsd,
        cashCostUsd: completeCashCoverage ? cashCostUsd : null,
        revenueUsd: input.revenueUsd ?? null,
        creditFundingCounts: fundingCounts,
      })
    : null;

  return {
    totalOperationCount,
    pricedOperationCount,
    unpricedOperationCount,
    cashAttributedOperationCount,
    completeEconomicCoverage,
    completeCashCoverage,
    projection,
  };
}
