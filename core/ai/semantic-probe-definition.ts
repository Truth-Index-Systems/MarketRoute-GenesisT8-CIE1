import type { SemanticProbeInput, SemanticProbeOutput, SemanticUncertainty } from "./semantic-operation";

export const SEMANTIC_PROBE_SCHEMA_NAME = "marketroute_semantic_probe_v1" as const;

export const SEMANTIC_PROBE_JSON_SCHEMA = JSON.stringify({
  type: "object",
  properties: {
    interpretation: { type: "string", description: "Concise semantic interpretation of the supplied synthetic business context." },
    labels: { type: "array", items: { type: "string" }, description: "Neutral semantic labels grounded only in the supplied context." },
    uncertainty: { type: "string", enum: ["low", "medium", "high"], description: "Semantic uncertainty only; never a commercial score." },
    unresolvedQuestions: { type: "array", items: { type: "string" }, description: "Important semantic questions that cannot be answered from the supplied context." },
  },
  required: ["interpretation", "labels", "uncertainty", "unresolvedQuestions"],
  additionalProperties: false,
});

export const SEMANTIC_PROBE_SYSTEM_INSTRUCTION = [
  "You are MarketRoute's semantic interpretation layer.",
  "Interpret only the supplied synthetic business description.",
  "Do not invent evidence or facts.",
  "Do not score or rank opportunities, routes, contacts, organisations, or execution decisions.",
  "Do not perform Truth Index, CIE, UDOSIB, or deterministic commercial mathematics.",
  "Return only the JSON object required by the supplied structured-output schema.",
].join(" ");

export function buildSemanticProbeUserPrompt(input: SemanticProbeInput): string {
  return [
    `Subject: ${input.subject}`,
    `Context: ${input.context ?? "No additional context supplied."}`,
    `Requested intelligence tier: ${input.requestedTier ?? "B"}`,
    "Produce a semantic interpretation, neutral labels, uncertainty, and unresolved questions.",
  ].join("\n");
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function boundedString(value: unknown, maximumLength: number): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (trimmed.length === 0 || trimmed.length > maximumLength) return null;
  return trimmed;
}

function boundedStringArray(value: unknown, maximumItems: number, maximumItemLength: number): string[] | null {
  if (!Array.isArray(value) || value.length > maximumItems) return null;
  const output: string[] = [];
  for (const item of value) {
    const parsed = boundedString(item, maximumItemLength);
    if (parsed === null) return null;
    output.push(parsed);
  }
  return output;
}

function isUncertainty(value: unknown): value is SemanticUncertainty {
  return value === "low" || value === "medium" || value === "high";
}

export function parseSemanticProbeOutput(value: unknown): SemanticProbeOutput | null {
  if (!isRecord(value)) return null;
  const allowedKeys = new Set(["interpretation", "labels", "uncertainty", "unresolvedQuestions"]);
  if (Object.keys(value).some((key) => !allowedKeys.has(key))) return null;

  const interpretation = boundedString(value.interpretation, 2_000);
  const labels = boundedStringArray(value.labels, 12, 120);
  const unresolvedQuestions = boundedStringArray(value.unresolvedQuestions, 8, 300);
  if (interpretation === null || labels === null || unresolvedQuestions === null || !isUncertainty(value.uncertainty)) {
    return null;
  }

  return {
    interpretation,
    labels,
    uncertainty: value.uncertainty,
    unresolvedQuestions,
  };
}
