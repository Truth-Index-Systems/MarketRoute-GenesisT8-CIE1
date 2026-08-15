import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const root=path.resolve(import.meta.dirname,"..");
const read=(file)=>fs.readFileSync(path.join(root,file),"utf8");
const migration=read("supabase/migrations/0028_seller_genome_json_operator_hotfix.sql");
const applySql=read("APPLY-IN-SUPABASE-MARKETROUTE-V2-0.18.3.8-SELLER-GENOME-JSON-HOTFIX.sql");
const rpc=read("platform/database/postgrest-rpc.ts");
const bootstrap=read("application/production/bootstrap.ts");
const dimensions=["offerings","capabilities","commercialObjectives","constraints","delivery","serviceGeography","targetCharacteristics","buyerAssumptions"];
const authorityWrite=/INSERT\s+INTO\s+public\.(?:commercial_reality_r4_records|route_authority_r5_records|contact_authority_r6_records|authority_records)/i;
const checks=[];
const check=(name,fn)=>checks.push([name,fn]);

check("deployable SQL exactly matches migration",()=>assert.equal(applySql,migration));
check("validator signature is replaced in place",()=>assert.match(migration,/CREATE OR REPLACE FUNCTION public\.marketroute_seller_genome_validate_v1\(\s*p_seller_business_id uuid,\s*p_genome jsonb\s*\)/));
check("validator remains stable and security definer",()=>{assert.match(migration,/LANGUAGE plpgsql\s+STABLE\s+SECURITY DEFINER/);assert.match(migration,/SET search_path = public, pg_temp, extensions/);});
check("all dimension extractions are parenthesised before key removal",()=>{for(const dimension of dimensions)assert(migration.includes(`(v_semantic->'${dimension}') - ARRAY`),dimension);});
check("ambiguous dimension extraction/removal forms are absent",()=>{for(const dimension of dimensions)assert(!migration.includes(`(v_semantic->'${dimension}' - ARRAY`),dimension);});
check("all eight exact-key checks remain present",()=>assert.equal(dimensions.filter(dimension=>migration.includes(`(v_semantic->'${dimension}') - ARRAY`)).length,8));
check("release metadata identifies SQLSTATE 22P02",()=>{assert(migration.includes("MARKETROUTE_V2_SELLER_GENOME_JSON_OPERATOR_HOTFIX_0_18_3_8"));assert(migration.includes("'sqlstate_fixed','22P02'"));});
check("hotfix creates no authority writer",()=>{assert(migration.includes("'new_authority_writer',false"));assert(!authorityWrite.test(migration));});
check("database RPC errors retain function and SQLSTATE context",()=>{assert(rpc.includes("readonly functionName: string"));assert(rpc.includes("MARKETROUTE_DATABASE_RPC_FAILED"));assert(rpc.includes("error.code ?? String(error.status)"));});
check("activation persists bounded structured diagnostics",()=>{assert(bootstrap.includes("marketrouteErrorCode(error"));assert(rpc.includes(".slice(0, 500)"));});

let passed=0;
console.log("\nMarketRoute V2 — Seller-genome JSON hotfix 0.18.3.8");
for(const [name,fn] of checks){try{fn();passed++;console.log(`PASS  ${name}`);}catch(error){console.error(`FAIL  ${name}: ${error instanceof Error?error.message:error}`);}}
console.log(`\n${passed}/${checks.length} PASS`);
if(passed!==checks.length)process.exitCode=1;
