import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const root=path.resolve(import.meta.dirname,"..");
const read=(file)=>fs.readFileSync(path.join(root,file),"utf8");
const migration=read("supabase/migrations/0029_activation_company_domain_hotfix.sql");
const applySql=read("APPLY-IN-SUPABASE-MARKETROUTE-V2-0.18.3.9-ACTIVATION-COMPANY-DOMAIN-HOTFIX.sql");
const discovery=read("platform/ai/openai-target-discovery.ts");
const activation=read("application/production/bootstrap.ts");
const authorityWrite=/INSERT\s+INTO\s+public\.(?:commercial_reality_r4_records|route_authority_r5_records|contact_authority_r6_records|authority_records)/i;
const checks=[];
const check=(name,fn)=>checks.push([name,fn]);

check("deployable SQL exactly matches migration",()=>assert.equal(applySql,migration));
check("activation company RPC is replaced in place",()=>assert.match(migration,/CREATE OR REPLACE FUNCTION public\.marketroute_ensure_activation_company_v1\(/));
check("www normalisation avoids backslash ambiguity",()=>assert(migration.includes("'^www[.]'")));
check("domain validation avoids backslash ambiguity",()=>assert(migration.includes("'^[a-z0-9][a-z0-9.-]*[.][a-z]{2,63}$'")));
check("double-dot hostnames fail closed",()=>assert(migration.includes("v_domain ~ '[.][.]'")));
check("valid domain regression is recorded",()=>assert(migration.includes("'valid_domain_regression','example.com'")));
check("empty new-company names fail explicitly",()=>assert(migration.includes("MARKETROUTE_ACTIVATION_COMPANY_NAME_INVALID")));
check("web discovery drops empty company names before persistence",()=>assert(discovery.includes("if(!name||!/")&&discovery.includes("companies.push({name,domain:d")));
check("campaign scoping remains idempotent",()=>assert.match(migration,/INSERT INTO public\.organisation_company_scopes[\s\S]*ON CONFLICT DO NOTHING/));
check("service-role execution boundary is preserved",()=>{assert.match(migration,/REVOKE ALL ON FUNCTION[\s\S]*FROM PUBLIC, anon, authenticated/);assert.match(migration,/GRANT EXECUTE ON FUNCTION[\s\S]*TO service_role/);});
check("hotfix creates no authority writer",()=>{assert(migration.includes("'new_authority_writer',false"));assert(!authorityWrite.test(migration));});
check("activation remains Genesis-bank-first",()=>assert(activation.indexOf("repo.bankCandidates")<activation.indexOf(".discover(")));

let passed=0;
console.log("\nMarketRoute V2 — Activation company-domain hotfix 0.18.3.9");
for(const [name,fn] of checks){try{fn();passed++;console.log(`PASS  ${name}`);}catch(error){console.error(`FAIL  ${name}: ${error instanceof Error?error.message:error}`);}}
console.log(`\n${passed}/${checks.length} PASS`);
if(passed!==checks.length)process.exitCode=1;
