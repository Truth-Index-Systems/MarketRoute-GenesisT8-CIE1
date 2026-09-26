// Recovery fault injection through the actual handler, provider and PostgreSQL.
// Only the Bedrock network is replaced with synthetic responses; no AWS credentials.
import assert from "node:assert/strict";
import { runAwsV0RecoveryCycle } from "../../application/research/aws-v0-recovery.mjs";
import fs from "node:fs";
import { spawn } from "node:child_process";
import { handleEvent } from "../../infrastructure/aws-v0/runtime/research-worker/index.mjs";
import { createPreparedBedrockProvider } from "../../infrastructure/aws-v0/runtime/research-worker/prepared-provider.mjs";

const container = process.env.BUILD11_POSTGRES_CONTAINER ?? "";
assert.match(container, /^[a-f0-9]{12,64}$/);
const fixtures = JSON.parse(fs.readFileSync('/tmp/marketroute-build11-recovery-fixtures.json', 'utf8'));
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

const recovery = {
  candidates: limit => obj(`SELECT public.marketroute_list_aws_v0_recovery_candidates_v1(${limit});`),
  prepare: (e, fp, owner) => obj(`SELECT public.marketroute_prepare_aws_v0_recovery_v1(${json(e)},${quote(fp)},${quote(owner)});`),
  confirm: (work, attempt, token, owner, fp, message) => obj(`SELECT public.marketroute_confirm_aws_v0_recovery_send_v1(${quote(work)},${attempt},${quote(token)},${quote(owner)},${quote(fp)},${quote(message)});`),
  note: (e, fp, count, reason) => obj(`SELECT public.marketroute_note_aws_v0_transport_failure_v1(${json(e)},${quote(fp)},${count},${quote(reason)});`),
  destroy() {},
};
const { envelopeFingerprint } = await import('../../infrastructure/aws-v0/runtime/research-worker/executor.mjs');
const expire = item => sql(`UPDATE public.marketroute_aws_v0_research_executions SET lease_expires_at=now()-interval '70 seconds' WHERE work_unit_id=${quote(item.ids.work)};`);
const recover = item => recovery.prepare(item.envelope,envelopeFingerprint(item.envelope),'fault-injection-controller');
const event = item => ({ Records: [{ messageId: 'synthetic-delivery',body:JSON.stringify(item.envelope) }] });
let groups=0;
const pass = label => { groups++; console.log('PASS '+label); };
await resetRate();
const lost = await setup(fixtures.completionLost);
let failureWrites=0;
const ambiguousLedger = { ...ledger,
  async complete(...args) { await ledger.complete(...args); throw new Error('Synthetic completion response lost after commit'); },
  async fail(...args) { failureWrites++; return ledger.fail(...args); },
};
assert.equal((await handleEvent(event(lost.item),{awsRequestId:'lost-completion'},{ledger:ambiguousLedger,admission,provider:lost.provider})).batchItemFailures.length,1);
assert.equal(failureWrites,0);
assert.equal(await sql(`SELECT state FROM public.marketroute_aws_v0_research_executions WHERE work_unit_id=${quote(lost.item.ids.work)};`),'SUCCEEDED');
const replay=await setup(lost.item);
assert.deepEqual(await run(replay,'recover-completion'),{batchItemFailures:[]});
assert.equal(replay.transport.calls,0);assert.equal(replay.transport.counts,0);
assert.equal(Number(await committed(lost.item)),0.00495);
pass('committed completion with lost response is not failed or reinvoked; replay synchronizes once');

await resetRate();
const absent=await setup(fixtures.completionNotStored);
assert.equal((await handleEvent(event(absent.item),{awsRequestId:'missing-completion'},
  {ledger:{...ledger,async complete(){throw new Error('Synthetic write did not reach database');}},admission,provider:absent.provider})).batchItemFailures.length,1);
await expire(absent.item);
assert.equal((await recover(absent.item)).outcome,'REVIEW_REQUIRED');
const blocked=await setup(absent.item);
assert.equal((await run(blocked,'must-not-repay')).batchItemFailures.length,1);
assert.equal(blocked.transport.counts,0);assert.equal(blocked.transport.calls,0);
assert.equal(await sql(`SELECT state FROM public.marketroute_aws_v0_inference_attempts WHERE work_unit_id=${quote(absent.item.ids.work)};`),'MEASURED');
pass('missing result after paid response preserves measured receipt and blocks blind paid retry');

