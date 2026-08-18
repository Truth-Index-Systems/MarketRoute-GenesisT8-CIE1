import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const root=path.resolve(import.meta.dirname,"..");
const read=p=>fs.readFileSync(path.join(root,p),"utf8");
const migration=read("supabase/migrations/0048_anonymous_discovery_launch_cost_freeze.sql");
const service=read("application/discovery/service.ts");
const env=read(".env.example");
const bootstrap=read("application/production/bootstrap.ts");
const freeEight=read("supabase/migrations/0043_product_free_eight_account_claim.sql");
const pkg=JSON.parse(read("package.json"));
const tests=[];
const check=(name,fn)=>tests.push([name,fn]);

check("launch policy is frozen at 8 free / 10 targets / USD1 / 12h",()=>{
  assert.match(service,/ANONYMOUS_DISCOVERY_LAUNCH_POLICY=Object\.freeze\(\{freeOpportunityLimit:8,targetCount:10,lifetimeBudgetUsd:1,researchWindowHours:12\}\)/);
  assert.match(migration,/'anonymous_free_opportunity_limit',8/);
  assert.match(migration,/'anonymous_target_company_ceiling',10/);
  assert.match(migration,/'anonymous_lifetime_ai_budget_usd',1\.00/);
  assert.match(migration,/'anonymous_research_window_hours',12/);
});
check("application environment values can lower but cannot raise launch ceilings",()=>{
  assert.match(service,/MARKETROUTE_ANONYMOUS_RESEARCH_BUDGET_USD[\s\S]*ANONYMOUS_DISCOVERY_LAUNCH_POLICY\.lifetimeBudgetUsd,0\.5,ANONYMOUS_DISCOVERY_LAUNCH_POLICY\.lifetimeBudgetUsd/);
  assert.match(service,/MARKETROUTE_ANONYMOUS_RESEARCH_WINDOW_HOURS[\s\S]*ANONYMOUS_DISCOVERY_LAUNCH_POLICY\.researchWindowHours,1,ANONYMOUS_DISCOVERY_LAUNCH_POLICY\.researchWindowHours/);
  assert.match(service,/MARKETROUTE_ANONYMOUS_TARGET_COUNT[\s\S]*ANONYMOUS_DISCOVERY_LAUNCH_POLICY\.targetCount,ANONYMOUS_DISCOVERY_LAUNCH_POLICY\.freeOpportunityLimit,ANONYMOUS_DISCOVERY_LAUNCH_POLICY\.targetCount/);
});
check("database independently clamps budget, window and target ceiling",()=>{
  assert.match(migration,/v_budget numeric:=LEAST\(1\.00::numeric,GREATEST\(0\.50::numeric/);
  assert.match(migration,/v_hours integer:=LEAST\(12,GREATEST\(1/);
  assert.match(migration,/v_target_count integer:=LEAST\(10,GREATEST\(8/);
  assert.match(migration,/v_budget>1\.00[\s\S]*v_hours>12[\s\S]*v_target_count>10/);
});
check("existing active or claimed anonymous runs are tightened without deleting lineage",()=>{
  assert.match(migration,/UPDATE public\.anonymous_discovery_runs/);
  assert.match(migration,/lifetime_budget_usd = LEAST\(lifetime_budget_usd, 1\.00::numeric\)/);
  assert.match(migration,/target_count = LEAST\(target_count, 10\)/);
  assert.match(migration,/research_expires_at = LEAST\(research_expires_at, created_at \+ interval '12 hours'\)/);
  assert.match(migration,/status IN \('ACTIVE','CLAIMED'\)/);
  assert.doesNotMatch(migration,/DELETE\s+FROM\s+public\.(?:organisation_company_scopes|opportunities|evidence_items|claims)/i);
});
check("ten scoped companies plus permanent free eight bounds post-free company opportunities to two",()=>{
  assert.match(freeEight,/ordinal integer NOT NULL CHECK \(ordinal BETWEEN 1 AND 8\)/);
  assert.match(migration,/'anonymous_max_post_free_companies',2/);
  assert.match(migration,/'anonymous_locked_teaser_ceiling',2/);
  assert.match(migration,/locked_limited AS \([\s\S]*LIMIT 2/);
  assert.match(bootstrap,/desiredCount=anonymous\?\.targetCount/);
});
check("env example uses the frozen launch defaults",()=>{
  assert.match(env,/MARKETROUTE_ANONYMOUS_RESEARCH_BUDGET_USD=1(?:\r?\n)/);
  assert.match(env,/MARKETROUTE_ANONYMOUS_RESEARCH_WINDOW_HOURS=12(?:\r?\n)/);
  assert.match(env,/MARKETROUTE_ANONYMOUS_TARGET_COUNT=10(?:\r?\n)/);
});
check("anonymous launch freeze remains service-role mediated",()=>{
  assert.match(migration,/PERFORM public\.marketroute_require_service_role\(\)/);
  assert.match(migration,/REVOKE ALL ON FUNCTION public\.marketroute_create_anonymous_discovery_v1[\s\S]*FROM PUBLIC,anon,authenticated/);
  assert.match(migration,/GRANT EXECUTE ON FUNCTION public\.marketroute_create_anonymous_discovery_v1[\s\S]*TO service_role/);
});
check("launch freeze cannot create commercial authority",()=>{
  assert.match(migration,/'new_authority_writer',false/);
  assert.match(migration,/'authority_semantics_unchanged',true/);
  assert.doesNotMatch(migration,/INSERT\s+INTO\s+public\.(?:commercial_reality_r4_records|route_authority_r5_records|contact_authority_r6_records|authority_records|opportunities|claims|evidence_items)/i);
});
check("growth and outbound delivery remain off",()=>{
  assert.match(migration,/'growth_reactivated',false/);
  assert.match(migration,/'delivery_enabled',false/);
});
check("launch-cost freeze validation is wired into production check",()=>{
  assert(pkg.scripts["validate:anonymous-launch-freeze"]);
  assert.match(pkg.scripts["production:check"],/validate:anonymous-launch-freeze/);
});

let passed=0;
console.log("\nMarketRoute V2 — Anonymous Discovery Launch Cost Freeze static gate");
for(const [name,fn] of tests){
  try{fn();passed++;console.log(`PASS  ${name}`)}
  catch(error){console.error(`FAIL  ${name}: ${error instanceof Error?error.message:error}`)}
}
console.log(`\n${passed}/${tests.length} PASS`);
if(passed!==tests.length)process.exitCode=1;
