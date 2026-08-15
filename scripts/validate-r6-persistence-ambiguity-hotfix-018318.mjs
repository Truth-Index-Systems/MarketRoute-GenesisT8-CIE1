import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const root=path.resolve(import.meta.dirname,"..");
const read=(file)=>fs.readFileSync(path.join(root,file),"utf8");
const migration=read("supabase/migrations/0037_r6_persistence_ambiguity_hotfix.sql");
const applySql=read("APPLY-IN-SUPABASE-MARKETROUTE-V2-0.18.3.18-R6-PERSISTENCE-AMBIGUITY-HOTFIX.sql");
const base=read("supabase/migrations/0011_contact_truth_and_authority_r6.sql");
const authorityWrite=/INSERT\s+INTO\s+public\.(?:commercial_reality_r4_records|route_authority_r5_records|contact_authority_r6_records|authority_records)/i;
const checks=[];
const check=(name,fn)=>checks.push([name,fn]);

check("deployable SQL exactly matches migration",()=>assert.equal(applySql,migration));
check("historical Build 8 migration remains immutable and the later migration owns the repair",()=>{
  assert.match(base,/route_authority_r5_records WHERE authority_record_id=v_r5_id/);
  assert.doesNotMatch(base,/FROM public\.route_authority_r5_records AS r WHERE r\.authority_record_id=v_r5_id/);
});
check("production patch replaces exactly the ambiguous expression",()=>{
  assert.match(migration,/v_old text := 'FROM public\.route_authority_r5_records WHERE authority_record_id=v_r5_id'/);
  assert.match(migration,/v_new text := 'FROM public\.route_authority_r5_records AS r WHERE r\.authority_record_id=v_r5_id'/);
  assert.match(migration,/v_old_occurrences=1 AND v_new_occurrences=0/);
  assert.match(migration,/v_old_occurrences=0 AND v_new_occurrences=1/);
  assert.match(migration,/MARKETROUTE_R6_PERSIST_PATCH_SOURCE_DRIFT/);
  assert.match(migration,/EXECUTE v_patched_definition/);
});
check("existing service-role-only writer boundary is restored",()=>{
  assert.match(migration,/REVOKE ALL ON FUNCTION public\.marketroute_persist_contact_authority_r6_v1[\s\S]*FROM PUBLIC, anon, authenticated/);
  assert.match(migration,/GRANT EXECUTE ON FUNCTION public\.marketroute_persist_contact_authority_r6_v1[\s\S]*TO service_role/);
});
check("only exact failed R6 revalidations are requeued",()=>{
  assert.match(migration,/w\.layer='R6'/);
  assert.match(migration,/w\.action='REVALIDATE_R6'/);
  assert.match(migration,/j\.status IN \('PENDING','FAILED'\)/);
  assert.match(migration,/j\.last_error_code='column reference "authority_record_id" is ambiguous'/);
  assert.match(migration,/max_attempts=least\(50,greatest\(j\.max_attempts,j\.attempt_count\+1\)\)/);
});
check("authority semantics and writer registry remain unchanged",()=>{
  assert.match(migration,/new_authority_writer',false/);
  assert.match(migration,/replaced_existing_authority_writer','marketroute\.r6\.contact-truth'/);
  assert.match(migration,/authority_semantics_unchanged',true/);
  assert(!authorityWrite.test(migration));
  assert.doesNotMatch(migration,/INSERT INTO public\.authority_writer_registry/i);
});
check("migration is transactional and reloads the API schema",()=>{
  assert.match(migration,/^BEGIN;/);
  assert.match(migration,/NOTIFY pgrst,'reload schema'/);
  assert.match(migration,/COMMIT;\s*$/);
});

let passed=0;
console.log("\nMarketRoute V2 — R6 persistence ambiguity hotfix 0.18.3.18");
for(const [name,fn] of checks){try{fn();passed++;console.log(`PASS  ${name}`);}catch(error){console.error(`FAIL  ${name}: ${error instanceof Error?error.message:error}`);}}
console.log(`\n${passed}/${checks.length} PASS`);
if(passed!==checks.length)process.exitCode=1;
