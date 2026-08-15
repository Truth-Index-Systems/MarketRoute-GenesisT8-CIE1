import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const root=path.resolve(import.meta.dirname,"..");
const read=(file)=>fs.readFileSync(path.join(root,file),"utf8");
const migration=read("supabase/migrations/0031_research_plan_persistence_hotfix.sql");
const applySql=read("APPLY-IN-SUPABASE-MARKETROUTE-V2-0.18.3.11-RESEARCH-PLAN-PERSISTENCE-HOTFIX.sql");
const planner=read("core/research/planner.ts");
const runtime=read("application/research/automation.ts");
const authorityWrite=/INSERT\s+INTO\s+public\.(?:commercial_reality_r4_records|route_authority_r5_records|contact_authority_r6_records|authority_records)/i;
const checks=[];
const check=(name,fn)=>checks.push([name,fn]);

check("deployable SQL exactly matches migration",()=>assert.equal(applySql,migration));
check("research-plan RPC is replaced in place",()=>assert.match(migration,/CREATE OR REPLACE FUNCTION public\.marketroute_persist_research_plan_v1\(/));
check("database canonicalises reference time to JavaScript ISO UTC",()=>{
  assert(migration.includes("AT TIME ZONE 'UTC'"));
  assert(migration.includes("'YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"'"));
  assert.match(migration,/MRV2-RESEARCH-WORK-1\.0\.0[\s\S]*v_reference_iso/);
});
check("planner uses Date toISOString for the matching fingerprint input",()=>assert.match(planner,/const reference = new Date\(context\.referenceTime\)[\s\S]*reference\.toISOString\(\)/));
check("plan fingerprint lookup qualifies the shadowed column",()=>{
  assert.match(migration,/FROM public\.research_plan_runs AS p\s+WHERE p\.plan_fingerprint = v_expected_fp/);
  assert.doesNotMatch(migration,/WHERE plan_fingerprint\s*=\s*v_expected_fp/);
});
check("work-unit counts qualify the shadowed plan id",()=>{
  assert.match(migration,/FROM public\.research_work_units AS w\s+WHERE w\.plan_id = v_existing\.id/);
  assert.match(migration,/FROM public\.research_work_units AS w\s+WHERE w\.plan_id = v_plan/);
});
check("insert deduplication names the unique constraint",()=>assert(migration.includes("ON CONFLICT ON CONSTRAINT research_plan_runs_plan_fingerprint_key DO NOTHING")));
check("service-role-only execution boundary is preserved",()=>{
  assert.match(migration,/REVOKE ALL ON FUNCTION[\s\S]*FROM PUBLIC, anon, authenticated/);
  assert.match(migration,/GRANT EXECUTE ON FUNCTION[\s\S]*TO service_role/);
});
check("failed planning remains before provider execution",()=>{
  assert(runtime.indexOf("this.planner.planCompany")<runtime.indexOf("this.worker.runOne"));
  assert(migration.includes("'failed_before_provider_cost',true"));
});
check("hotfix creates no authority writer",()=>{
  assert(migration.includes("'new_authority_writer',false"));
  assert(!authorityWrite.test(migration));
});

let passed=0;
console.log("\nMarketRoute V2 — Research-plan persistence hotfix 0.18.3.11");
for(const [name,fn] of checks){
  try{fn();passed++;console.log(`PASS  ${name}`);}
  catch(error){console.error(`FAIL  ${name}: ${error instanceof Error?error.message:error}`);}
}
console.log(`\n${passed}/${checks.length} PASS`);
if(passed!==checks.length)process.exitCode=1;
