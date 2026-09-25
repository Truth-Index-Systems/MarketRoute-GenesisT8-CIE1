import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";
import { createPreparedBedrockProvider } from "../../infrastructure/aws-v0/runtime/research-worker/prepared-provider.mjs";
import * as contract from "../../infrastructure/aws-v0/runtime/research-worker/request-contract.mjs";
import { executeResearchEnvelope } from "../../infrastructure/aws-v0/runtime/research-worker/admitted-executor.mjs";

const profileArn = "arn:aws:bedrock:eu-west-2:801132668416:application-inference-profile/1t6o6h9xl4qb";
const evidenceId = "55555555-5555-4555-8555-555555555555";
const input = { companyName: "Synthetic company", requestedTier: "B", evidence: [
  { evidenceId, sourceType: "WEBSITE", statement: "Synthetic company makes sensors.", observedAt: "2026-09-25T12:00:00.000Z" },
] };
const value = { overview: { text: "Synthetic company makes sensors.", evidenceIds: [evidenceId] },
  businessActivities: [], offerings: [], customerTypes: [], operatingSignals: [], uncertainty: "medium", unresolvedQuestions: [] };
const envelope = { schemaVersion: "1", transport: "AWS_SQS", workUnitId: "11111111-1111-4111-8111-111111111111",
  organisationId: "22222222-2222-4222-8222-222222222222", campaignId: "33333333-3333-4333-8333-333333333333",
  companyId: "44444444-4444-4444-8444-444444444444", dedupeKey: "a".repeat(64),
  workUnit: { action: "SYNTHESIZE_COMPANY_UNDERSTANDING", costCeilingUsd: 0.1, payload: { metadata: {
    awsV0Executor: { contractVersion: "MR-AWS-V0-COMPANY-UNDERSTANDING-1.0.0", operation: "ai.companyUnderstanding", input },
  } } } };
const tests = [];
const test = (name, fn) => tests.push([name, fn]);
function transport(options = {}) {
  return { counts: 0, calls: 0, countedBody: null, invokedBody: null,
    async count(body) { this.counts++; this.countedBody = Buffer.from(body); return { inputTokens: options.tokens ?? 1000 }; },
    async invoke(body) { this.calls++; this.invokedBody = Buffer.from(body);
      return { body: Buffer.from(JSON.stringify({ content: [{ type: "text", text: options.text ?? JSON.stringify(value) }],
        stop_reason: options.stopReason ?? "end_turn", usage: options.usage ?? { input_tokens: 1000, output_tokens: 100 } })),
        $metadata: { requestId: "test-only" } }; }, destroy() {} };
}
const prepared = (t) => createPreparedBedrockProvider({ region: "eu-west-2", profileArn, transport: t });
function dependencies(overrides = {}) {
  const events = [], records = [];
  return { events, records,
    ledger: { async claim() { return { outcome: "CLAIMED", attemptCount: 1 }; },
      async complete(_w, _f, _id, result, telemetry) { events.push("complete"); records.push({ result, telemetry }); return "d".repeat(64); },
      async sync() { return "SYNCED"; }, async fail() { events.push("fail"); return "FAILED_TERMINAL"; },
      async syncFailure() { return "FAILED_SYNCED"; }, destroy() {} },
    provider: { async prepare() { events.push("prepare"); return { inputTokens: 1000, maxOutputTokens: 1400, profileArn, requestFingerprint: "b".repeat(64) }; },
      async executePrepared() { events.push("invoke"); return { value, telemetry: { inputUnits: 1000, outputUnits: 100 } }; }, destroy() {} },
    admission: { async preflight() { return { outcome: "READY" }; },
      async admit() { return { outcome: "ADMITTED", admissionId: "test-admission", reservedCostUsd: 0.0264, startBefore: new Date(Date.now() + 1000).toISOString() }; },
      async defer() { events.push("defer"); return true; },
      async settle(_id, _worker, _fp, outcome) { events.push(`settle:${outcome}`); return { withinReservation: true, accountedCostUsd: 0.0099, attemptCostUsd: 0.00495, usageState: outcome }; }, destroy() {} }, ...overrides };
}

