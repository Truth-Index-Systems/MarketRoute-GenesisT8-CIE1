export type SemanticOperationId = "ai.semanticProbe";

export type IntelligenceTier = "A" | "B" | "C";
export type SemanticUncertainty = "low" | "medium" | "high";

export interface SemanticProbeInput {
  subject: string;
  context?: string;
  requestedTier?: IntelligenceTier;
}

export interface SemanticProbeOutput {
  interpretation: string;
  labels: string[];
  uncertainty: SemanticUncertainty;
  unresolvedQuestions: string[];
}

export interface SemanticOperationMap {
  "ai.semanticProbe": {
    input: SemanticProbeInput;
    output: SemanticProbeOutput;
  };
}

export type SemanticOperationInput<K extends SemanticOperationId> = SemanticOperationMap[K]["input"];
export type SemanticOperationOutput<K extends SemanticOperationId> = SemanticOperationMap[K]["output"];

export type SemanticOperationFailureCode =
  | "TIMEOUT"
  | "PROVIDER_UNAVAILABLE"
  | "INVALID_PROVIDER_RESPONSE"
  | "OPERATION_NOT_SUPPORTED"
  | "TELEMETRY_UNAVAILABLE";

export interface SemanticOperationFailure {
  code: SemanticOperationFailureCode;
  retryable: boolean;
  message: "Semantic operation timed out." | "Semantic operation could not be completed.";
}

export type SemanticOperationResult<K extends SemanticOperationId> =
  | {
      ok: true;
      operation: K;
      value: SemanticOperationOutput<K>;
    }
  | {
      ok: false;
      operation: K;
      error: SemanticOperationFailure;
    };
