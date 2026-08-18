import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const root=path.resolve(import.meta.dirname,"../..");
const read=p=>fs.readFileSync(path.join(root,p),"utf8");
const migration=read("supabase/migrations/0048_anonymous_discovery_launch_cost_freeze.sql");
const service=read("application/discovery/service.ts");
const freeEight=read("supabase/migrations/0043_product_free_eight_account_claim.sql");
const tests=[];
const check=(name,fn)=>tests.push([name,fn]);

const clamp=(value,fallback,min,max)=>{
  const n=Number(value??fallback);
  return Number.isFinite(n)?Math.max(min,Math.min(max,n)):fallback;
};
const policy=(env={})=>({
  budget:clamp(env.budget,1,.5,1),
  hours:Math.floor(clamp(env.hours,12,1,12)),
  target:Math.floor(clamp(env.target,10,8,10)),
  free:8
});

check("hostile high environment values cannot create an expensive free run",()=>{
  assert.deepEqual(policy({budget:999,hours:999,target:999}),{budget:1,hours:12,target:10,free:8});
  assert.match(service,/boundedNumber\("MARKETROUTE_ANONYMOUS_RESEARCH_BUDGET_USD"[\s\S]*ANONYMOUS_DISCOVERY_LAUNCH_POLICY\.lifetimeBudgetUsd\)/);
  assert.match(migration,/LEAST\(1\.00::numeric/);
});
check("lower emergency cost settings remain possible",()=>{
  assert.deepEqual(policy({budget:.5,hours:4,target:8}),{budget:.5,hours:4,target:8,free:8});
});
check("missing or malformed environment values fail back to launch defaults",()=>{
  assert.deepEqual(policy({}),{budget:1,hours:12,target:10,free:8});
  assert.deepEqual(policy({budget:"wat",hours:"wat",target:"wat"}),{budget:1,hours:12,target:10,free:8});
});
check("free run cannot expose more than two post-free company slots at target ceiling",()=>{
  const p=policy({budget:1,hours:12,target:10});
  assert.equal(Math.max(0,p.target-p.free),2);
  assert.match(freeEight,/ordinal BETWEEN 1 AND 8/);
  assert.match(migration,/'anonymous_max_post_free_companies',2/);
  assert.match(migration,/locked_limited AS \([\s\S]*LIMIT 2/);
  assert.match(migration,/v_locked_count,v_locked[\s\S]*FROM locked_limited l/);
});
check("database clamps even if application boundary is bypassed by service credentials",()=>{
  assert.match(migration,/v_budget numeric:=LEAST\(1\.00::numeric,GREATEST\(0\.50::numeric/);
  assert.match(migration,/v_hours integer:=LEAST\(12,GREATEST\(1/);
  assert.match(migration,/v_target_count integer:=LEAST\(10,GREATEST\(8/);
});
check("pre-existing generous active runs are tightened rather than grandfathered",()=>{
  const existing={budget:3,target:12,hours:24};
  const tightened={budget:Math.min(existing.budget,1),target:Math.min(existing.target,10),hours:Math.min(existing.hours,12)};
  assert.deepEqual(tightened,{budget:1,target:10,hours:12});
  assert.match(migration,/WHERE status IN \('ACTIVE','CLAIMED'\)/);
});
check("tightening cannot delete existing evidence, companies or opportunities",()=>{
  assert.doesNotMatch(migration,/DELETE\s+FROM/i);
  assert.doesNotMatch(migration,/TRUNCATE/i);
});
check("browser cannot directly choose budget/window/target inputs",()=>{
  const start=read("app/api/discovery/start/route.ts");
  assert.doesNotMatch(start,/form\.get\(["'](?:budget|researchBudget|researchWindowHours|targetCount|companyCount)["']/i);
});
check("launch freeze cannot alter paid plan capacity",()=>{
  assert.match(migration,/IF FOUND AND v_ent\.plan_code IN\('STARTER','GROWTH','SCALE','LEGACY_FULL'\)/);
  assert.match(migration,/v_capacity:=public\.marketroute_research_capacity_snapshot_v1\(p_organisation_id,p_at\)/);
  assert.doesNotMatch(migration,/UPDATE\s+public\.(?:marketroute_plan_catalog|organisation_commercial_entitlements)/i);
  assert(migration.indexOf("locked_limited AS")>migration.indexOf("a.status='CLAIMED'"));
});
check("launch freeze cannot become an authority writer",()=>{
  assert.doesNotMatch(migration,/authority_writer_registry/);
  assert.doesNotMatch(migration,/INSERT\s+INTO\s+public\.(?:commercial_reality_r4_records|route_authority_r5_records|contact_authority_r6_records|authority_records)/i);
});

let passed=0;
console.log("\nMarketRoute V2 — Anonymous Discovery Launch Cost Freeze adversarial gate");
for(const [name,fn] of tests){
  try{fn();passed++;console.log(`PASS  ${name}`)}
  catch(error){console.error(`FAIL  ${name}: ${error instanceof Error?error.message:error}`)}
}
console.log(`\n${passed}/${tests.length} PASS`);
if(passed!==tests.length)process.exitCode=1;
