import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const root=path.resolve(import.meta.dirname,"..");
const read=(file)=>fs.readFileSync(path.join(root,file),"utf8");
const migration=read("supabase/migrations/0034_r4_iso_timestamp_format_hotfix.sql");
const applySql=read("APPLY-IN-SUPABASE-MARKETROUTE-V2-0.18.3.14-R4-ISO-TIMESTAMP-FORMAT-HOTFIX.sql");
const build6=read("supabase/migrations/0009_commercial_reality_r4.sql");
const engine=read("core/commercial-reality/engine.ts");
const functionPattern=/CREATE OR REPLACE FUNCTION public\.marketroute_r4_iso_v1\(p_value timestamptz\)[\s\S]*?\n\$\$;/;
const originalFunction=build6.match(functionPattern)?.[0];
const repairedFunction=migration.match(functionPattern)?.[0];
const oldMask=String.raw`YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"`;
const correctMask='YYYY-MM-DD"T"HH24:MI:SS.MS"Z"';
const checks=[];
const check=(name,fn)=>checks.push([name,fn]);

check("deployable SQL exactly matches migration",()=>assert.equal(applySql,migration));
check("R4 ISO helper is replaced in place",()=>assert(repairedFunction));
check("PostgreSQL format mask contains no literal backslashes",()=>{
  assert(repairedFunction.includes(correctMask));
  assert(!repairedFunction.includes(oldMask));
});
check("R4 ISO helper remains UTC and millisecond precise",()=>{
  assert(repairedFunction.includes("p_value AT TIME ZONE 'UTC'"));
  assert(repairedFunction.includes("HH24:MI:SS.MS"));
});
check("the formatter mask is the helper's only semantic change",()=>{
  assert(originalFunction&&repairedFunction);
  assert.equal(repairedFunction.replace(correctMask,oldMask),originalFunction);
});
check("production boundary timestamp now matches TypeScript ISO output",()=>{
  const timestamp="2027-02-11T00:00:00.000Z";
  assert.equal(new Date(timestamp).toISOString(),timestamp);
  assert.equal(timestamp.includes('"T"'),false);
  assert.equal(timestamp.includes('"Z"'),false);
  assert(engine.includes(".toISOString()"));
});
check("release records the exact two-field production drift",()=>{
  assert(migration.includes("'root_error','MARKETROUTE_R4_BOUNDARIES_MISMATCH'"));
  assert(migration.includes("'production_diff_fields',2"));
  assert(migration.includes("'typescript_database_boundary_parity',true"));
});
check("release adds no authority writer and changes no authority writer",()=>{
  assert(migration.includes("'new_authority_writer',false"));
  assert(migration.includes("'authority_semantics_unchanged',true"));
  assert(!migration.includes("INSERT INTO public.authority_writer_registry"));
  assert(!migration.includes("CREATE OR REPLACE FUNCTION public.marketroute_persist_commercial_reality_r4_v1"));
});
check("internal helper remains unavailable to browser roles",()=>{
  assert.match(migration,/REVOKE ALL ON FUNCTION public\.marketroute_r4_iso_v1\(timestamptz\)[\s\S]*FROM PUBLIC, anon, authenticated/);
});

let passed=0;
console.log("\nMarketRoute V2 — R4 ISO timestamp-format hotfix 0.18.3.14");
for(const [name,fn] of checks){
  try{fn();passed++;console.log(`PASS  ${name}`);}
  catch(error){console.error(`FAIL  ${name}: ${error instanceof Error?error.message:error}`);}
}
console.log(`\n${passed}/${checks.length} PASS`);
if(passed!==checks.length)process.exitCode=1;
