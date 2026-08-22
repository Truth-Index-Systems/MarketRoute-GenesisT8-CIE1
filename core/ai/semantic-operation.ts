export type SemanticOperationId = "ai.semanticProbe" | "ai.companyUnderstanding";

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

export type SemanticEvidenceSourceType = "WEBSITE" | "REGISTRY" | "DOCUMENT" | "DATASET" | "OTHER";

export interface CompanyUnderstandingEvidence {
  evidenceId: string;
  sourceType: SemanticEvidenceSourceType;
  statement: string;
  observedAt?: string;
}

export interface CompanyUnderstandingInput {
  companyName: string;
  evidence: CompanyUnderstandingEvidence[];
  requestedTier?: IntelligenceTier;
}

export interface GroundedSemanticStatement {
  text: string;
  evidenceIds: string[];
}

export interface CompanyUnderstandingOutput {
  overview: GroundedSemanticStatement;
  businessActivities: GroundedSemanticStatement[];
  offerings: GroundedSemanticStatement[];
  customerTypes: GroundedSemanticStatement[];
  operatingSignals: GroundedSemanticStatement[];
  uncertainty: SemanticUncertainty;
  unresolvedQuestions: string[];
}

export interface SemanticOperationMap {
  "ai.semanticProbe": {
    input: SemanticProbeInput;
    output: SemanticProbeOutput;
  };
  "ai.companyUnderstanding": {
    input: CompanyUnderstandingInput;
    output: CompanyUnderstandingOutput;
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
