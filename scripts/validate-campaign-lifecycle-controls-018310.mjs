import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const root=path.resolve(import.meta.dirname,"..");
const read=(file)=>fs.readFileSync(path.join(root,file),"utf8");
const migration=read("supabase/migrations/0030_campaign_lifecycle_controls.sql");
const applySql=read("APPLY-IN-SUPABASE-MARKETROUTE-V2-0.18.3.10-CAMPAIGN-LIFECYCLE-CONTROLS.sql");
const component=read("ui/application/campaign-danger-zone.tsx");
const route=read("app/api/campaigns/[campaignId]/workflow/route.ts");
const detail=read("app/app/campaigns/[campaignId]/page.tsx");
const list=read("app/app/campaigns/page.tsx");
const authorityWrite=/INSERT\s+INTO\s+public\.(?:commercial_reality_r4_records|route_authority_r5_records|contact_authority_r6_records|authority_records)/i;
const checks=[];
const check=(name,fn)=>checks.push([name,fn]);

check("deployable SQL exactly matches migration",()=>assert.equal(applySql,migration));
check("delete is an archive transition, never a campaign row deletion",()=>{
  assert.match(migration,/v_resulting_state\s*:=\s*'ARCHIVED'/);
  assert.doesNotMatch(migration,/DELETE\s+FROM\s+public\.campaigns/i);
});
check("archive requires the exact stored campaign name",()=>assert.match(migration,/p_confirmation_name\s+IS\s+DISTINCT\s+FROM\s+v_campaign\.name/));
check("management is owner/admin scoped in the database",()=>{
  assert.match(migration,/marketroute_is_org_admin\(p_organisation_id\)/);
  assert.match(migration,/GRANT EXECUTE ON FUNCTION public\.marketroute_manage_campaign_v1[\s\S]*TO authenticated/);
  assert.match(migration,/REVOKE ALL ON FUNCTION public\.marketroute_manage_campaign_v1[\s\S]*FROM PUBLIC, anon, service_role/);
});
check("campaign workflow audit is append-only",()=>assert.match(migration,/campaign_workflow_events_append_only[\s\S]*marketroute_reject_mutation/));
check("pause and archive disable new research",()=>assert.match(migration,/v_action IN \('PAUSE','ARCHIVE'\)[\s\S]*UPDATE public\.research_budget_policies[\s\S]*SET enabled = false/));
check("resume restores the policy state captured at pause",()=>{
  assert(migration.includes("researchPolicyWasEnabled"));
  assert.match(migration,/v_action = 'RESUME'[\s\S]*SET enabled = v_policy_was_enabled/);
});
check("research claims require an active campaign and enabled policy",()=>{
  assert.match(migration,/c\.workflow_state = 'ACTIVE'/);
  assert.match(migration,/SELECT p\.enabled[\s\S]*p\.campaign_id = w\.campaign_id/);
});
check("pause/archive fail closed during a running delivery",()=>assert.match(migration,/engagement_delivery_jobs[\s\S]*j\.status = 'RUNNING'[\s\S]*MARKETROUTE_CAMPAIGN_CHANGE_BLOCKED_DURING_DELIVERY/));
check("archived campaigns are excluded from normal command-centre reads",()=>assert.match(migration,/workflow_state <> 'ARCHIVED'/));
check("typed confirmation is exact in the browser and submit is disabled until matched",()=>{
  assert(component.includes("confirmationName !== campaignName"));
  assert(component.includes('name="confirmationName"'));
  assert(component.includes('value="ARCHIVE"'));
});
check("campaign mutation endpoint enforces origin, session and admin role",()=>{
  assert(route.includes("sameOriginOrThrow(request)"));
  assert(route.includes("sessions.authenticate(accessToken)"));
  assert(route.includes("['OWNER', 'ADMIN'].includes(workspace.role)"));
});
check("controls are role-gated and archive success leaves the detail view",()=>{
  assert(detail.includes('workspace.role==="OWNER"||workspace.role==="ADMIN"'));
  assert(route.includes('return redirectWith(request, "/app/campaigns", "campaignAction", "archived")'));
  assert(list.includes('query.campaignAction==="archived"'));
});
check("release creates no commercial-authority writer",()=>{
  assert(migration.includes("'new_authority_writer',false"));
  assert(!authorityWrite.test(migration));
});

let passed=0;
console.log("\nMarketRoute V2 — Campaign lifecycle controls 0.18.3.10");
for(const [name,fn] of checks){
  try{fn();passed++;console.log(`PASS  ${name}`);}
  catch(error){console.error(`FAIL  ${name}: ${error instanceof Error?error.message:error}`);}
}
console.log(`\n${passed}/${checks.length} PASS`);
if(passed!==checks.length)process.exitCode=1;
