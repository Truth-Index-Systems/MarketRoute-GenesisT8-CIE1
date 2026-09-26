import { createHash } from "node:crypto";
import { AwsV0ResearchExecutionError, parseCompanyUnderstandingOutput } from "./executor.mjs";
import { COMPANY_UNDERSTANDING_JSON_SCHEMA, COMPANY_UNDERSTANDING_SYSTEM_INSTRUCTION,
  companyUnderstandingPrompt } from "./request-contract.mjs";

export const MODEL_ID = "anthropic.claude-sonnet-4-5-20250929-v1:0";
const MAX_OUTPUT_TOKENS = 1400;
const RETRYABLE = new Set(["ThrottlingException", "ServiceUnavailableException",
  "InternalServerException", "ModelTimeoutException"]);
const err = (code, retryable = false, telemetry = {}) =>
  new AwsV0ResearchExecutionError(`MARKETROUTE_AWS_V0_${code}`, retryable, telemetry);

export function nativeCompanyRequest(input) {
  return JSON.stringify({
    anthropic_version: "bedrock-2023-05-31",
    system: COMPANY_UNDERSTANDING_SYSTEM_INSTRUCTION,
    messages: [{ role: "user", content: [{ type: "text", text: companyUnderstandingPrompt(input) }] }],
    max_tokens: MAX_OUTPUT_TOKENS,
    temperature: 0,
    output_config: { format: { type: "json_schema", schema: JSON.parse(COMPANY_UNDERSTANDING_JSON_SCHEMA) } },
  });
}

function usageFromResponse(value) {
  const u = value?.usage;
  if (!u || !Number.isSafeInteger(u.input_tokens) || u.input_tokens < 0
      || !Number.isSafeInteger(u.output_tokens) || u.output_tokens < 0
      || (u.cache_creation_input_tokens ?? 0) !== 0 || (u.cache_read_input_tokens ?? 0) !== 0) return null;
  return { inputUnits: u.input_tokens, outputUnits: u.output_tokens };
}

// Transport injection is used only by credential-free tests. Production uses a
// single-attempt SDK client, with no fallback model, endpoint or implicit retry.
export async function createPreparedBedrockProvider(options = {}) {
  const region = options.region ?? process.env.AWS_REGION;
  const profileArn = options.profileArn ?? process.env.MARKETROUTE_AWS_BEDROCK_INFERENCE_PROFILE_ARN;
  if (region !== "eu-west-2" || typeof profileArn !== "string"
      || !/^arn:aws:bedrock:eu-west-2:801132668416:application-inference-profile\/[A-Za-z0-9-]+$/.test(profileArn)) {
    throw err("ADMISSION_PROVIDER_CONFIGURATION_INVALID");
  }
  let transport = options.transport;
  if (!transport) {
    const sdk = await import("@aws-sdk/client-bedrock-runtime");
    const client = new sdk.BedrockRuntimeClient({ region, maxAttempts: 1 });
    transport = {
      count: (body, signal) => client.send(new sdk.CountTokensCommand({
        modelId: MODEL_ID, input: { invokeModel: { body } },
      }), { abortSignal: signal }),
      invoke: (body, signal) => client.send(new sdk.InvokeModelCommand({
        modelId: profileArn, body, contentType: "application/json", accept: "application/json",
      }), { abortSignal: signal }),
      destroy: () => client.destroy(),
    };
  }
  const prepared = new WeakMap();
  return {
    async prepare(input) {
      const snapshot = structuredClone(input);
      const body = Buffer.from(nativeCompanyRequest(snapshot), "utf8");
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 15_000);
      try {
        const response = await transport.count(body, controller.signal);
        const tokens = response.inputTokens;
        if (!Number.isSafeInteger(tokens) || tokens <= 0 || tokens + MAX_OUTPUT_TOKENS > 200_000) {
          throw err("ADMISSION_TOKEN_COUNT_INVALID");
        }
        const plan = Object.freeze({
          inputTokens: tokens, maxOutputTokens: MAX_OUTPUT_TOKENS, profileArn,
          requestFingerprint: createHash("sha256").update(body).digest("hex"),
        });
        prepared.set(plan, { body, input: snapshot });
        return plan;
      } finally { clearTimeout(timer); }
    },
    async executePrepared(plan) {
      const request = prepared.get(plan);
      if (!request) throw err("ADMISSION_PREPARED_REQUEST_REQUIRED");
      prepared.delete(plan); // A lost network response never permits reuse.
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 120_000);
      const startedAt = Date.now();
      let telemetry = { provider: "AWS_BEDROCK", modelIdentifier: MODEL_ID,
        inferenceProfileIdentifier: profileArn, usageUnit: "TOKEN", requestFingerprint: plan.requestFingerprint };
      try {
        const response = await transport.invoke(request.body, controller.signal);
        telemetry = { ...telemetry, providerRequestId: response.$metadata?.requestId ?? null,
          latencyMs: Math.max(0, Date.now() - startedAt) };
        let decoded;
        try { decoded = JSON.parse(Buffer.from(response.body).toString("utf8")); }
        catch { throw err("BEDROCK_INVALID_RESPONSE", false, telemetry); }
        const usage = usageFromResponse(decoded);
        if (!usage) throw err("BEDROCK_USAGE_INVALID", false, telemetry);
        // Preserve measured usage BEFORE output validation can reject the result.
        telemetry = { ...telemetry, ...usage };
        const text = decoded.content?.find((block) => block?.type === "text" && typeof block.text === "string")?.text;
        let value;
        try { value = parseCompanyUnderstandingOutput(JSON.parse(text), request.input); }
        catch { value = null; }
        if (!value || decoded.stop_reason !== "end_turn") throw err("BEDROCK_INVALID_RESPONSE", false, telemetry);
        return { value, telemetry };
      } catch (error) {
        if (error instanceof AwsV0ResearchExecutionError) throw error;
        const name = controller.signal.aborted ? "ModelTimeoutException" : (error?.name ?? "UnknownError");
        throw err(`BEDROCK_${String(name).replace(/[^A-Za-z0-9_.-]/g, "_").slice(0, 100)}`,
          RETRYABLE.has(name) || Number(error?.$metadata?.httpStatusCode) >= 500,
          { ...telemetry, latencyMs: Math.max(0, Date.now() - startedAt),
            providerRequestId: error?.$metadata?.requestId ?? telemetry.providerRequestId ?? null });
      } finally { clearTimeout(timer); }
    },
    destroy() { transport.destroy?.(); },
  };
}