test("frozen prompt, JSON schema and evidence rendering retain byte parity", () => {
  const legacy = fs.readFileSync("infrastructure/aws-v0/runtime/research-worker/executor.mjs", "utf8");
  const declarations = legacy.slice(legacy.indexOf("const GROUNDED_STATEMENT_SCHEMA"), legacy.indexOf("export class AwsV0ResearchExecutionError"));
  const prompt = legacy.slice(legacy.indexOf("function companyUnderstandingPrompt"), legacy.indexOf("\nfunction requiredEnvironment"));
  const expected = vm.runInNewContext(`${declarations}\n${prompt}\n[COMPANY_UNDERSTANDING_JSON_SCHEMA, COMPANY_UNDERSTANDING_SYSTEM_INSTRUCTION, companyUnderstandingPrompt(input)]`, { input });
  assert.equal(contract.COMPANY_UNDERSTANDING_JSON_SCHEMA, expected[0]);
  assert.equal(contract.COMPANY_UNDERSTANDING_SYSTEM_INSTRUCTION, expected[1]);
  assert.equal(contract.companyUnderstandingPrompt(input), expected[2]);
});
test("CountTokens and InvokeModel receive identical immutable request bytes", async () => {
  const t = transport(), p = await prepared(t), mutableInput = structuredClone(input);
  const plan = await p.prepare(mutableInput);
  mutableInput.evidence[0].evidenceId = "tampered-after-count";
  const result = await p.executePrepared(plan);
  assert.deepEqual(t.countedBody, t.invokedBody);
  assert.equal(result.value.overview.evidenceIds[0], evidenceId);
  assert.equal(JSON.parse(t.invokedBody).max_tokens, 1400);
  assert.deepEqual(JSON.parse(t.invokedBody).output_config.format.schema, JSON.parse(contract.COMPANY_UNDERSTANDING_JSON_SCHEMA));
  assert.equal(t.calls, 1);
});
test("a prepared request cannot be cloned, mutated or invoked twice", async () => {
  const t = transport(), p = await prepared(t), plan = await p.prepare(input);
  assert.throws(() => { plan.inputTokens = 1; });
  await assert.rejects(() => p.executePrepared({ ...plan }), /PREPARED_REQUEST_REQUIRED/);
  await p.executePrepared(plan);
  await assert.rejects(() => p.executePrepared(plan), /PREPARED_REQUEST_REQUIRED/);
  assert.equal(t.calls, 1);
});
test("invalid or long-context token counts fail before inference", async () => {
  for (const tokens of [0, -1, "1000", 200000, NaN]) {
    const t = transport({ tokens }), p = await prepared(t);
    await assert.rejects(() => p.prepare(input), /TOKEN_COUNT_INVALID/);
    assert.equal(t.calls, 0);
  }
});
test("malformed semantic output retains measured usage", async () => {
  const t = transport({ text: "invalid JSON" }), p = await prepared(t), plan = await p.prepare(input);
  await assert.rejects(() => p.executePrepared(plan), (e) => {
    assert.match(e.message, /INVALID_RESPONSE/); assert.equal(e.telemetry.inputUnits, 1000);
    assert.equal(e.telemetry.outputUnits, 100); return true;
  });
});
test("truncation is rejected with usage preserved", async () => {
  const t = transport({ stopReason: "max_tokens" }), p = await prepared(t);
  const plan = await p.prepare(input);
  await assert.rejects(() => p.executePrepared(plan), (e) => e.telemetry.outputUnits === 100);
});
for (const reason of ["WORK_BUDGET_EXHAUSTED", "REQUEST_RATE_LIMIT"]) {
  test(`${reason} makes no inference call and does not settle a failed job`, async () => {
    const d = dependencies(); d.admission.admit = async () => ({ outcome: "DEFERRED", reason });
    const result = await executeResearchEnvelope(envelope, { workerId: "worker-test" }, d);
    assert.equal(result.acknowledge, false); assert.equal(result.reason, reason);
    assert.deepEqual(d.events, ["prepare", "defer"]);
  });
}
test("disabled scope or invalid evidence prevents even token counting", async () => {
  for (const throwing of [false, true]) {
    const d = dependencies(); d.admission.preflight = async () => {
      if (throwing) throw new Error("evidence rejected"); return { outcome: "DEFERRED", reason: "MODEL_SCOPE_DISABLED" };
    };
    await executeResearchEnvelope(envelope, { workerId: "worker-test" }, d);
    assert.deepEqual(d.events, ["defer"]);
  }
});
test("ambiguous admission response cannot issue another request", async () => {
  const d = dependencies(); d.admission.admit = async () => ({ outcome: "ALREADY_ADMITTED" });
  await executeResearchEnvelope(envelope, { workerId: "worker-test" }, d);
  assert.deepEqual(d.events, ["prepare"]);
});
test("expired permits are settled NOT_SENT rather than invoked", async () => {
  const d = dependencies(); d.admission.admit = async () => ({ outcome: "ADMITTED", admissionId: "expired",
    reservedCostUsd: 0.0264, startBefore: new Date(Date.now() - 1000).toISOString() });
  await executeResearchEnvelope(envelope, { workerId: "worker-test" }, d);
  assert.deepEqual(d.events, ["prepare", "settle:NOT_SENT", "fail"]);
});
test("success uses accumulated attempt cost, not only the last provider call", async () => {
  const d = dependencies(); const result = await executeResearchEnvelope(envelope, { workerId: "worker-test" }, d);
  assert.equal(result.acknowledge, true);
  assert.deepEqual(d.events, ["prepare", "invoke", "settle:MEASURED", "complete"]);
  assert.equal(d.records[0].telemetry.estimatedEquivalentCostUsd, 0.0099);
  assert.equal(d.records[0].result.truthAuthorityGranted, false);
});
test("unknown network outcomes keep an UNKNOWN reservation", async () => {
  const d = dependencies(); d.provider.executePrepared = async () => { d.events.push("invoke"); throw new Error("network response lost"); };
  await executeResearchEnvelope(envelope, { workerId: "worker-test" }, d);
  assert.deepEqual(d.events, ["prepare", "invoke", "settle:UNKNOWN", "fail"]);
});
test("synchronization failure does not discard a persisted result", async () => {
  const d = dependencies(); d.ledger.sync = async () => { throw new Error("sync temporarily unavailable"); };
  const result = await executeResearchEnvelope(envelope, { workerId: "worker-test" }, d);
  assert.equal(result.outcome, "SYNC_PENDING"); assert.equal(d.events.includes("fail"), false);
});
let passed = 0;
for (const [name, fn] of tests) {
  try { await fn(); passed++; console.log(`PASS ${name}`); }
  catch (e) { console.error(`FAIL ${name}`, e); }
}
console.log(`${passed}/${tests.length} Build 11 admission/provider assertion groups passed`);
if (passed !== tests.length) process.exitCode = 1;
