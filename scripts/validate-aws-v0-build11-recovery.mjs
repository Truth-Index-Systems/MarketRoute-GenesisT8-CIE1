import fs from 'node:fs';
import assert from 'node:assert/strict';
const read=p=>fs.readFileSync(p,'utf8');
const sql=read('database/aws/0007_marketroute_aws_build11_recovery.sql');
for(const name of ['DEFAULT false','REVIEW_REQUIRED','CANONICAL_RESERVATION_REQUIRES_REVIEW',
  "interval '60 seconds'","interval '24 hours'",'pg_advisory_xact_lock','republish_count=republish_count+1']) assert.ok(sql.includes(name),name);
for(const table of ['claims','truth_claim_snapshots','authority_records','commercial_reality_r4_records','route_authority_r5_records','contact_authority_r6_records']) {
  assert.equal(new RegExp(`(?:INSERT INTO|UPDATE|DELETE FROM) public\\.${table}\\b`,'i').test(sql),false,'forbidden authority '+table);
}
const dispatcher=read('application/research/aws-v0-dispatcher.ts');
assert.ok(dispatcher.includes('if (!publishAttempted) await this.repository.failAwsV0Dispatch('));
assert.ok(dispatcher.indexOf('publishAttempted = true;')<dispatcher.indexOf('await this.publisher.publish(body)'));
const controller=read('application/research/aws-v0-recovery.mjs');
assert.ok(controller.includes('limit > 20'));assert.ok(controller.includes('await ledger.prepare('));
assert.equal((controller.match(/publisher\.publish\(/g)||[]).length,1);
const runtime=read('infrastructure/aws-v0/runtime/research-worker/admitted-executor.mjs');
assert.ok(runtime.includes('completionAttempted && !completed'));
const stack=read('infrastructure/aws-v0/lib/research-stack.ts');
assert.ok(stack.includes('enabled: false'));
assert.ok(stack.includes('const MAX_RECEIVE_COUNT = 5'));
assert.ok(stack.includes('const VISIBILITY_TIMEOUT_SECONDS = 1_440'));
assert.ok(!stack.includes('grantSendMessages'));
console.log('PASS Build 11 recovery authority, finite publication and disabled rollout boundaries');
