// Actual Lambda entry/executor + PostgreSQL claim/sync adapter; no AWS calls.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { executeResearchEnvelope } from "../../infrastructure/aws-v0/runtime/research-worker/executor.mjs";
import { handleEvent } from "../../infrastructure/aws-v0/runtime/research-worker/index.mjs";

const container = process.env.BUILD11_POSTGRES_CONTAINER ?? "";
assert.match(container, /^[a-f0-9]{12,64}$/, "Disposable Docker service required");
const quote = (value) => `'${String(value).replaceAll("'", "''")}'`;
async function sql(text) {
  return await new Promise((resolve, reject) => {
    const child = spawn("docker", ["exec", "-i", container, "psql", "-X", "-Atq",
      "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "marketroute_build11_test"]);
    let out = "", err = "";
    const timer = setTimeout(() => { child.kill("SIGKILL"); reject(new Error("PostgreSQL proof timeout")); }, 15_000);
    child.stdout.on("data", (data) => { out += data; });
    child.stderr.on("data", (data) => { err += data; });
    child.on("error", (error) => { clearTimeout(timer); reject(error); });
    child.on("close", (code) => {
      clearTimeout(timer);
      code === 0 ? resolve(out.trim()) : reject(new Error(err));
    });
    child.stdin.end(`SET statement_timeout='10s'; SET lock_timeout='5s';\n${text}`);
  });
}

const ledger = {
  async claim(envelope, fingerprint, worker, at) {
    return JSON.parse(await sql(`SELECT public.marketroute_claim_aws_v0_research_execution_v2(
      ${quote(JSON.stringify(envelope))}::jsonb,${quote(fingerprint)},${quote(worker)},${quote(at)}::timestamptz);`));
  },
  async sync(work, envelopeFp, resultFp, at) {
    return await sql(`SELECT public.marketroute_sync_aws_v0_research_execution_v1(
      ${quote(work)}::uuid,${quote(envelopeFp)},${quote(resultFp)},${quote(at)}::timestamptz);`);
  },
  async syncFailure(work, fingerprint, at) {
    return await sql(`SELECT public.marketroute_sync_aws_v0_research_failure_v1(
      ${quote(work)}::uuid,${quote(fingerprint)},${quote(at)}::timestamptz);`);
  },
  async complete() { throw new Error("Replay must not complete again"); },
  async fail() { throw new Error("Replay must not mutate failure state"); },
  destroy() {},
};
let providerCalls = 0;
const provider = {
  async execute() { providerCalls++; throw new Error("Settled replay must not invoke provider"); },
  destroy() {},
};
const deps = { ledger, provider };
const success = JSON.parse(await sql(`SELECT d.envelope_json FROM public.marketroute_aws_v0_research_dispatches d
  JOIN public.research_work_units w ON w.id=d.work_unit_id
  JOIN public.background_jobs j ON j.id=w.background_job_id
  JOIN public.marketroute_aws_v0_company_understanding_artifacts a ON a.work_unit_id=w.id
  WHERE d.state='SYNCED' AND j.status='SUCCEEDED' AND j.attempt_count=d.canonical_attempt_number
  ORDER BY d.work_unit_id LIMIT 1;`));
const failure = JSON.parse(await sql(`SELECT envelope_json FROM public.marketroute_aws_v0_research_dispatches
  WHERE state='FAILED' ORDER BY work_unit_id LIMIT 1;`));
const totals = () => sql(`SELECT json_build_object(
  'budgetEvents',(SELECT count(*) FROM public.research_budget_events),
  'cost',(SELECT sum(amount_usd) FROM public.research_budget_events),
  'artifacts',(SELECT count(*) FROM public.marketroute_aws_v0_company_understanding_artifacts),
  'executionAttempts',(SELECT sum(attempt_count) FROM public.marketroute_aws_v0_research_executions));`);
const before = await totals();

for (const [name, envelope, expected] of [["success", success, "DEDUPLICATED"], ["failure", failure, "TERMINAL"]]) {
  for (let replay = 0; replay < 3; replay++) {
    const result = await executeResearchEnvelope(envelope, { workerId: `proof-${name}-${replay}` }, deps);
    assert.equal(result.acknowledge, true);
    assert.equal(result.outcome, expected);
  }
  console.log(`PASS actual executor ${name} replay with PostgreSQL ledger`);
}

// This is a local process switch only; IaC event source remains disabled.
process.env.MARKETROUTE_AWS_RESEARCH_EXECUTOR_ENABLED = "true";
assert.deepEqual(await handleEvent({ Records: [
  { messageId: "success-replay", body: JSON.stringify(success) },
  { messageId: "failure-replay", body: JSON.stringify(failure) },
]}, { awsRequestId: "build11-entry-proof" }, deps), { batchItemFailures: [] });
console.log("PASS actual Lambda entry acknowledges settled messages without provider calls");

const tampered = structuredClone(success);
tampered.organisationId = "00000000-0000-4000-8000-000000000000";
assert.deepEqual(await handleEvent({ Records: [
  { messageId: "wrong-tenant", body: JSON.stringify(tampered) },
  { messageId: "malformed", body: "not-json" },
]}, { awsRequestId: "build11-rejection-proof" }, deps),
{ batchItemFailures: [{ itemIdentifier: "wrong-tenant" }, { itemIdentifier: "malformed" }] });
console.log("PASS tampered/malformed delivery remains unacknowledged");
assert.equal(providerCalls, 0);
assert.equal(await totals(), before);
console.log("PASS zero provider calls, zero additional attempts, zero extra budget settlement");
console.log("5/5 runtime/PostgreSQL integration checks passed; live AWS is NOT certified");
