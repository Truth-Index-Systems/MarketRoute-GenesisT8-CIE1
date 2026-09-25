// Real handler + prepared-request provider + PostgreSQL execution/admission/sync.
// Only the Bedrock network is replaced with synthetic responses; no AWS credentials.
import assert from "node:assert/strict";
import fs from "node:fs";
import { spawn } from "node:child_process";
import { handleEvent } from "../../infrastructure/aws-v0/runtime/research-worker/index.mjs";
import { createPreparedBedrockProvider } from "../../infrastructure/aws-v0/runtime/research-worker/prepared-provider.mjs";

const container = process.env.BUILD11_POSTGRES_CONTAINER ?? "";
assert.match(container, /^[a-f0-9]{12,64}$/);
const fixtures = JSON.parse(fs.readFileSync('/tmp/marketroute-build11-admission-fixtures.json', 'utf8'));
const quote = (s) => `'${String(s).replaceAll("'", "''")}'`;
const json = (v) => `${quote(JSON.stringify(v))}::jsonb`;
function sql(text) {
  return new Promise((resolve, reject) => {
    const child = spawn("docker", ["exec", "-i", container, "psql", "-X", "-Atq", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "marketroute_build11_test"]);
    let output = "", error = "";
    const timer = setTimeout(() => { child.kill("SIGKILL"); reject(new Error("Test database timeout")); }, 15000);
    child.stdout.on('data', d => { output += d; }); child.stderr.on('data', d => { error += d; });
    child.on('error', e => { clearTimeout(timer); reject(e); });
    child.on('close', c => { clearTimeout(timer); c === 0 ? resolve(output.trim()) : reject(new Error(error)); });
    child.stdin.end(`SET statement_timeout='10s'; SET lock_timeout='5s';\n${text}`);
  });
}
const obj = async (text) => JSON.parse(await sql(text));
const ledger = {
  claim: (e, fp, w, at) => obj(`SELECT public.marketroute_claim_aws_v0_research_execution_v2(${json(e)},${quote(fp)},${quote(w)},${quote(at)}::timestamptz);`),
  complete: (id, fp, w, result, telemetry, at) => sql(`SELECT public.marketroute_complete_aws_v0_research_execution_v1(${quote(id)},${quote(fp)},${quote(w)},${json(result)},${json(telemetry)},${quote(at)}::timestamptz);`),
  fail: (id, fp, w, code, retry, telemetry, at) => sql(`SELECT public.marketroute_fail_aws_v0_research_execution_v1(${quote(id)},${quote(fp)},${quote(w)},${quote(code)},${retry},${json(telemetry)},${quote(at)}::timestamptz);`),
  sync: (id, fp, result, at) => sql(`SELECT public.marketroute_sync_aws_v0_research_execution_v1(${quote(id)},${quote(fp)},${quote(result)},${quote(at)}::timestamptz);`),
  syncFailure: (id, fp, at) => sql(`SELECT public.marketroute_sync_aws_v0_research_failure_v1(${quote(id)},${quote(fp)},${quote(at)}::timestamptz);`),
  destroy() {},
};
const admission = {
  preflight: (id, fp, w) => obj(`SELECT public.marketroute_preflight_aws_v0_inference_v1(${quote(id)},${quote(fp)},${quote(w)});`),
  admit: (e, fp, w, p) => obj(`SELECT public.marketroute_admit_aws_v0_inference_v1(${quote(e.workUnitId)},${quote(fp)},${quote(w)},${quote(p.requestFingerprint)},${quote(p.profileArn)},${p.inputTokens},${p.maxOutputTokens});`),
  defer: (id, fp, w) => sql(`SELECT public.marketroute_defer_aws_v0_inference_v1(${quote(id)},${quote(fp)},${quote(w)});`),
  settle: (id, w, fp, outcome, t) => obj(`SELECT public.marketroute_settle_aws_v0_inference_v1(${quote(id)},${quote(w)},${quote(fp)},${quote(outcome)},${outcome === 'MEASURED' ? t.inputUnits : 'NULL'},${outcome === 'MEASURED' ? t.outputUnits : 'NULL'},${json(t)});`),
  destroy() {},
};
const profileArn = 'arn:aws:bedrock:eu-west-2:801132668416:application-inference-profile/1t6o6h9xl4qb';
async function setup(item, mode = 'valid') {
  const input = item.envelope.workUnit.payload.metadata.awsV0Executor.input;
  const value = { overview: { text: input.evidence[0].statement, evidenceIds: [input.evidence[0].evidenceId] },
    businessActivities: [], offerings: [], customerTypes: [], operatingSignals: [], uncertainty: 'medium', unresolvedQuestions: [] };
  const t = { counts: 0, calls: 0, countedBody: null,
    async count(body) { this.counts++; this.countedBody = Buffer.from(body); return { inputTokens: 1000 }; },
    async invoke(body) {
      this.calls++;
      assert.deepEqual(this.countedBody, body);
      assert.equal(await sql(`SELECT count(*) FROM public.marketroute_aws_v0_inference_attempts WHERE work_unit_id=${quote(item.ids.work)} AND state='RESERVED';`), '1', 'no inference before durable reservation');
      if (mode === 'unknown') throw new Error('Synthetic missing network outcome');
      return { body: Buffer.from(JSON.stringify({ stop_reason: 'end_turn', usage: { input_tokens: 1000, output_tokens: 100 },
        content: [{ type: 'text', text: mode === 'invalid' ? 'malformed structured answer' : JSON.stringify(value) }] })), $metadata: { requestId: 'synthetic-inference' } };
    }, destroy() {} };
  const p = await createPreparedBedrockProvider({ region: 'eu-west-2', profileArn, transport: t });
  return { item, transport: t, provider: p };
}
async function run(setup, requestId) {
  return handleEvent({ Records: [{ messageId: requestId, body: JSON.stringify(setup.item.envelope) }] },
    { awsRequestId: requestId }, { ledger, admission, provider: setup.provider });
}
const resetRate = () => sql("UPDATE public.marketroute_aws_v0_inference_scopes SET enabled=true,next_start_at='-infinity';");
const committed = item => sql(`SELECT COALESCE(sum(amount_usd),0)::text FROM public.research_budget_events WHERE work_unit_id=${quote(item.ids.work)} AND event_type='COMMIT';`);
process.env.MARKETROUTE_AWS_RESEARCH_EXECUTOR_ENABLED = 'true'; // Test process only.

