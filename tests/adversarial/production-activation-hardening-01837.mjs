import fs from "node:fs";
import path from "node:path";
import assert from "node:assert/strict";

const root=path.resolve(import.meta.dirname,"../..");
const read=(file)=>fs.readFileSync(path.join(root,file),"utf8");
const migration=read("supabase/migrations/0027_production_activation_hardening.sql");
const bootstrap=read("application/production/bootstrap.ts");
const extractor=read("platform/ai/openai-seller-genome-extractor.ts");
const provider=read("platform/ai/openai-target-discovery.ts");
const targets=read("application/production/activation-targets.ts");
const setupRoute=read("app/api/session/setup/route.ts");

const tests=[];const test=(name,fn)=>tests.push({name,fn});
test("checkbox ambiguity cannot cross the application boundary",()=>{assert.match(setupRoute,/\["DESCRIBED","NONE"\]/);assert.match(setupRoute,/constraintMode==="NONE"/);});
test("database rejects no-constraints plus written limits",()=>assert.equal((migration.match(/MARKETROUTE_SETUP_CONSTRAINT_CONFLICT/g)??[]).length,2));
test("new declaration cannot inherit exhausted attempts",()=>assert.ok((migration.match(/attempt_count=0/g)??[]).length>=2));
test("poor website indexing cannot erase first-party offering",()=>{assert.match(extractor,/offerings\.length===0&&sellerOfferingText/);assert.match(extractor,/user_declared_offering/);});
test("seller website is still analysed on every activation",()=>{assert.match(extractor,/webSearch:true/);assert.match(extractor,/tool|allowedDomains/);});
test("bank selection cannot silently broaden beyond explicit industries",()=>{assert.match(migration,/cardinality\(p_industry_keys\),0\)=0 THEN RETURN/);assert.match(migration,/m\.industry_key=ANY\(p_industry_keys\)/);});
test("hard country targeting is applied to bank candidates",()=>assert.match(migration,/upper\(COALESCE\(c\.country_code,''\)\)=ANY/));
test("research density orders reuse but never creates fit authority",()=>{const start=migration.indexOf("CREATE OR REPLACE FUNCTION public.marketroute_activation_bank_candidates_v1");const end=migration.indexOf("UPDATE public.workspace_activation_jobs",start);const functionBody=migration.slice(start,end);assert.ok(start>=0&&end>start);assert.doesNotMatch(functionBody,/score|rank|fit|viab|authority/i);assert.match(functionBody,/contacts_complete DESC/);});
test("paid discovery is conditional and excludes bank domains",()=>{assert.match(bootstrap,/if\(candidates\.length<minimumBankTargets\)/);assert.match(bootstrap,/excludedDomains:candidates\.map/);assert.match(provider,/seen=new Set<string>\(excluded\)/);});
test("empty bank plus empty web fails closed",()=>assert.match(bootstrap,/if\(candidates\.length===0\)throw new Error\("MARKETROUTE_TARGET_DISCOVERY_EMPTY"\)/));
test("AI still cannot emit commercial authority",()=>assert.match(provider,/Do not calculate or output fit, viability, confidence, scores, ranks, opportunity status, authority, or execution permission/));
test("target mapping is deterministic",()=>{assert.doesNotMatch(targets,/OpenAI|fetch|Math\.random/);assert.match(targets,/INDUSTRY_ALIASES/);assert.match(targets,/COUNTRY_ALIASES/);});

let passed=0;
for(const {name,fn} of tests){try{fn();passed++;console.log(`PASS ${name}`);}catch(error){console.error(`FAIL ${name}: ${error instanceof Error?error.message:error}`);}}
console.log(`\n${passed}/${tests.length} activation adversarial checks passed.`);
if(passed!==tests.length)process.exitCode=1;
