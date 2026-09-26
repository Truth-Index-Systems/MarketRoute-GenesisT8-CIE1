// Real, packaged SDK middleware/signing/serialization/deserialization. Only the
// final NodeHttpHandler is replaced. No runtime dependency injection or AWS calls.
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { createRequire, syncBuiltinESMExports } from "node:module";
import { pathToFileURL } from "node:url";
import { Readable } from "node:stream";
import { createHash } from "node:crypto";
import { spawn } from "node:child_process";
import http from "node:http";
import https from "node:https";
import net from "node:net";
import tls from "node:tls";

const task = fs.realpathSync(process.env.BUILD11_TASK_DIR);
assert(!task.includes('/repo/'), 'Run outside the application source tree');
const require = createRequire(path.join(task, 'package.json'));
const lock = JSON.parse(fs.readFileSync(path.join(task, 'package-lock.json')));
for (const name of ['@aws-sdk/client-bedrock-runtime', '@aws-sdk/client-rds-data', '@smithy/node-http-handler']) {
  assert(fs.realpathSync(require.resolve(name)).startsWith(task + path.sep), 'SDK escaped the ZIP');
  assert.equal(require(name + '/package.json').version, lock.packages['node_modules/' + name].version);
}
// Not real credentials: the serializer signs requests, but there is no network.
Object.assign(process.env, { AWS_ACCESS_KEY_ID: 'AKIDBUILD11OFFLINEONLY',
  AWS_SECRET_ACCESS_KEY: 'build11-offline-only-not-an-aws-secret', AWS_REGION: 'eu-west-2',
  AWS_EC2_METADATA_DISABLED: 'true', AWS_CONFIG_FILE: '/dev/null', AWS_SHARED_CREDENTIALS_FILE: '/dev/null',
  MARKETROUTE_AWS_BEDROCK_INFERENCE_PROFILE_ARN: 'arn:aws:bedrock:eu-west-2:801132668416:application-inference-profile/1t6o6h9xl4qb',
  MARKETROUTE_AWS_RDS_CLUSTER_ARN: 'arn:aws:rds:eu-west-2:801132668416:cluster:marketroute-aws-v0',
  MARKETROUTE_AWS_RDS_SECRET_ARN: 'arn:aws:secretsmanager:eu-west-2:801132668416:secret:marketroute/aws-v0/database/admin-OFFLINE',
  MARKETROUTE_AWS_RDS_DATABASE: 'marketroute' });
let forbiddenNetwork = 0;
const blockNetwork = () => { forbiddenNetwork++; throw new Error('OFFLINE_PACKAGE_PROOF_FORBIDS_NETWORK'); };
http.request = https.request = net.connect = net.createConnection = tls.connect = blockNetwork;
net.Socket.prototype.connect = blockNetwork;
syncBuiltinESMExports();
const { NodeHttpHandler } = require('@smithy/node-http-handler');
let responseFor;
const requests = [];
const bytes = value => typeof value === 'string' ? Buffer.from(value) : Buffer.from(value ?? []);
const response = (body, statusCode = 200, extra = {}) => ({ response: { statusCode,
  headers: { 'content-type': 'application/json', 'x-amzn-requestid': 'offline-sdk-request', ...extra },
  body: Readable.from([Buffer.from(JSON.stringify(body))]) } });
