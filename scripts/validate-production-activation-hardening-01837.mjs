import fs from "node:fs";
import path from "node:path";
import assert from "node:assert/strict";

const root=path.resolve(import.meta.dirname,"..");
const read=(file)=>fs.readFileSync(path.join(root,file),"utf8");
const migration=read("supabase/migrations/0027_production_activation_hardening.sql");
const session=read("application/session/service.ts");
const setup=read("app/setup/page.tsx");
const api=read("app/api/session/setup/route.ts");
const extractor=read("platform/ai/openai-seller-genome-extractor.ts");
const bootstrap=read("application/production/bootstrap.ts");
const targets=read("application/production/activation-targets.ts");
const repository=read("platform/database/production-activation-repository.ts");
const observability=read("application/production/observability.ts");
const route=read("app/api/cron/bootstrap/route.ts");

const checks=[];
function check(name,fn){try{fn();checks.push([name,true]);}catch(error){checks.push([name,false,error?.message??String(error)]);}}

check("first-party offering is captured end to end",()=>{for(const source of [migration,session,setup,api,extractor,bootstrap,repository])assert.match(source,/seller[_A-Z]?Offering|seller_offering/i);assert.match(extractor,/user_declared_offering/);});
check("website analysis remains fresh and domain scoped",()=>{assert.match(extractor,/webSearch:true/);assert.match(extractor,/allowedDomains:websiteUrl/);assert.match(extractor,/Freshly (?:inspect|research)/);});
check("constraint contradiction fails closed",()=>{assert.match(session,/MARKETROUTE_SETUP_CONSTRAINT_CONFLICT/);assert.match(migration,/v_no_hard AND v_hard IS NOT NULL[\s\S]*MARKETROUTE_SETUP_CONSTRAINT_CONFLICT/);assert.match(setup,/type="radio"[\s\S]*constraintMode/);assert.doesNotMatch(setup,/name="noHardConstraints"/);});
check("corrected submissions reset exhausted attempts",()=>{assert.match(migration,/ON CONFLICT\(organisation_id\)[\s\S]*attempt_count=0/);assert.ok((migration.match(/attempt_count=0/g)??[]).length>=2);assert.ok((migration.match(/'PENDING',0,now\(\)/g)??[]).length>=2);});
check("V2 claim requires explicit offering",()=>{assert.match(migration,/marketroute_claim_workspace_activation_v2/);assert.match(migration,/j\.seller_offering_text IS NOT NULL/);assert.match(repository,/marketroute_claim_workspace_activation_v[23]/);});
check("Genesis bank is queried before paid fallback",()=>{assert.match(repository,/marketroute_activation_bank_candidates_v1/);assert.match(bootstrap,/repo\.bankCandidates/);assert.ok(bootstrap.indexOf("repo.bankCandidates")<bootstrap.indexOf("openAITargetDiscoveryProviderFromEnvironment"+"().discover"));assert.match(bootstrap,/candidates\.length<minimumBankTargets/);});
check("bank retrieval is explicit and core-complete",()=>{assert.match(migration,/m\.industry_key=ANY\(p_industry_keys\)/);assert.match(migration,/p\.core_complete_at IS NOT NULL/);assert.match(migration,/p_country_codes/);assert.match(migration,/contacts_complete DESC,e\.routes_complete DESC,e\.profile_complete DESC/);});
check("logistics and UK canonical aliases exist",()=>{assert.match(targets,/logistics:\[/);assert.match(targets,/supply_chain/);assert.match(targets,/uk:"GB"/);});
check("bootstrap logical failure is observable",()=>{assert.match(bootstrap,/"PARTIAL"/);assert.match(bootstrap,/"FAILED"/);assert.match(observability,/status==="FAILED"\|\|status==="PARTIAL"/);assert.match(route,/result\.status==="FAILED"\?500/);assert.match(route,/result\.status==="PARTIAL"\?207/);});
check("no commercial authority writer added",()=>{assert.doesNotMatch(migration,/INSERT INTO public\.(commercial_reality_r4_records|route_authority_r5_records|contact_authority_r6_records|opportunities|engagement_messages)/i);assert.match(migration,/new_authority_writer',false/);});
check("service-role bank boundary is preserved",()=>{assert.match(migration,/marketroute_activation_bank_candidates_v1[\s\S]*marketroute_require_service_role/);assert.match(migration,/GRANT EXECUTE ON FUNCTION public\.marketroute_activation_bank_candidates_v1[\s\S]*TO service_role/);});
check("migration is transactional",()=>{assert.match(migration,/^BEGIN;/);assert.match(migration,/COMMIT;\s*$/);});

for(const [name,ok,message] of checks)console.log(`${ok?"PASS":"FAIL"} ${name}${message?`: ${message}`:""}`);
if(checks.some(([,ok])=>!ok))process.exit(1);
console.log(`\n${checks.length}/${checks.length} activation-hardening checks passed.`);