await resetRate();
const success = await setup(fixtures.success);
assert.deepEqual(await run(success, 'first-success'), { batchItemFailures: [] });
assert.equal(success.transport.calls, 1);
assert.equal(Number(await committed(fixtures.success)), 0.00495);
assert.equal(await sql(`SELECT count(*) FROM public.marketroute_aws_v0_company_understanding_artifacts WHERE work_unit_id=${quote(fixtures.success.ids.work)};`), '1');
const baseline = await sql(`SELECT count(*) FROM public.research_budget_events WHERE work_unit_id=${quote(fixtures.success.ids.work)};`);
assert.deepEqual(await run(success, 'repeated-success'), { batchItemFailures: [] });
assert.equal(success.transport.calls, 1); assert.equal(success.transport.counts, 1);
assert.equal(await sql(`SELECT count(*) FROM public.research_budget_events WHERE work_unit_id=${quote(fixtures.success.ids.work)};`), baseline);
console.log('PASS full synthetic first execution and semantic synchronization; replay adds no inference or budget event');

await resetRate();
const invalid = await setup(fixtures.invalid, 'invalid');
assert.deepEqual(await run(invalid, 'invalid-output'), { batchItemFailures: [] });
assert.equal(Number(await committed(fixtures.invalid)), 0.00495);
assert.equal(await sql(`SELECT state FROM public.marketroute_aws_v0_inference_attempts WHERE work_unit_id=${quote(fixtures.invalid.ids.work)};`), 'MEASURED');
assert.deepEqual(await run(invalid, 'invalid-output-replay'), { batchItemFailures: [] });
assert.equal(invalid.transport.calls, 1);
console.log('PASS invalid structured answer retains measured usage and settles actual estimated attempt cost once');

await resetRate();
const unknown = await setup(fixtures.unknown, 'unknown');
assert.deepEqual(await run(unknown, 'unknown-result'), { batchItemFailures: [] });
assert.equal(Number(await committed(fixtures.unknown)), 0.0264);
assert.equal(await sql(`SELECT state FROM public.marketroute_aws_v0_inference_attempts WHERE work_unit_id=${quote(fixtures.unknown.ids.work)};`), 'UNKNOWN');
console.log('PASS missing provider outcome settles the held ceiling, not zero');

await resetRate();
const noBudget = await setup(fixtures.noBudget);
assert.equal((await run(noBudget, 'budget-denied')).batchItemFailures.length, 1);
assert.equal(noBudget.transport.calls, 0);
assert.equal(Number(await committed(fixtures.noBudget)), 0);
assert.equal(await sql(`SELECT attempt_count FROM public.marketroute_aws_v0_research_executions WHERE work_unit_id=${quote(fixtures.noBudget.ids.work)};`), '0');
console.log('PASS denied daily budget never invokes inference or charges a failed execution');

const noEvidence = await setup(fixtures.noEvidence);
assert.equal((await run(noEvidence, 'evidence-denied')).batchItemFailures.length, 1);
assert.equal(noEvidence.transport.calls, 0); assert.equal(noEvidence.transport.counts, 0);
console.log('PASS missing canonical evidence blocks both token counting and inference');

await resetRate();
const a = await setup(fixtures.rateA), b = await setup(fixtures.rateB);
const raced = await Promise.all([run(a, 'rate-worker-a'), run(b, 'rate-worker-b')]);
assert.equal(a.transport.calls + b.transport.calls, 1);
assert.equal(raced.reduce((n, r) => n + r.batchItemFailures.length, 0), 1);
console.log('PASS concurrent handlers from separate organisations share one admission slot');
console.log('6/6 actual-handler/PostgreSQL admission groups passed; AWS network and worker IAM remain untested');
