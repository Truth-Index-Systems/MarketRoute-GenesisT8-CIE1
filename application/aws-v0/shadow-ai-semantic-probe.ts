import "server-only";

import { executeSemanticOperation } from "../ai/execute-semantic-operation";
import type { SemanticTelemetrySink } from "../ai/semantic-telemetry";
import { estimateSemanticTokenCostUsd } from "../../core/ai/semantic-economics";
import type { SemanticOperationFailureCode, SemanticProbeOutput } from "../../core/ai/semantic-operation";
import type { SemanticOperationTelemetry } from "../../core/ai/semantic-telemetry";
import { BedrockSemanticProvider } from "../../platform/ai/bedrock/bedrock-semantic-provider";
import { SONNET45_EU_GEO_PRICING } from "../../platform/ai/bedrock/bedrock-semantic-pricing";
import { getAwsV0BedrockSemanticInferenceProfileArn } from "./shadow-ai-runtime";

const SYNTHETIC_PROBE_INPUT = Object.freeze({
  subject: "Northstar Industrial Controls Ltd (synthetic)",
  context: "Fictional UK manufacturer of industrial temperature-monitoring components for food-processing plants. The description is synthetic and contains no customer or canonical MarketRoute data.",
  requestedTier: "B" as const,
});

// Build 7.5 certified these exact EU equivalent-cost constants. Build 7.8 keeps
// them as active compatibility guards while centralising the provider pricing
// object used by all semantic economics.
const SONNET45_EU_GEO_INPUT_USD_PER_MILLION_TOKENS = 3.3;
const SONNET45_EU_GEO_OUTPUT_USD_PER_MILLION_TOKENS = 16.5;

function assertCertifiedProbePricingBasis(): void {
  if (
    SONNET45_EU_GEO_PRICING.inputUsdPerMillionUnits !== SONNET45_EU_GEO_INPUT_USD_PER_MILLION_TOKENS ||
    SONNET45_EU_GEO_PRICING.outputUsdPerMillionUnits !== SONNET45_EU_GEO_OUTPUT_USD_PER_MILLION_TOKENS
  ) {
    throw new Error("AWS_V0_BUILD7_5_PRICING_BASIS_DRIFT");
  }
}

export interface AwsV0ShadowAiDiagnostics {
  usageUnit: "TOKEN" | "PROVIDER_UNIT" | "UNKNOWN";
  inputUnits: number | null;
  outputUnits: number | null;
  attemptCount: number;
  retryCount: number;
  escalationTier: "A" | "B" | "C";
  latencyMs: number;
  estimatedEquivalentCostUsd: number | null;
  actualAttributedCostUsd: number | null;
  creditFunding: "UNKNOWN" | "CREDIT_FUNDED" | "CASH_FUNDED" | "MIXED";
}

export type AwsV0ShadowSemanticProbeResult =
  | {
      ok: true;
      value: SemanticProbeOutput;
      diagnostics: AwsV0ShadowAiDiagnostics;
    }
  | {
      ok: false;
      failureCode: SemanticOperationFailureCode;
      diagnostics: AwsV0ShadowAiDiagnostics | null;
    };

function estimateEquivalentCost(event: Readonly<SemanticOperationTelemetry>): number | null {
  if (event.usageUnit !== "TOKEN" || event.inputUnits === null || event.outputUnits === null) return null;
  assertCertifiedProbePricingBasis();
  return estimateSemanticTokenCostUsd(
    { inputUnits: event.inputUnits, outputUnits: event.outputUnits },
    SONNET45_EU_GEO_PRICING,
  );
}

class InMemorySemanticProbeTelemetrySink implements SemanticTelemetrySink {
  private latest: SemanticOperationTelemetry | null = null;

  async record(event: Readonly<SemanticOperationTelemetry>): Promise<void> {
    this.latest = {
      ...event,
      estimatedEquivalentCostUsd: event.estimatedEquivalentCostUsd ?? estimateEquivalentCost(event),
    };
  }

  snapshot(): SemanticOperationTelemetry | null {
    return this.latest ? { ...this.latest, attribution: { ...this.latest.attribution } } : null;
  }
}

function sanitiseDiagnostics(event: SemanticOperationTelemetry | null): AwsV0ShadowAiDiagnostics | null {
  if (!event) return null;
  return {
    usageUnit: event.usageUnit,
    inputUnits: event.inputUnits,
    outputUnits: event.outputUnits,
    attemptCount: event.attemptCount,
    retryCount: event.retryCount,
    escalationTier: event.escalationTier,
    latencyMs: event.latencyMs,
    estimatedEquivalentCostUsd: event.estimatedEquivalentCostUsd,
    actualAttributedCostUsd: event.actualAttributedCostUsd,
    creditFunding: event.creditFunding,
  };
}

export async function runAwsV0SyntheticSemanticProbe(): Promise<AwsV0ShadowSemanticProbeResult> {
  const telemetry = new InMemorySemanticProbeTelemetrySink();
  const provider = new BedrockSemanticProvider({
    inferenceProfileArn: getAwsV0BedrockSemanticInferenceProfileArn(),
  });

  try {
    const result = await executeSemanticOperation("ai.semanticProbe", SYNTHETIC_PROBE_INPUT, {
      provider,
      telemetry,
      telemetryContext: {
        escalationTier: "B",
        attribution: {
          customerId: null,
          workloadId: "aws-v0-build7.5-semantic-probe",
        },
        estimatedEquivalentCostUsd: null,
        actualAttributedCostUsd: null,
        creditFunding: "UNKNOWN",
      },
      policy: {
        timeoutMs: 60_000,
        maxAttempts: 2,
        retryDelayMs: 500,
      },
    });
    const diagnostics = sanitiseDiagnostics(telemetry.snapshot());
    if (!result.ok) return { ok: false, failureCode: result.error.code, diagnostics };
    if (!diagnostics) return { ok: false, failureCode: "TELEMETRY_UNAVAILABLE", diagnostics: null };
    return { ok: true, value: result.value, diagnostics };
  } finally {
    provider.destroy();
  }
}
