import type {
  SemanticOperationId,
  SemanticOperationInput,
  SemanticOperationOutput,
} from "../../core/ai/semantic-operation";

export type SemanticProviderFailureCode =
  | "TIMEOUT"
  | "UNAVAILABLE"
  | "INVALID_RESPONSE"
  | "NOT_LIVE"
  | "UNSUPPORTED_OPERATION";

export class SemanticProviderError extends Error {
  constructor(
    public readonly code: SemanticProviderFailureCode,
    public readonly retryable: boolean,
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
  ): Promise<SemanticOperationOutput<K>>;
}
