import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const root=path.resolve(import.meta.dirname,"..");
const read=(file)=>fs.readFileSync(path.join(root,file),"utf8");
const migration=read("supabase/migrations/0038_r6_reasoning_kind_hotfix.sql");
const applySql=read("APPLY-IN-SUPABASE-MARKETROUTE-V2-0.18.3.19-R6-REASONING-KIND-HOTFIX.sql");
const base=read("supabase/migrations/0003_reasoning_authority_and_workflow_separation.sql");
const r6=read("supabase/migrations/0011_contact_truth_and_authority_r6.sql");
const authorityWrite=/INSERT\s+INTO\s+public\.(?:commercial_reality_r4_records|route_authority_r5_records|contact_authority_r6_records|authority_records)/i;
const checks=[];
const check=(name,fn)=>checks.push([name,fn]);

check("deployable SQL exactly matches migration",()=>assert.equal(applySql,migration));
check("finite reasoning-kind law already owns canonical CONTACT_TRUTH",()=>{
  assert.match(base,/reasoning_kind IN \([^\n]*'CONTACT_TRUTH'/);
  assert.doesNotMatch(base,/CONTACT_TRUTH_AUTHORITY/);
});
check("historical R6 source remains immutable and the later migration owns the repair",()=>{
  assert.match(r6,/'CONTACT_TRUTH_AUTHORITY'/);
});
check("production writer is changed to the canonical existing kind only",()=>{
  assert.match(migration,/v_old text := 'VALUES\(p_organisation_id,p_campaign_id,''CONTACT_TRUTH_AUTHORITY'',p_engine_version'/);
  assert.match(migration,/v_new text := 'VALUES\(p_organisation_id,p_campaign_id,''CONTACT_TRUTH'',p_engine_version'/);
  assert.match(migration,/v_old_occurrences=1 AND v_new_occurrences=0/);
  assert.match(migration,/v_old_occurrences=0 AND v_new_occurrences=1/);
  assert.match(migration,/MARKETROUTE_R6_REASONING_KIND_PATCH_SOURCE_DRIFT/);
});
check("constraint remains finite and is checked rather than widened",()=>{
  assert.match(migration,/pg_get_constraintdef/);
  assert.match(migration,/MARKETROUTE_REASONING_KIND_CONSTRAINT_DRIFT/);
  assert.doesNotMatch(migration,/DROP CONSTRAINT|ADD CONSTRAINT|ALTER TABLE[\s\S]*reasoning_runs/i);
});
check("only exact failed R6 revalidations are requeued",()=>{
  assert.match(migration,/w\.layer='R6'/);
  assert.match(migration,/w\.action='REVALIDATE_R6'/);
  assert.match(migration,/reasoning_runs_reasoning_kind_check/);
  assert.match(migration,/max_attempts=least\(50,greatest\(j\.max_attempts,j\.attempt_count\+1\)\)/);
});
check("authority writer set and semantics remain unchanged",()=>{
  assert.match(migration,/new_authority_writer',false/);
  assert.match(migration,/authority_semantics_unchanged',true/);
  assert(!authorityWrite.test(migration));
  assert.doesNotMatch(migration,/authority_writer_registry/i);
});
check("existing service-role-only writer boundary is restored",()=>{
  assert.match(migration,/REVOKE ALL ON FUNCTION public\.marketroute_persist_contact_authority_r6_v1[\s\S]*FROM PUBLIC, anon, authenticated/);
  assert.match(migration,/GRANT EXECUTE ON FUNCTION public\.marketroute_persist_contact_authority_r6_v1[\s\S]*TO service_role/);
});
check("migration is transactional and reloads the API schema",()=>{
  assert.match(migration,/^BEGIN;/);
  assert.match(migration,/NOTIFY pgrst,'reload schema'/);
  assert.match(migration,/COMMIT;\s*$/);
});

let passed=0;
console.log("\nMarketRoute V2 — R6 reasoning-kind hotfix 0.18.3.19");
for(const [name,fn] of checks){try{fn();passed++;console.log(`PASS  ${name}`);}catch(error){console.error(`FAIL  ${name}: ${error instanceof Error?error.message:error}`);}}
console.log(`\n${passed}/${checks.length} PASS`);
if(passed!==checks.length)process.exitCode=1;
