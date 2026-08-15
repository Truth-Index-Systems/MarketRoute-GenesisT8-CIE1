import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const root=path.resolve(import.meta.dirname,"..");
const read=(file)=>fs.readFileSync(path.join(root,file),"utf8");
const migration=read("supabase/migrations/0033_r4_context_snapshot_array_hotfix.sql");
const applySql=read("APPLY-IN-SUPABASE-MARKETROUTE-V2-0.18.3.13-R4-CONTEXT-SNAPSHOT-ARRAY-HOTFIX.sql");
const build6=read("supabase/migrations/0009_commercial_reality_r4.sql");
const functionPattern=/CREATE OR REPLACE FUNCTION public\.marketroute_r4_truth_set_v1\(p_snapshot_ids jsonb\)[\s\S]*?\n\$\$;/;
const originalFunction=build6.match(functionPattern)?.[0];
const repairedFunction=migration.match(functionPattern)?.[0];
const adapter=`
  -- marketroute_get_r4_context_v1 deliberately returns full snapshot objects
  -- to the deterministic TypeScript engine. The database verifier consumes
  -- the same context, so reduce that shape back to its authoritative IDs.
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_snapshot_ids) AS e(value)
    WHERE jsonb_typeof(e.value) = 'object'
  ) THEN
    IF EXISTS (
      SELECT 1
      FROM jsonb_array_elements(p_snapshot_ids) AS e(value)
      WHERE jsonb_typeof(e.value) IS DISTINCT FROM 'object'
         OR jsonb_typeof(e.value -> 'snapshotId') IS DISTINCT FROM 'string'
         OR (e.value ->> 'snapshotId') !~ '^[0-9a-fA-F-]{36}$'
    ) THEN
      RAISE EXCEPTION 'MARKETROUTE_R4_SNAPSHOT_ID_ARRAY_INVALID';
    END IF;

    SELECT COALESCE(
      jsonb_agg(e.value ->> 'snapshotId' ORDER BY e.value ->> 'snapshotId'),
      '[]'::jsonb
    )
    INTO p_snapshot_ids
    FROM jsonb_array_elements(p_snapshot_ids) AS e(value);
  END IF;
`;
const checks=[];
const check=(name,fn)=>checks.push([name,fn]);

check("deployable SQL exactly matches migration",()=>assert.equal(applySql,migration));
check("R4 Truth helper is replaced in place",()=>assert(repairedFunction));
check("enriched context objects are reduced to ordered snapshot IDs",()=>{
  assert(repairedFunction.includes("jsonb_typeof(e.value -> 'snapshotId') IS DISTINCT FROM 'string'"));
  assert(repairedFunction.includes("jsonb_agg(e.value ->> 'snapshotId' ORDER BY e.value ->> 'snapshotId')"));
});
check("mixed or malformed context arrays remain rejected",()=>{
  assert(repairedFunction.includes("jsonb_typeof(e.value) IS DISTINCT FROM 'object'"));
  assert(repairedFunction.includes("RAISE EXCEPTION 'MARKETROUTE_R4_SNAPSHOT_ID_ARRAY_INVALID'"));
});
check("authoritative database snapshot lookup remains mandatory",()=>{
  assert(repairedFunction.includes("FROM public.truth_claim_snapshots t"));
  assert(repairedFunction.includes("RAISE EXCEPTION 'MARKETROUTE_R4_TRUTH_SNAPSHOT_NOT_FOUND'"));
});
check("Truth resolution semantics are byte-identical after adapter removal",()=>{
  assert(originalFunction&&repairedFunction);
  assert.equal(repairedFunction.replace(adapter,"").replace("  END IF;\n\n  IF EXISTS (","  END IF;\n  IF EXISTS ("),originalFunction);
});
check("release adds no authority writer and replaces no authority writer",()=>{
  assert(migration.includes("'new_authority_writer',false"));
  assert(migration.includes("'authority_semantics_unchanged',true"));
  assert(!migration.includes("INSERT INTO public.authority_writer_registry"));
  assert(!migration.includes("CREATE OR REPLACE FUNCTION public.marketroute_persist_commercial_reality_r4_v1"));
});
check("internal helper remains unavailable to browser roles",()=>{
  assert.match(migration,/REVOKE ALL ON FUNCTION public\.marketroute_r4_truth_set_v1\(jsonb\) FROM PUBLIC, anon, authenticated/);
});

let passed=0;
console.log("\nMarketRoute V2 — R4 context snapshot-array hotfix 0.18.3.13");
for(const [name,fn] of checks){
  try{fn();passed++;console.log(`PASS  ${name}`);}
  catch(error){console.error(`FAIL  ${name}: ${error instanceof Error?error.message:error}`);}
}
console.log(`\n${passed}/${checks.length} PASS`);
if(passed!==checks.length)process.exitCode=1;
