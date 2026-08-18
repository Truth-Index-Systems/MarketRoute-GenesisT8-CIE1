import fs from 'node:fs';
import assert from 'node:assert/strict';
const sql=fs.readFileSync(new URL('../../supabase/migrations/0052_anonymous_discovery_extension_claim_ambiguity_hotfix.sql',import.meta.url),'utf8');
const checks=[
 ['named run_id conflict constraint',/ON CONFLICT ON CONSTRAINT anonymous_discovery_extension_jobs_run_id_key/],
 ['no ambiguous conflict target',! /ON CONFLICT\s*\(\s*run_id\s*\)/i.test(sql)],
 ['service role guard',/marketroute_require_service_role\(\)/],
 ['active or claimed only',/r\.status IN\('ACTIVE','CLAIMED'\)/],
 ['paid run excluded',/NOT public\.marketroute_paid_entitlement_active_v1/],
 ['target ceiling retained',/< r\.target_count/],
 ['three attempt ceiling retained',/j\.attempt_count<3/],
 ['active campaign retained',/c\.workflow_state='ACTIVE'/],
];
for(const [name,ok] of checks){assert.ok(ok instanceof RegExp?ok.test(sql):ok,name);console.log('PASS',name)}
console.log(`${checks.length}/${checks.length}`);
