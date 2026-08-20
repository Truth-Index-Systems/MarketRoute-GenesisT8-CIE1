import type {
  SemanticOperationId,
  SemanticOperationInput,
  SemanticOperationOutput,
} from "../../core/ai/semantic-operation";
import type { SemanticUsageUnit } from "../../core/ai/semantic-telemetry";

export type SemanticProviderFailureCode =
  | "TIMEOUT"
  | "UNAVAILABLE"
  | "INVALID_RESPONSE"
  | "NOT_LIVE"
  | "UNSUPPORTED_OPERATION";

export interface SemanticProviderTelemetryMetadata {
  modelIdentifier?: string;
  inferenceProfileIdentifier?: string;
  providerRequestId?: string;
  usageUnit?: SemanticUsageUnit;
  inputUnits?: number;
  outputUnits?: number;
}

export interface SemanticProviderExecution<K extends SemanticOperationId> {
  value: SemanticOperationOutput<K>;
  telemetry?: Readonly<SemanticProviderTelemetryMetadata>;
}

export class SemanticProviderError extends Error {
  constructor(
    public readonly code: SemanticProviderFailureCode,
    public readonly retryable: boolean,
    public readonly telemetry?: Readonly<SemanticProviderTelemetryMetadata>,
  ) {
    super("MARKETROUTE_SEMANTIC_PROVIDER_FAILURE");
    this.name = "SemanticProviderError";
  }
}

export interface SemanticProvider {
  execute<K extends SemanticOperationId>(
    operation: K,
    input: SemanticOperationInput<K>,
    signal: AbortSignal,
  ): Promise<SemanticProviderExecution<K>>;
}
