import type {
  IntelligenceTier,
  SemanticOperationFailureCode,
  SemanticOperationId,
} from "./semantic-operation";

export const SEMANTIC_TELEMETRY_SCHEMA_VERSION = "1" as const;

export type SemanticUsageUnit = "TOKEN" | "PROVIDER_UNIT" | "UNKNOWN";
export type SemanticCreditFunding = "UNKNOWN" | "CREDIT_FUNDED" | "CASH_FUNDED" | "MIXED";

export interface SemanticTelemetryAttribution {
  product: "MarketRoute";
  customerId: string | null;
  workloadId: string | null;
}

export interface SemanticOperationTelemetry {
  schemaVersion: typeof SEMANTIC_TELEMETRY_SCHEMA_VERSION;
  operationId: SemanticOperationId;
  invocationTimestamp: string;
  modelIdentifier: string | null;
  inferenceProfileIdentifier: string | null;
  providerRequestId: string | null;
  usageUnit: SemanticUsageUnit;
  inputUnits: number | null;
  outputUnits: number | null;
  attemptCount: number;
  retryCount: number;
  escalationTier: IntelligenceTier;
  success: boolean;
  failureCode: SemanticOperationFailureCode | null;
  latencyMs: number;
  estimatedEquivalentCostUsd: number | null;
  actualAttributedCostUsd: number | null;
  creditFunding: SemanticCreditFunding;
  attribution: SemanticTelemetryAttribution;
}
