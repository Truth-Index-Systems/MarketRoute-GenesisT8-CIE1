import type { IntelligenceTier } from "../../core/ai/semantic-operation";
import type {
  SemanticCreditFunding,
  SemanticOperationTelemetry,
  SemanticTelemetryAttribution,
} from "../../core/ai/semantic-telemetry";

export interface SemanticTelemetrySink {
  record(event: Readonly<SemanticOperationTelemetry>): Promise<void>;
}

export interface SemanticTelemetryContext {
  escalationTier: IntelligenceTier;
  attribution?: Partial<Omit<SemanticTelemetryAttribution, "product">>;
  estimatedEquivalentCostUsd?: number | null;
  actualAttributedCostUsd?: number | null;
  creditFunding?: SemanticCreditFunding;
}

export function normaliseSemanticTelemetryAttribution(
  context: SemanticTelemetryContext,
): SemanticTelemetryAttribution {
  return {
    product: "MarketRoute",
    customerId: context.attribution?.customerId ?? null,
    workloadId: context.attribution?.workloadId ?? null,
  };
}

export function normaliseSemanticEconomicAmount(
  value: number | null | undefined,
  field: "estimatedEquivalentCostUsd" | "actualAttributedCostUsd",
): number | null {
  if (value === null || value === undefined) return null;
  if (!Number.isFinite(value) || value < 0) {
    throw new Error(`INVALID_SEMANTIC_TELEMETRY_${field.toUpperCase()}`);
  }
  return value;
}
