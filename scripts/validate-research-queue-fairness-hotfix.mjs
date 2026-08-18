import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const root=path.resolve(import.meta.dirname,"..");
const read=p=>fs.readFileSync(path.join(root,p),"utf8");
const migration=read("supabase/migrations/0047_research_queue_fairness_hotfix.sql");
const pkg=JSON.parse(read("package.json"));
const tests=[];
const check=(name,fn)=>tests.push([name,fn]);

check("hotfix replaces only the existing research claim boundary",()=>{
  assert.match(migration,/CREATE OR REPLACE FUNCTION public\.marketroute_claim_research_work_v1/);
  assert.doesNotMatch(migration,/CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+public\.marketroute_(?:persist_r4|persist_r5|persist_r6)/i);
});
check("claim candidates are restricted to active campaigns",()=>{
  assert.match(migration,/JOIN public\.campaigns AS c/);
  assert.match(migration,/c\.workflow_state = 'ACTIVE'/);
});
check("explicitly disabled research policies are filtered before ordering",()=>{
  assert.match(migration,/SELECT p\.enabled[\s\S]*research_budget_policies/);
  assert.match(migration,/COALESCE\(\([\s\S]*p\.enabled[\s\S]*\), true\)/);
});
check("blocked queue head continues instead of terminating claim",()=>{
  assert.match(migration,/\bLOOP\b/);
  const beforeReserve=migration.split("v_attempt :=")[0];
  const continues=(beforeReserve.match(/\bCONTINUE;/g)||[]).length;
  assert(continues>=4,`expected multiple CONTINUE branches, got ${continues}`);
  assert.match(migration,/IF NOT FOUND THEN\s+RETURN NULL;/);
});
check("campaign-level concurrency block skips only that campaign",()=>{
  assert.match(migration,/v_skip_campaigns/);
  assert.match(migration,/array_append\(v_skip_campaigns, v_work\.campaign_id\)/);
  assert.match(migration,/activeJobs[\s\S]*CONTINUE;/);
});
check("organisation plan-capacity block skips only that organisation",()=>{
  assert.match(migration,/v_skip_organisations/);
  assert.match(migration,/MARKETROUTE_PLAN_RESEARCH_CAPACITY_EXHAUSTED/);
  assert.match(migration,/array_append\([\s\S]*v_skip_organisations[\s\S]*v_work\.organisation_id/);
});
check("archived queued work is terminally cancelled while paused work is retained",()=>{
  const cleanup=migration.split("Archived campaigns retain")[1].split("LOOP")[0];
  assert.match(cleanup,/c\.workflow_state = 'ARCHIVED'/);
  assert.match(cleanup,/status = 'CANCELLED'/);
  assert.match(cleanup,/MARKETROUTE_CAMPAIGN_ARCHIVED/);
  assert.doesNotMatch(cleanup,/workflow_state\s*=\s*'PAUSED'/);
});
check("unit budget rejection continues scanning for zero-cost deterministic work",()=>{
  const budget=migration.split("This remains deliberately unit-specific")[1].split("v_attempt :=")[0];
  assert.match(budget,/v_work\.cost_ceiling_usd > greatest\(0, v_remaining\)/);
  assert.match(budget,/CONTINUE;/);
  assert.doesNotMatch(budget,/v_skip_campaigns\s*:=/);
  assert.match(budget,/v_skip_work_units/);
});
check("zero-cost work still reserves a canonical zero-dollar budget event",()=>{
  assert.match(migration,/event_type,[\s\S]*amount_usd/);
  assert.match(migration,/'RESERVE',[\s\S]*v_work\.cost_ceiling_usd/);
});
check("anonymous discovery and paid entitlement boundaries are preserved",()=>{
  assert.match(migration,/anonymous_discovery_runs/);
  assert.match(migration,/marketroute_paid_entitlement_active_v1/);
  assert.match(migration,/MARKETROUTE_ANONYMOUS_RESEARCH_WINDOW_CLOSED/);
  assert.match(migration,/MARKETROUTE_ANONYMOUS_RESEARCH_BUDGET_EXHAUSTED/);
});
check("claim still requires a live research scheduler lease",()=>{
  assert.match(migration,/MARKETROUTE_RESEARCH_SCHEDULER_RUN_REQUIRED/);
  assert.match(migration,/lease_key = 'GENESIS_RESEARCH_V1'/);
  assert.match(migration,/l\.expires_at > p_at/);
});
check("claim remains service-role only",()=>{
  assert.match(migration,/REVOKE ALL ON FUNCTION public\.marketroute_claim_research_work_v1\(uuid,timestamptz\)/);
  assert.match(migration,/GRANT EXECUTE ON FUNCTION public\.marketroute_claim_research_work_v1\(uuid,timestamptz\)[\s\S]*TO service_role/);
});
check("hotfix is constitutionally non-authoritative",()=>{
  assert.match(migration,/'new_authority_writer',false/);
  assert.match(migration,/'authority_semantics_unchanged',true/);
  assert.doesNotMatch(migration,/INSERT\s+INTO\s+public\.(?:commercial_reality_r4_records|route_authority_r5_records|contact_authority_r6_records|authority_records|opportunities|claims|evidence_items)/i);
});
check("growth and delivery remain disabled",()=>{
  assert.match(migration,/'growth_reactivated',false/);
  assert.match(migration,/'delivery_enabled',false/);
});
check("queue fairness gate is wired into production check",()=>{
  assert(pkg.scripts["validate:research-queue-fairness"]);
  assert.match(pkg.scripts["production:check"],/validate:research-queue-fairness/);
});

let passed=0;
console.log("\nMarketRoute V2 — Research Queue Fairness Hotfix static gate");
for(const [name,fn] of tests){
  try{fn();passed++;console.log(`PASS  ${name}`)}
  catch(error){console.error(`FAIL  ${name}: ${error instanceof Error?error.message:error}`)}
}
console.log(`\n${passed}/${tests.length} PASS`);
if(passed!==tests.length)process.exitCode=1;
