import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const root=path.resolve(import.meta.dirname,"..");
const read=(file)=>fs.readFileSync(path.join(root,file),"utf8");
const migration=read("supabase/migrations/0032_r4_persistence_ambiguity_hotfix.sql");
const applySql=read("APPLY-IN-SUPABASE-MARKETROUTE-V2-0.18.3.12-R4-PERSISTENCE-AMBIGUITY-HOTFIX.sql");
const build6=read("supabase/migrations/0009_commercial_reality_r4.sql");
const worker=read("application/research/worker.ts");
const functionPattern=/CREATE OR REPLACE FUNCTION public\.marketroute_persist_commercial_reality_r4_v1\([\s\S]*?\n\$\$;/;
const originalFunction=build6.match(functionPattern)?.[0];
const repairedFunction=migration.match(functionPattern)?.[0];
const originalLookup="  SELECT * INTO v_existing FROM public.commercial_reality_r4_records\n  WHERE organisation_id=p_organisation_id AND campaign_id=p_campaign_id AND company_id=p_company_id AND input_fingerprint=v_input_fingerprint;";
const repairedLookup="  SELECT r.*\n  INTO v_existing\n  FROM public.commercial_reality_r4_records AS r\n  WHERE r.organisation_id=p_organisation_id\n    AND r.campaign_id=p_campaign_id\n    AND r.company_id=p_company_id\n    AND r.input_fingerprint=v_input_fingerprint;";
const checks=[];
const check=(name,fn)=>checks.push([name,fn]);

check("deployable SQL exactly matches migration",()=>assert.equal(applySql,migration));
check("existing R4 writer is replaced in place",()=>assert(repairedFunction));
check("input-fingerprint lookup qualifies every R4 table column",()=>{
  assert(repairedFunction.includes(repairedLookup));
  assert(!repairedFunction.includes(originalLookup));
});
check("R4 authority semantics are byte-identical apart from the lookup repair",()=>{
  assert(originalFunction&&repairedFunction);
  assert.equal(repairedFunction.replace(repairedLookup,originalLookup),originalFunction);
});
check("release does not register a new authority writer",()=>{
  assert(migration.includes("'new_authority_writer',false"));
  assert(migration.includes("'replaced_existing_authority_writer','marketroute.r4.commercial-reality'"));
  assert(!migration.includes("INSERT INTO public.authority_writer_registry"));
});
check("service-role-only boundary is preserved",()=>{
  assert.match(migration,/REVOKE ALL ON FUNCTION[\s\S]*FROM PUBLIC, anon, authenticated/);
  assert.match(migration,/GRANT EXECUTE ON FUNCTION[\s\S]*TO service_role/);
});
check("R5 and R6 persistence already use qualified deduplication columns",()=>{
  const r5=read("supabase/migrations/0010_relationship_truth_and_route_authority_r5.sql");
  const r6=read("supabase/migrations/0011_contact_truth_and_authority_r6.sql");
  assert(r5.includes("rr.input_fingerprint=v_input_fp"));
  assert(r6.includes("r.input_fingerprint=v_input"));
});
check("failed zero-cost revalidation remains retryable",()=>{
  assert(worker.includes("this.d.repository.fail(work.workUnitId,schedulerRunId,code,failedCostUsd,true"));
  assert(migration.includes("'failed_before_provider_cost',true"));
});

let passed=0;
console.log("\nMarketRoute V2 — R4 persistence ambiguity hotfix 0.18.3.12");
for(const [name,fn] of checks){
  try{fn();passed++;console.log(`PASS  ${name}`);}
  catch(error){console.error(`FAIL  ${name}: ${error instanceof Error?error.message:error}`);}
}
console.log(`\n${passed}/${checks.length} PASS`);
if(passed!==checks.length)process.exitCode=1;
