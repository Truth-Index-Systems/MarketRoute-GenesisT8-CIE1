// Actual source handler and PostgreSQL routines; no AWS endpoint or model request.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {spawnSync} from 'node:child_process';
import {handleEvent} from '../../infrastructure/aws-v0/runtime/research-worker/index.mjs';
import {envelopeFingerprint,parseCompanyUnderstandingInput} from '../../infrastructure/aws-v0/runtime/research-worker/executor.mjs';
const {fixture:f,container,database} = JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
assert.match(container,/^[a-f0-9]{64}$/);assert.equal(database,'marketroute_build11_rehearsal');
const q=v=>`'${String(v).replaceAll("'","''")}'`;
const j=v=>`${q(JSON.stringify(v))}::jsonb`;
const query=sql=>{
 const r=spawnSync('docker',['exec','-i',container,'psql','-X','-v','ON_ERROR_STOP=1','-U','postgres','-d',database,'-Atq'],{
  input:`SET statement_timeout='10s';\n${sql}`,encoding:'utf8',timeout:15000,
  env:{PATH:process.env.PATH,DOCKER_HOST:'unix:///var/run/docker.sock',LANG:'C.UTF-8'}});
 if(r.status!==0)throw Error(r.stderr);return r.stdout.trim();
};
let providerCalls=0;const trace=[];
const forbidden=()=>{providerCalls++;throw Error('Provider path forbidden in paused zero-budget canary');};
const deps={
 ledger:{claim:async(e,fp,w,at)=>{trace.push('claim');return JSON.parse(query(`SELECT public.marketroute_claim_aws_v0_research_execution_v2(${j(e)},${q(fp)},${q(w)},${q(at)}::timestamptz);`));},destroy(){}},
 admission:{preflight:async(id,fp,w)=>{const r=JSON.parse(query(`SELECT public.marketroute_preflight_aws_v0_inference_v1(${q(id)},${q(fp)},${q(w)});`));trace.push('preflight:'+r.reason);return r;},
  defer:async(id,fp,w)=>{trace.push('defer');return query(`SELECT public.marketroute_defer_aws_v0_inference_v1(${q(id)},${q(fp)},${q(w)});`)==='t';},
  admit:forbidden,settle:forbidden,destroy(){}},
 provider:{prepare:forbidden,executePrepared:forbidden,destroy(){}},
 recovery:{note:()=>{throw Error('No simulated SQS receive permitted');},destroy(){}},
};
assert.equal(envelopeFingerprint(f.envelope),f.fingerprint);
assert.equal(parseCompanyUnderstandingInput(f.envelope).evidence[0].sourceType,'OTHER');
process.env.MARKETROUTE_AWS_RESEARCH_EXECUTOR_ENABLED='true'; // Test process only.
const response=await handleEvent({Records:[{messageId:f.messageId,body:JSON.stringify(f.envelope)}]},
 {awsRequestId:'00000000-0000-4000-8000-000000000711'},deps);
assert.deepEqual(response,{batchItemFailures:[{itemIdentifier:f.messageId}]});
assert.deepEqual(trace,['claim','preflight:CAMPAIGN_NOT_ACTIVE','defer']);
assert.equal(providerCalls,0);
console.log(JSON.stringify({response,trace,providerCalls}));