const sendItem=fixtures.sendLost;
let publications=[];
const scoped={...recovery,candidates:async()=>[{envelope:sendItem.envelope}]};
let cycle=await runAwsV0RecoveryCycle({ledger:scoped,coordinator:'controller',publisher:{async publish(body){publications.push(body);throw new Error('Accepted by synthetic SQS but response lost');}}});
assert.equal(cycle[0].outcome,'RECOVERY_PENDING');
cycle=await runAwsV0RecoveryCycle({ledger:scoped,coordinator:'other',publisher:{async publish(){throw new Error('Must not publish while leased');}}});
assert.equal(cycle[0].outcome,'BUSY');
await sql(`UPDATE public.marketroute_aws_v0_recovery_receipts SET lease_until=now()-interval '1 minute',not_before=now()-interval '1 minute' WHERE work_unit_id=${quote(sendItem.ids.work)};`);
cycle=await runAwsV0RecoveryCycle({ledger:scoped,coordinator:'controller-2',publisher:{async publish(body){publications.push(body);return {messageId:'new-sqs-id'};}}});
assert.equal(cycle[0].outcome,'REPUBLISHED');
assert.equal(publications.length,2);assert.equal(publications[0],publications[1]);
await resetRate();
const afterSend=await setup(sendItem);assert.deepEqual(await run(afterSend,'new-message'),{batchItemFailures:[]});
const oldMessage=await setup(sendItem);assert.deepEqual(await run(oldMessage,'original-message'),{batchItemFailures:[]});
assert.equal(afterSend.transport.calls,1);assert.equal(oldMessage.transport.calls,0);
assert.equal(await sql(`SELECT attempt_count FROM public.background_jobs WHERE id=${quote(sendItem.ids.job)};`),'1');
pass('ambiguous queue send is retried with the same envelope; both deliveries produce one paid execution');

let executes=0,waits=[];
const rate=event(fixtures.rate);
assert.deepEqual(await handleEvent(rate,{awsRequestId:'bounded-wait',getRemainingTimeInMillis:()=>240000},{
  sleep:async ms=>waits.push(ms),
  executeResearchEnvelope:async()=>++executes===1?{acknowledge:false,reason:'REQUEST_RATE_LIMIT',retryAt:new Date(Date.now()+1000).toISOString()}:{acknowledge:true},
}),{batchItemFailures:[]});
assert.equal(executes,2);assert.equal(waits.length,1);assert.ok(waits[0]>0&&waits[0]<=12000);
pass('one bounded in-invocation rate wait avoids another transport receive');

executes=0;waits=[];
assert.equal((await handleEvent(rate,{awsRequestId:'never-loop',getRemainingTimeInMillis:()=>240000},{
  sleep:async ms=>waits.push(ms),executeResearchEnvelope:async()=>{executes++;return {acknowledge:false,reason:'REQUEST_RATE_LIMIT',retryAt:new Date(Date.now()+1000).toISOString()};}
})).batchItemFailures.length,1);
assert.equal(executes,2);assert.equal(waits.length,1);
await handleEvent(rate,{awsRequestId:'budget-is-not-rate',getRemainingTimeInMillis:()=>240000},{sleep:async()=>{throw new Error('Budget denial must not wait');},executeResearchEnvelope:async()=>({acknowledge:false,reason:'WORK_BUDGET_EXHAUSTED'})});
pass('inline retries are finite and budget denial cannot use the rate-wait path');

const receive=event(fixtures.receiveLimit);
receive.Records[0].eventSourceARN='arn:aws:sqs:eu-west-2:801132668416:marketroute-aws-v0-research-work';
receive.Records[0].attributes={ApproximateReceiveCount:'5'};
assert.equal((await handleEvent(receive,{awsRequestId:'receive-limit'},{recovery,
  executeResearchEnvelope:async()=>({acknowledge:false,outcome:'ADMISSION_DEFERRED'})})).batchItemFailures.length,1);
assert.equal(await sql(`SELECT highest_receive_count FROM public.marketroute_aws_v0_recovery_receipts WHERE work_unit_id=${quote(fixtures.receiveLimit.ids.work)};`),'5');
assert.equal((await handleEvent(receive,{awsRequestId:'receipt-write-lost'},{recovery:{async note(){throw new Error('No database response');}},
  executeResearchEnvelope:async()=>({acknowledge:false,outcome:'ADMISSION_DEFERRED'})})).batchItemFailures.length,1);
pass('receive-limit recording survives outside the message and never causes premature acknowledgment');
console.log(`${groups}/${groups} actual-handler/controller/PostgreSQL recovery groups passed; SQS transport is simulated`);
