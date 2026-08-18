import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const root=path.resolve(import.meta.dirname,"../..");
const migration=fs.readFileSync(path.join(root,"supabase/migrations/0047_research_queue_fairness_hotfix.sql"),"utf8");
const tests=[];
const check=(name,fn)=>tests.push([name,fn]);

// Reference model for the queue contract introduced by 0047. This is deliberately
// small: static assertions below tie each behaviour back to the PL/pgSQL implementation.
function claimReference(rows,{remainingByCampaign={},concurrencyBlocked=new Set(),capacityBlocked=new Set()}={}){
  const ordered=[...rows]
    .filter(r=>r.status==="PENDING"||r.status==="DEFERRED")
    .filter(r=>r.available)
    .filter(r=>r.campaignState==="ACTIVE")
    .filter(r=>r.policyEnabled!==false)
    .sort((a,b)=>a.priority-b.priority||a.created-b.created||a.id.localeCompare(b.id));
  const skipCampaigns=new Set();
  const skipOrgs=new Set();
  for(const row of ordered){
    if(skipCampaigns.has(row.campaignId)||skipOrgs.has(row.orgId))continue;
    if(concurrencyBlocked.has(row.campaignId)){skipCampaigns.add(row.campaignId);continue;}
    if(capacityBlocked.has(row.orgId)){skipOrgs.add(row.orgId);continue;}
    const remaining=remainingByCampaign[row.campaignId]??Infinity;
    if(row.cost>remaining||row.cost>row.maxJobCost)continue;
    return row;
  }
  return null;
}

const row=(id,{priority=10,campaignId="c1",orgId="o1",campaignState="ACTIVE",policyEnabled=true,cost=.5,maxJobCost=.5,created=1,status="PENDING",available=true}={})=>({id,priority,campaignId,orgId,campaignState,policyEnabled,cost,maxJobCost,created,status,available});

check("blocked priority-10 campaign cannot starve runnable priority-20 campaign",()=>{
  const chosen=claimReference([
    row("blocked",{priority:10,campaignId:"blocked-c",orgId:"blocked-o"}),
    row("runnable",{priority:20,campaignId:"live-c",orgId:"live-o",cost:0,created:2})
  ],{concurrencyBlocked:new Set(["blocked-c"])});
  assert.equal(chosen?.id,"runnable");
  assert.match(migration,/activeJobs[\s\S]*v_skip_campaigns[\s\S]*CONTINUE;/);
});

check("archived priority-10 work cannot outrank active priority-20 work",()=>{
  const chosen=claimReference([
    row("archived",{priority:10,campaignId:"old",campaignState:"ARCHIVED"}),
    row("active",{priority:20,campaignId:"new",orgId:"o2",cost:0,created:2})
  ]);
  assert.equal(chosen?.id,"active");
  assert.match(migration,/c\.workflow_state = 'ACTIVE'/);
  assert.match(migration,/c\.workflow_state = 'ARCHIVED'[\s\S]*status = 'CANCELLED'|status = 'CANCELLED'[\s\S]*c\.workflow_state = 'ARCHIVED'/);
});

check("AI budget exhaustion cannot starve zero-cost deterministic revalidation",()=>{
  const chosen=claimReference([
    row("ai",{priority:10,campaignId:"same",cost:.5,created:1}),
    row("revalidate",{priority:20,campaignId:"same",cost:0,created:2})
  ],{remainingByCampaign:{same:0}});
  assert.equal(chosen?.id,"revalidate");
  const budget=migration.split("This remains deliberately unit-specific")[1].split("v_attempt :=")[0];
  assert.match(budget,/CONTINUE;/);
  assert.doesNotMatch(budget,/v_skip_campaigns\s*:=/);
  assert.match(budget,/v_skip_work_units/);
});

check("capacity-exhausted organisation cannot starve another organisation",()=>{
  const chosen=claimReference([
    row("full",{priority:10,campaignId:"c1",orgId:"full-o"}),
    row("other",{priority:20,campaignId:"c2",orgId:"other-o",cost:0,created:2})
  ],{capacityBlocked:new Set(["full-o"])});
  assert.equal(chosen?.id,"other");
  assert.match(migration,/MARKETROUTE_PLAN_RESEARCH_CAPACITY_EXHAUSTED[\s\S]*v_skip_organisations[\s\S]*CONTINUE;/);
});

check("paused campaign is not cancelled and is not claimable",()=>{
  const chosen=claimReference([
    row("paused",{priority:10,campaignState:"PAUSED"}),
    row("active",{priority:20,campaignId:"c2",orgId:"o2",cost:0,created:2})
  ]);
  assert.equal(chosen?.id,"active");
  const cleanup=migration.split("Archived campaigns retain")[1].split("LOOP")[0];
  assert.doesNotMatch(cleanup,/workflow_state = 'PAUSED'/);
});

check("disabled policy cannot become global queue head",()=>{
  const chosen=claimReference([
    row("disabled",{priority:1,policyEnabled:false}),
    row("active",{priority:20,campaignId:"c2",orgId:"o2",cost:0,created:2})
  ]);
  assert.equal(chosen?.id,"active");
  assert.match(migration,/SELECT p\.enabled[\s\S]*research_budget_policies/);
});

check("no runnable candidate returns null only after filtering/scanning",()=>{
  const chosen=claimReference([
    row("archived",{campaignState:"ARCHIVED"}),
    row("paused",{campaignId:"p",campaignState:"PAUSED"}),
    row("disabled",{campaignId:"d",policyEnabled:false})
  ]);
  assert.equal(chosen,null);
  assert.match(migration,/LOOP[\s\S]*IF NOT FOUND THEN\s+RETURN NULL;/);
});

check("unit-specific rejection is skipped for the remainder of the same claim call",()=>{
  assert.match(migration,/v_skip_work_units uuid\[\]/);
  assert.match(migration,/NOT \(w\.id = ANY\(v_skip_work_units\)\)/);
  assert.match(migration,/array_append\(v_skip_work_units, v_work\.id\)/);
});

check("hotfix cannot create a fourth authority writer",()=>{
  assert.doesNotMatch(migration,/authority_writer_registry/);
  assert.doesNotMatch(migration,/INSERT\s+INTO\s+public\.(?:commercial_reality_r4_records|route_authority_r5_records|contact_authority_r6_records|authority_records)/i);
});

let passed=0;
console.log("\nMarketRoute V2 — Research Queue Fairness Hotfix adversarial gate");
for(const [name,fn] of tests){
  try{fn();passed++;console.log(`PASS  ${name}`)}
  catch(error){console.error(`FAIL  ${name}: ${error instanceof Error?error.message:error}`)}
}
console.log(`\n${passed}/${tests.length} PASS`);
if(passed!==tests.length)process.exitCode=1;
