import type {
  SemanticOperationFailure,
  SemanticOperationId,
  SemanticOperationInput,
  SemanticOperationResult,
} from "../../core/ai/semantic-operation";
import {
  SEMANTIC_TELEMETRY_SCHEMA_VERSION,
  type SemanticOperationTelemetry,
  type SemanticUsageUnit,
} from "../../core/ai/semantic-telemetry";
import {
  SemanticProviderError,
  type SemanticProvider,
  type SemanticProviderExecution,
  type SemanticProviderTelemetryMetadata,
} from "../../platform/ai/semantic-provider";
import {
  normaliseSemanticEconomicAmount,
  normaliseSemanticTelemetryAttribution,
  type SemanticTelemetryContext,
  type SemanticTelemetrySink,
} from "./semantic-telemetry";

export interface SemanticExecutionPolicy {
  timeoutMs: number;
  maxAttempts: number;
  retryDelayMs: number;
}

export const MAX_SEMANTIC_TIMEOUT_MS = 120_000 as const;
export const MAX_SEMANTIC_ATTEMPTS = 3 as const;
export const MAX_SEMANTIC_RETRY_DELAY_MS = 5_000 as const;

export const DEFAULT_SEMANTIC_EXECUTION_POLICY: Readonly<SemanticExecutionPolicy> = Object.freeze({
  timeoutMs: 8_000,
  maxAttempts: 2,
  retryDelayMs: 150,
});

export interface SemanticExecutionDependencies {
  provider: SemanticProvider;
  telemetry: SemanticTelemetrySink;
  telemetryContext: SemanticTelemetryContext;
  policy?: Partial<SemanticExecutionPolicy>;
  sleep?: (milliseconds: number) => Promise<void>;
  nowMs?: () => number;
  nowDate?: () => Date;
}

interface AggregatedProviderTelemetry {
  modelIdentifier: string | null;
  inferenceProfileIdentifier: string | null;
  providerRequestId: string | null;
  usageUnit: SemanticUsageUnit;
  inputUnits: number | null;
  outputUnits: number | null;
}

const EMPTY_PROVIDER_TELEMETRY: AggregatedProviderTelemetry = {
  modelIdentifier: null,
  inferenceProfileIdentifier: null,
  providerRequestId: null,
  usageUnit: "UNKNOWN",
  inputUnits: null,
  outputUnits: null,
};

function normalisePolicy(overrides?: Partial<SemanticExecutionPolicy>): SemanticExecutionPolicy {
  const policy = { ...DEFAULT_SEMANTIC_EXECUTION_POLICY, ...overrides };
  if (!Number.isFinite(policy.timeoutMs) || policy.timeoutMs <= 0 || policy.timeoutMs > MAX_SEMANTIC_TIMEOUT_MS) {
    throw new Error("INVALID_SEMANTIC_TIMEOUT_POLICY");
  }
  if (!Number.isInteger(policy.maxAttempts) || policy.maxAttempts < 1 || policy.maxAttempts > MAX_SEMANTIC_ATTEMPTS) {
    throw new Error("INVALID_SEMANTIC_RETRY_POLICY");
  }
  if (!Number.isFinite(policy.retryDelayMs) || policy.retryDelayMs < 0 || policy.retryDelayMs > MAX_SEMANTIC_RETRY_DELAY_MS) {
    throw new Error("INVALID_SEMANTIC_RETRY_DELAY_POLICY");
  }
  return policy;
}

function toPublicFailure(error: unknown): SemanticOperationFailure {
  if (error instanceof SemanticProviderError) {
    if (error.code === "TIMEOUT") {
      return { code: "TIMEOUT", retryable: error.retryable, message: "Semantic operation timed out." };
    }
    if (error.code === "INVALID_RESPONSE") {
      return { code: "INVALID_PROVIDER_RESPONSE", retryable: error.retryable, message: "Semantic operation could not be completed." };
    }
    if (error.code === "UNSUPPORTED_OPERATION") {
      return { code: "OPERATION_NOT_SUPPORTED", retryable: false, message: "Semantic operation could not be completed." };
    }
    return { code: "PROVIDER_UNAVAILABLE", retryable: error.retryable, message: "Semantic operation could not be completed." };
  }
  return { code: "PROVIDER_UNAVAILABLE", retryable: false, message: "Semantic operation could not be completed." };
}

function addUnits(current: number | null, next: number | undefined): number | null {
  if (next === undefined) return current;
  if (!Number.isSafeInteger(next) || next < 0) throw new SemanticProviderError("INVALID_RESPONSE", false);
  return (current ?? 0) + next;
}

function mergeProviderTelemetry(
  current: AggregatedProviderTelemetry,
  next?: Readonly<SemanticProviderTelemetryMetadata>,
): AggregatedProviderTelemetry {
  if (!next) return current;
  return {
    modelIdentifier: next.modelIdentifier ?? current.modelIdentifier,
    inferenceProfileIdentifier: next.inferenceProfileIdentifier ?? current.inferenceProfileIdentifier,
    providerRequestId: next.providerRequestId ?? current.providerRequestId,
    usageUnit: next.usageUnit ?? current.usageUnit,
    inputUnits: addUnits(current.inputUnits, next.inputUnits),
    outputUnits: addUnits(current.outputUnits, next.outputUnits),
  };
}

async function executeAttempt<K extends SemanticOperationId>(
  operation: K,
  input: SemanticOperationInput<K>,
  provider: SemanticProvider,
  timeoutMs: number,
): Promise<SemanticProviderExecution<K>> {
  const controller = new AbortController();
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => {
      controller.abort();
      reject(new SemanticProviderError("TIMEOUT", true));
    }, timeoutMs);
  });

  try {
    return await Promise.race([provider.execute(operation, input, controller.signal), timeout]);
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}

