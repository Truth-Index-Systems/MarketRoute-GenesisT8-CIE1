import type {
  SemanticOperationFailure,
  SemanticOperationId,
  SemanticOperationInput,
  SemanticOperationResult,
} from "../../core/ai/semantic-operation";
import {
  SemanticProviderError,
  type SemanticProvider,
} from "../../platform/ai/semantic-provider";

export interface SemanticExecutionPolicy {
  timeoutMs: number;
  maxAttempts: number;
  retryDelayMs: number;
}

export const DEFAULT_SEMANTIC_EXECUTION_POLICY: Readonly<SemanticExecutionPolicy> = Object.freeze({
  timeoutMs: 8_000,
  maxAttempts: 2,
  retryDelayMs: 150,
});

export interface SemanticExecutionDependencies {
  provider: SemanticProvider;
  policy?: Partial<SemanticExecutionPolicy>;
  sleep?: (milliseconds: number) => Promise<void>;
}

function normalisePolicy(overrides?: Partial<SemanticExecutionPolicy>): SemanticExecutionPolicy {
  const policy = { ...DEFAULT_SEMANTIC_EXECUTION_POLICY, ...overrides };
  if (!Number.isFinite(policy.timeoutMs) || policy.timeoutMs <= 0) throw new Error("INVALID_SEMANTIC_TIMEOUT_POLICY");
  if (!Number.isInteger(policy.maxAttempts) || policy.maxAttempts < 1 || policy.maxAttempts > 3) {
    throw new Error("INVALID_SEMANTIC_RETRY_POLICY");
  }
  if (!Number.isFinite(policy.retryDelayMs) || policy.retryDelayMs < 0) throw new Error("INVALID_SEMANTIC_RETRY_DELAY_POLICY");
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

async function executeAttempt<K extends SemanticOperationId>(
  operation: K,
  input: SemanticOperationInput<K>,
  provider: SemanticProvider,
  timeoutMs: number,
): Promise<Awaited<ReturnType<SemanticProvider["execute"]>>> {
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

export async function executeSemanticOperation<K extends SemanticOperationId>(
  operation: K,
  input: SemanticOperationInput<K>,
  dependencies: SemanticExecutionDependencies,
): Promise<SemanticOperationResult<K>> {
  const policy = normalisePolicy(dependencies.policy);
  const sleep = dependencies.sleep ?? ((milliseconds: number) => new Promise<void>((resolve) => setTimeout(resolve, milliseconds)));

  for (let attempt = 1; attempt <= policy.maxAttempts; attempt += 1) {
    try {
      const value = await executeAttempt(operation, input, dependencies.provider, policy.timeoutMs);
      return { ok: true, operation, value } as SemanticOperationResult<K>;
    } catch (error) {
      const failure = toPublicFailure(error);
      const shouldRetry = failure.retryable && attempt < policy.maxAttempts;
      if (!shouldRetry) return { ok: false, operation, error: failure };
      if (policy.retryDelayMs > 0) await sleep(policy.retryDelayMs);
    }
  }

  return {
    ok: false,
    operation,
    error: { code: "PROVIDER_UNAVAILABLE", retryable: false, message: "Semantic operation could not be completed." },
  };
}
