// Isolated packaged recovery Data API wire proof. No cloud calls or new SDK dependency.
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { createRequire, syncBuiltinESMExports } from 'node:module';
import net from 'node:net';
import { Readable } from 'node:stream';
const root=path.resolve(import.meta.dirname,'../..');
const archive=path.join(root,'infrastructure/aws-v0/artifacts/research-worker.zip');
const task=mkdtempSync(path.join(tmpdir(),'build11-recovery-package-'));
try {
  const extracted=spawnSync('python3',['-m','zipfile','-e',archive,task],{encoding:'utf8'});
  assert.equal(extracted.status,0,extracted.stderr);
  const require=createRequire(path.join(task,'index.mjs'));
  const resolved=require.resolve('@smithy/node-http-handler');
  assert.ok(resolved.startsWith(task+path.sep));
  let connections=0;
  net.Socket.prototype.connect=()=>{connections++;throw new Error('OFFLINE_RECOVERY_PROOF_NETWORK_FORBIDDEN');};
  syncBuiltinESMExports();
  Object.assign(process.env,{
    AWS_REGION:'eu-west-2',AWS_ACCESS_KEY_ID:'BUILD11RECOVERYTESTONLY',AWS_SECRET_ACCESS_KEY:'synthetic-not-a-secret',
    AWS_EC2_METADATA_DISABLED:'true',MARKETROUTE_AWS_RDS_DATABASE:'marketroute',
    MARKETROUTE_AWS_RDS_CLUSTER_ARN:'arn:aws:rds:eu-west-2:801132668416:cluster:marketroute-aws-v0',
    MARKETROUTE_AWS_RDS_SECRET_ARN:'arn:aws:secretsmanager:eu-west-2:801132668416:secret:marketroute/aws-v0/database/admin-test',
  });
  delete process.env.AWS_SESSION_TOKEN;
  let calls=[];
  const {NodeHttpHandler,NodeHttp2Handler}=require('@smithy/node-http-handler');
  const intercept=async request=>{
    assert.equal(request.hostname,'rds-data.eu-west-2.amazonaws.com');
    assert.equal(request.path,'/Execute');assert.equal(request.protocol,'https:');
    assert.match(request.headers.authorization,/^AWS4-HMAC-SHA256/);
    const body=JSON.parse(request.body);calls.push(body);
    assert.ok(!body.sql.includes("tenant'O'Reilly"));assert.equal(body.continueAfterTimeout,false);
    assert.equal(body.resourceArn,process.env.MARKETROUTE_AWS_RDS_CLUSTER_ARN);
    let result;
    if(body.sql.includes('marketroute_list_aws_v0_recovery'))result=[];
    else if(body.sql.includes('marketroute_prepare_aws_v0_recovery'))result={outcome:'DISABLED'};
    else if(body.sql.includes('marketroute_confirm_aws_v0_recovery'))result={outcome:'CONFIRMED'};
    else if(body.sql.includes('marketroute_note_aws_v0_transport'))result={outcome:'RECORDED',acknowledge:false};
    else throw new Error('Unexpected operation');
    return {response:{statusCode:200,headers:{'content-type':'application/json'},body:Readable.from([
      Buffer.from(JSON.stringify({formattedRecords:JSON.stringify([{result_json:JSON.stringify(result)}])}))])}};
  };
  NodeHttpHandler.prototype.handle=intercept;NodeHttp2Handler.prototype.handle=intercept;
  const {createRecoveryLedger}=await import(pathToFileURL(path.join(task,'admission-ledger.mjs')));
  const ledger=await createRecoveryLedger();
  const work='11111111-1111-4111-8111-111111111111',fp='a'.repeat(64);
  assert.deepEqual(await ledger.candidates(5),[]);
  assert.equal((await ledger.prepare({workUnitId:work},fp,"tenant'O'Reilly")).outcome,'DISABLED');
  assert.equal((await ledger.confirm(work,1,work,'controller',fp,'message')).outcome,'CONFIRMED');
  assert.equal((await ledger.note({workUnitId:work},fp,5,'ADMISSION_DEFERRED')).acknowledge,false);
  ledger.destroy();assert.equal(calls.length,4);assert.equal(connections,0);
  assert.equal(calls[1].parameters.find(p=>p.name==='coordinator').value.stringValue,"tenant'O'Reilly");
  const manifest=JSON.parse(readFileSync(path.join(root,'infrastructure/aws-v0/artifacts/research-worker.manifest.json')));
  console.log('PASS four recovery operations through packaged SDK signing/serialization; zero external connections; architecture='+process.arch);
  console.log('Package manifest present: '+Boolean(manifest));
} finally { rmSync(task,{recursive:true,force:true}); }