NodeHttpHandler.prototype.handle = async function (request) {
  assert.equal(request.protocol, 'https:');
  assert(request.hostname.endsWith('.eu-west-2.amazonaws.com'));
  assert.match(request.headers.authorization ?? '', /^AWS4-HMAC-SHA256 Credential=AKIDBUILD11OFFLINEONLY\//);
  requests.push({ ...request, body: bytes(request.body) });
  return responseFor(request);
};
const load = name => import(pathToFileURL(path.join(task, name)).href);
const { createPreparedBedrockProvider, nativeCompanyRequest, MODEL_ID } = await load('prepared-provider.mjs');
const { createInferenceAdmissionLedger } = await load('admission-ledger.mjs');
const { createAuroraResearchExecutionLedger } = await load('executor.mjs');
const { handler } = await load('index.mjs');
const profile = process.env.MARKETROUTE_AWS_BEDROCK_INFERENCE_PROFILE_ARN;
const evidenceId = '55555555-5555-4555-8555-555555555555';
const input = { companyName: 'Offline package company', requestedTier: 'B', evidence: [
  { evidenceId, sourceType: 'WEBSITE', statement: 'Synthetic evidence only.' } ] };
const value = i => ({ overview: { text: i.evidence[0].statement, evidenceIds: [i.evidence[0].evidenceId] },
  businessActivities: [], offerings: [], customerTypes: [], operatingSignals: [], uncertainty: 'medium', unresolvedQuestions: [] });
let groups = 0, databaseGroups = 0;
const pass = text => { groups++; console.log('PASS ' + text); };
pass('both SDKs and shared HTTP handler resolve within extracted ZIP at locked versions');
function bedrockReply(request, i = input, mode = 'valid') {
  assert.equal(request.hostname, 'bedrock-runtime.eu-west-2.amazonaws.com');
  if (request.path.endsWith('/count-tokens')) {
    assert.equal(decodeURIComponent(request.path.split('/')[2]), MODEL_ID);
    const body = JSON.parse(bytes(request.body));
    const counted = Buffer.from(body.input.invokeModel.body, 'base64');
    assert.deepEqual(counted, Buffer.from(nativeCompanyRequest(i)));
    return response({ inputTokens: mode === 'count-invalid' ? 0 : 1000 });
  }
  assert(request.path.endsWith('/invoke'));
  assert.equal(decodeURIComponent(request.path.split('/')[2]), profile);
  assert.equal(request.headers['content-type'], 'application/json');
  assert.deepEqual(bytes(request.body), Buffer.from(nativeCompanyRequest(i)));
  if (mode === 'throttled') return response({ message: 'Offline synthetic throttle' }, 429, { 'x-amzn-errortype': 'ThrottlingException' });
  if (mode === 'denied') return response({ message: 'Offline synthetic denial' }, 403, { 'x-amzn-errortype': 'AccessDeniedException' });
  return response({ model: 'claude-sonnet-4-5-20250929', stop_reason: mode === 'truncated' ? 'max_tokens' : 'end_turn',
    usage: { input_tokens: 1000, output_tokens: 100, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 },
    content: [{ type: 'text', text: mode === 'invalid' ? '{bad json' : JSON.stringify(value(i)) }] });
}
responseFor = req => bedrockReply(req);
const provider = await createPreparedBedrockProvider();
const mutable = structuredClone(input), plan = await provider.prepare(mutable);
mutable.evidence[0].statement = 'Changed after counting';
const result = await provider.executePrepared(plan);
assert.deepEqual(result.value, value(input));
assert.equal(result.telemetry.inputUnits, 1000); assert.equal(result.telemetry.outputUnits, 100);
assert.equal(result.telemetry.providerRequestId, 'offline-sdk-request');
const countedBytes = Buffer.from(JSON.parse(requests[0].body).input.invokeModel.body, 'base64');
assert.deepEqual(countedBytes, requests[1].body);
assert.equal(createHash('sha256').update(countedBytes).digest('hex'), plan.requestFingerprint);
pass('real SDK serializes identical counted/invoked native JSON bytes, profile, schema and content type');
assert.equal(requests.length, 2);
await assert.rejects(provider.executePrepared(plan), /PREPARED_REQUEST_REQUIRED/);
await assert.rejects(provider.executePrepared({ ...plan }), /PREPARED_REQUEST_REQUIRED/);
assert.equal(requests.length, 2); provider.destroy();
pass('packaged prepared requests remain single-use through the real SDK path');
for (const mode of ['invalid', 'truncated', 'throttled', 'denied', 'count-invalid']) {
  const start = requests.length;
  responseFor = req => bedrockReply(req, input, mode);
  const p = await createPreparedBedrockProvider();
  try {
    if (mode === 'count-invalid') await assert.rejects(p.prepare(input), /TOKEN_COUNT_INVALID/);
    else {
      const plan = await p.prepare(input);
      await assert.rejects(p.executePrepared(plan), error => {
        if (['invalid', 'truncated'].includes(mode)) {
          assert.equal(error.telemetry.inputUnits, 1000); assert.equal(error.telemetry.outputUnits, 100);
        } else assert.equal(error.retryable, mode === 'throttled');
        return true;
      });
    }
    assert.equal(requests.length - start, mode === 'count-invalid' ? 1 : 2, 'SDK may not silently retry');
  } finally { p.destroy(); }
  pass(`packaged SDK ${mode}: correct failure handling without hidden retry`);
}

const calls = [], fp = 'a'.repeat(64), work = '11111111-1111-4111-8111-111111111111';
function checkDataRequest(request) {
  assert.equal(request.hostname, 'rds-data.eu-west-2.amazonaws.com');
  assert.equal(request.path, '/Execute');
  const body = JSON.parse(bytes(request.body));
  assert.equal(body.resourceArn, process.env.MARKETROUTE_AWS_RDS_CLUSTER_ARN);
  assert.equal(body.secretArn, process.env.MARKETROUTE_AWS_RDS_SECRET_ARN);
  assert.equal(body.database, 'marketroute');
  assert.equal(body.formatRecordsAs, 'JSON'); assert.equal(body.continueAfterTimeout, false);
  assert.match(body.sql.trim(), /^SELECT /);
  assert(!body.sql.includes("UNTRUSTED'O'Reilly"), 'Values must be parameters, never SQL');
  assert(Array.isArray(body.parameters)); calls.push(body);
  return body;
}
responseFor = req => {
  const body = checkDataRequest(req);
  let row;
  if (body.sql.includes('marketroute_preflight_')) row = { result_json: JSON.stringify({ outcome: 'READY' }) };
  else if (body.sql.includes('marketroute_admit_')) row = { result_json: JSON.stringify({ outcome: 'DEFERRED', reason: 'REQUEST_RATE_LIMIT' }) };
  else if (body.sql.includes('marketroute_defer_')) row = { result_json: 'true' };
  else if (body.sql.includes('marketroute_settle_')) row = { result_json: JSON.stringify({ accountedCostUsd: 0.00495 }) };
  else if (body.sql.includes('marketroute_claim_')) row = { result_json: JSON.stringify({ outcome: 'BUSY' }) };
  else if (body.sql.includes('marketroute_complete_')) row = { result_fingerprint: 'b'.repeat(64) };
  else if (body.sql.includes('marketroute_fail_')) row = { failure_state: 'FAILED_TERMINAL' };
  else if (body.sql.includes('marketroute_sync_aws_v0_research_failure')) row = { sync_state: 'ALREADY_FAILED' };
  else if (body.sql.includes('marketroute_sync_')) row = { sync_state: 'ALREADY_SYNCED' };
  else throw new Error('Unexpected named database operation');
  return response({ formattedRecords: JSON.stringify([row]) });
};
const admission = await createInferenceAdmissionLedger();
assert.equal((await admission.preflight(work, fp, "UNTRUSTED'O'Reilly")).outcome, 'READY');
assert.equal((await admission.admit({ workUnitId: work }, fp, 'worker', plan)).outcome, 'DEFERRED');
assert.equal(await admission.defer(work, fp, 'worker'), true);
assert.equal((await admission.settle(work, 'worker', fp, 'UNKNOWN', {})).accountedCostUsd, 0.00495);
const unknownParams = calls.at(-1).parameters;
assert.deepEqual(unknownParams.find(p => p.name === 'input').value, { isNull: true });
assert.deepEqual(unknownParams.find(p => p.name === 'output').value, { isNull: true });
admission.destroy();
pass('packaged admission adapter serializes all four named operations with scope, bound values and null usage');
const ledger = await createAuroraResearchExecutionLedger();
assert.equal((await ledger.claim({ workUnit: { action: 'SYNTHESIZE_COMPANY_UNDERSTANDING' } }, fp, 'worker', new Date().toISOString())).outcome, 'BUSY');
assert.equal(await ledger.complete(work, fp, 'worker', {}, {}, new Date().toISOString()), 'b'.repeat(64));
assert.equal(await ledger.fail(work, fp, 'worker', 'OFFLINE', false, {}, new Date().toISOString()), 'FAILED_TERMINAL');
assert.equal(await ledger.sync(work, fp, fp, new Date().toISOString()), 'ALREADY_SYNCED');
assert.equal(await ledger.syncFailure(work, fp, new Date().toISOString()), 'ALREADY_FAILED');
ledger.destroy();
pass('packaged execution adapter serializes claim, completion, failure and synchronization correctly');
const beforeDisabled = requests.length;
delete process.env.MARKETROUTE_AWS_RESEARCH_EXECUTOR_ENABLED;
assert.deepEqual(await handler({ Records: [{ messageId: 'disabled', body: '{}' }] }), { batchItemFailures: [{ itemIdentifier: 'disabled' }] });
assert.equal(requests.length, beforeDisabled);
pass('packaged Lambda entry imports and remains inactive without its execution switch');

// Optionally execute the actual handler/default Data API adapter against disposable
// PostgreSQL. It is the serialized HTTP request we translate, not an injected ledger.
const container = process.env.BUILD11_POSTGRES_CONTAINER;
if (container) {
  assert.match(container, /^[a-f0-9]{12,64}$/);
  const fixtures = JSON.parse(fs.readFileSync('/tmp/marketroute-build11-admission-fixtures.json', 'utf8'));
  const quote = s => `'${String(s).replaceAll("'", "''")}'`;
  function sql(text) {
    return new Promise((resolve, reject) => {
      const child = spawn('docker', ['exec', '-i', container, 'psql', '-X', '-Atq', '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', '-d', 'marketroute_build11_test']);
      let out = '', err = '';
      const timer = setTimeout(() => { child.kill('SIGKILL'); reject(new Error('Package DB proof timeout')); }, 15000);
      child.stdout.on('data', d => { out += d; }); child.stderr.on('data', d => { err += d; });
      child.on('error', e => { clearTimeout(timer); reject(e); });
      child.on('close', c => { clearTimeout(timer); c === 0 ? resolve(out.trim()) : reject(new Error(err)); });
      child.stdin.end(`SET statement_timeout='10s'; SET lock_timeout='5s';\n${text}`);
    });
  }
  let current, mode = 'valid', modelCalls = 0;
  responseFor = async req => {
    if (req.hostname.startsWith('bedrock-runtime.')) {
      if (req.path.endsWith('/invoke')) {
        modelCalls++;
        assert.equal(await sql(`SELECT count(*) FROM public.marketroute_aws_v0_inference_attempts WHERE work_unit_id=${quote(current.ids.work)} AND state='RESERVED';`), '1');
      }
      const i = structuredClone(current.envelope.workUnit.payload.metadata.awsV0Executor.input);
      i.requestedTier ??= 'B';
      // Production parser normalises evidence dates before prompt serialization.
      for (const e of i.evidence) if (e.observedAt) e.observedAt = new Date(e.observedAt).toISOString();
      return bedrockReply(req, i, mode);
    }
    const b = checkDataRequest(req);
    const params = new Map(b.parameters.map(p => [p.name, p.value.isNull ? 'NULL'
      : p.value.booleanValue !== undefined ? String(p.value.booleanValue)
      : quote(p.value.stringValue ?? p.value.longValue ?? p.value.doubleValue)]));
    const bound = b.sql.replace(/(?<!:):([A-Za-z_][A-Za-z0-9_]*)/g, (_m, name) => {
      assert(params.has(name), 'Missing serialized SQL parameter'); return params.get(name);
    });
    try {
      const rows = await sql(`SELECT row_to_json(package_result)::text FROM (${bound.replace(/;\s*$/, '')}) package_result;`);
      return response({ formattedRecords: JSON.stringify(rows ? rows.split('\n').map(r => JSON.parse(r)) : []) });
    } catch (e) { return response({ message: 'Offline SQL failure: ' + e.message }, 400, { 'x-amzn-errortype': 'DatabaseErrorException' }); }
  };
  process.env.MARKETROUTE_AWS_RESEARCH_EXECUTOR_ENABLED = 'true';
  const run = () => handler({ Records: [{ messageId: 'packaged-' + current.ids.work, body: JSON.stringify(current.envelope) }] }, { awsRequestId: 'package-sdk-db' });
  for (const [name, m, expectedCalls, expectedFailed] of [
    ['packagedSuccess', 'valid', 1, 0], ['packagedInvalid', 'invalid', 1, 0],
    ['packagedNoBudget', 'valid', 0, 1], ['packagedNoEvidence', 'valid', 0, 1],
  ]) {
    current = fixtures[name]; assert(current, 'Fresh packaged fixture required'); mode = m;
    await sql("UPDATE public.marketroute_aws_v0_inference_scopes SET enabled=true,next_start_at='-infinity';");
    const initialCalls = modelCalls;
    const r = await run(); assert.equal(r.batchItemFailures.length, expectedFailed);
    assert.equal(modelCalls - initialCalls, expectedCalls);
    if (!expectedFailed) {
      const events = await sql(`SELECT count(*) FROM public.research_budget_events WHERE work_unit_id=${quote(current.ids.work)};`);
      assert.equal((await run()).batchItemFailures.length, 0);
      assert.equal(modelCalls - initialCalls, 1);
      assert.equal(await sql(`SELECT count(*) FROM public.research_budget_events WHERE work_unit_id=${quote(current.ids.work)};`), events);
      assert.equal(Number(await sql(`SELECT sum(amount_usd) FROM public.research_budget_events WHERE work_unit_id=${quote(current.ids.work)} AND event_type='COMMIT';`)), 0.00495);
    }
    databaseGroups++; console.log(`PASS extracted handler + real SDK + PostgreSQL: ${name}`);
  }
}
assert.equal(forbiddenNetwork, 0);
console.log(`${groups}/${groups} packaged SDK/entry groups; ${databaseGroups} packaged PostgreSQL groups passed`);
console.log('PACKAGE_PROOF_JSON=' + JSON.stringify({ architecture: process.arch, node: process.version,
  sdkAssertionGroups: groups, packagedDatabaseGroups: databaseGroups,
  liveAwsCalls: 0, archiveSourceVerified: true, externalNetworkAttempts: forbiddenNetwork }));
