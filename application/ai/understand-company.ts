import type {
  CompanyUnderstandingEvidence,
  CompanyUnderstandingInput,
  SemanticEvidenceSourceType,
  SemanticOperationResult,
} from "../../core/ai/semantic-operation";
import {
  executeSemanticOperation,
  type SemanticExecutionDependencies,
} from "./execute-semantic-operation";

const EVIDENCE_ID_PATTERN = /^[A-Za-z0-9._:-]{1,120}$/;
const ALLOWED_SOURCE_TYPES = new Set<SemanticEvidenceSourceType>([
  "WEBSITE",
  "REGISTRY",
  "DOCUMENT",
  "DATASET",
  "OTHER",
]);

function normaliseRequiredString(value: string, field: string, maximumLength: number): string {
  const trimmed = value.trim();
  if (trimmed.length === 0 || trimmed.length > maximumLength) {
    throw new Error(`INVALID_COMPANY_UNDERSTANDING_${field}`);
  }
  return trimmed;
}

function normaliseObservedAt(value: string | undefined): string | undefined {
  if (value === undefined) return undefined;
  const trimmed = value.trim();
  if (trimmed.length === 0 || trimmed.length > 80) throw new Error("INVALID_COMPANY_UNDERSTANDING_OBSERVED_AT");
  const parsed = Date.parse(trimmed);
  if (!Number.isFinite(parsed)) throw new Error("INVALID_COMPANY_UNDERSTANDING_OBSERVED_AT");
  return new Date(parsed).toISOString();
}

function normaliseEvidence(evidence: readonly CompanyUnderstandingEvidence[]): CompanyUnderstandingEvidence[] {
  if (!Array.isArray(evidence) || evidence.length === 0 || evidence.length > 40) {
    throw new Error("INVALID_COMPANY_UNDERSTANDING_EVIDENCE_COUNT");
  }

  const seenEvidenceIds = new Set<string>();
  return evidence.map((item) => {
    const evidenceId = item.evidenceId.trim();
    if (!EVIDENCE_ID_PATTERN.test(evidenceId) || seenEvidenceIds.has(evidenceId)) {
      throw new Error("INVALID_COMPANY_UNDERSTANDING_EVIDENCE_ID");
    }
    seenEvidenceIds.add(evidenceId);

    if (!ALLOWED_SOURCE_TYPES.has(item.sourceType)) {
      throw new Error("INVALID_COMPANY_UNDERSTANDING_SOURCE_TYPE");
    }

    return {
      evidenceId,
      sourceType: item.sourceType,
      statement: normaliseRequiredString(item.statement, "EVIDENCE_STATEMENT", 4_000),
      observedAt: normaliseObservedAt(item.observedAt),
    };
  });
}

export function normaliseCompanyUnderstandingInput(input: CompanyUnderstandingInput): CompanyUnderstandingInput {
  return {
    companyName: normaliseRequiredString(input.companyName, "COMPANY_NAME", 300),
    evidence: normaliseEvidence(input.evidence),
    requestedTier: input.requestedTier ?? "B",
  };
}

export async function understandCompanyFromEvidence(
  input: CompanyUnderstandingInput,
  dependencies: SemanticExecutionDependencies,
): Promise<SemanticOperationResult<"ai.companyUnderstanding">> {
  const normalisedInput = normaliseCompanyUnderstandingInput(input);
  return executeSemanticOperation("ai.companyUnderstanding", normalisedInput, dependencies);
}