function buildTelemetryEvent<K extends SemanticOperationId>(args: {
  operation: K;
  invocationTimestamp: string;
  providerTelemetry: AggregatedProviderTelemetry;
  attemptCount: number;
  success: boolean;
  failure: SemanticOperationFailure | null;
  latencyMs: number;
  context: SemanticTelemetryContext;
}): SemanticOperationTelemetry {
  return {
    schemaVersion: SEMANTIC_TELEMETRY_SCHEMA_VERSION,
    operationId: args.operation,
    invocationTimestamp: args.invocationTimestamp,
    modelIdentifier: args.providerTelemetry.modelIdentifier,
    inferenceProfileIdentifier: args.providerTelemetry.inferenceProfileIdentifier,
    providerRequestId: args.providerTelemetry.providerRequestId,
    usageUnit: args.providerTelemetry.usageUnit,
    inputUnits: args.providerTelemetry.inputUnits,
    outputUnits: args.providerTelemetry.outputUnits,
    attemptCount: args.attemptCount,
    retryCount: Math.max(0, args.attemptCount - 1),
    escalationTier: args.context.escalationTier,
    success: args.success,
    failureCode: args.failure?.code ?? null,
    latencyMs: Math.max(0, args.latencyMs),
    estimatedEquivalentCostUsd: normaliseSemanticEconomicAmount(
      args.context.estimatedEquivalentCostUsd,
      "estimatedEquivalentCostUsd",
    ),
    actualAttributedCostUsd: normaliseSemanticEconomicAmount(
      args.context.actualAttributedCostUsd,
      "actualAttributedCostUsd",
    ),
    creditFunding: args.context.creditFunding ?? "UNKNOWN",
    attribution: normaliseSemanticTelemetryAttribution(args.context),
  };
}

async function recordTelemetry(
  sink: SemanticTelemetrySink,
  event: SemanticOperationTelemetry,
): Promise<boolean> {
  try {
    await sink.record(event);
    return true;
  } catch {
    return false;
  }
}

function telemetryUnavailableFailure(): SemanticOperationFailure {
  return {
    code: "TELEMETRY_UNAVAILABLE",
    retryable: false,
    message: "Semantic operation could not be completed.",
  };
}

export async function executeSemanticOperation<K extends SemanticOperationId>(
  operation: K,
  input: SemanticOperationInput<K>,
  dependencies: SemanticExecutionDependencies,
): Promise<SemanticOperationResult<K>> {
  const policy = normalisePolicy(dependencies.policy);
  const sleep = dependencies.sleep ?? ((milliseconds: number) => new Promise<void>((resolve) => setTimeout(resolve, milliseconds)));
  const nowMs = dependencies.nowMs ?? Date.now;
  const nowDate = dependencies.nowDate ?? (() => new Date());
  const startedAtMs = nowMs();
  const invocationTimestamp = nowDate().toISOString();
  let providerTelemetry: AggregatedProviderTelemetry = { ...EMPTY_PROVIDER_TELEMETRY };
  let attemptCount = 0;

  for (let attempt = 1; attempt <= policy.maxAttempts; attempt += 1) {
    attemptCount = attempt;
    try {
      const execution = await executeAttempt(operation, input, dependencies.provider, policy.timeoutMs);
      providerTelemetry = mergeProviderTelemetry(providerTelemetry, execution.telemetry);
      const event = buildTelemetryEvent({
        operation,
        invocationTimestamp,
        providerTelemetry,
        attemptCount,
        success: true,
        failure: null,
        latencyMs: nowMs() - startedAtMs,
        context: dependencies.telemetryContext,
      });
      if (!(await recordTelemetry(dependencies.telemetry, event))) {
        return { ok: false, operation, error: telemetryUnavailableFailure() };
      }
      return { ok: true, operation, value: execution.value } as SemanticOperationResult<K>;
    } catch (error) {
      let effectiveError = error;
      if (error instanceof SemanticProviderError) {
        try {
          providerTelemetry = mergeProviderTelemetry(providerTelemetry, error.telemetry);
        } catch (telemetryMetadataError) {
          effectiveError = telemetryMetadataError;
        }
      }
      const failure = toPublicFailure(effectiveError);
      const shouldRetry = failure.retryable && attempt < policy.maxAttempts;
      if (shouldRetry) {
        if (policy.retryDelayMs > 0) await sleep(policy.retryDelayMs);
        continue;
      }

      const event = buildTelemetryEvent({
        operation,
        invocationTimestamp,
        providerTelemetry,
        attemptCount,
        success: false,
        failure,
        latencyMs: nowMs() - startedAtMs,
        context: dependencies.telemetryContext,
      });
      if (!(await recordTelemetry(dependencies.telemetry, event))) {
        return { ok: false, operation, error: telemetryUnavailableFailure() };
      }
      return { ok: false, operation, error: failure };
    }
  }

  const failure: SemanticOperationFailure = {
    code: "PROVIDER_UNAVAILABLE",
    retryable: false,
    message: "Semantic operation could not be completed.",
  };
  const event = buildTelemetryEvent({
    operation,
    invocationTimestamp,
    providerTelemetry,
    attemptCount,
    success: false,
    failure,
    latencyMs: nowMs() - startedAtMs,
    context: dependencies.telemetryContext,
  });
  if (!(await recordTelemetry(dependencies.telemetry, event))) {
    return { ok: false, operation, error: telemetryUnavailableFailure() };
  }
  return { ok: false, operation, error: failure };
}
