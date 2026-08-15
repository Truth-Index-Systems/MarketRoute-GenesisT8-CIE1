import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const root=path.resolve(import.meta.dirname,"..");
const read=(file)=>fs.readFileSync(path.join(root,file),"utf8");
const migration=read("supabase/migrations/0036_campaign_activation_progress_ui.sql");
const applySql=read("APPLY-IN-SUPABASE-MARKETROUTE-V2-0.18.3.16-CAMPAIGN-ACTIVATION-PROGRESS-UI.sql");
const bootstrap=read("application/production/bootstrap.ts");
const repository=read("platform/database/production-activation-repository.ts");
const session=read("application/session/service.ts");
const progress=read("ui/application/campaign-activation-progress.tsx");
const form=read("ui/application/campaign-creation-form.tsx");
const campaigns=read("app/app/campaigns/page.tsx");
const commandCentre=read("app/app/page.tsx");
const authorityWrite=/INSERT\s+INTO\s+public\.(?:commercial_reality_r4_records|route_authority_r5_records|contact_authority_r6_records|authority_records)/i;
const checks=[];
const check=(name,fn)=>checks.push([name,fn]);

check("deployable SQL exactly matches migration",()=>assert.equal(applySql,migration));
check("activation progress is durable structured workspace state",()=>{
  assert.match(migration,/ADD COLUMN IF NOT EXISTS activation_stage text NOT NULL DEFAULT 'QUEUED'/);
  assert.match(migration,/ADD COLUMN IF NOT EXISTS activation_progress integer NOT NULL DEFAULT 5/);
  assert.match(migration,/activation_stage_detail_json jsonb NOT NULL DEFAULT '\{\}'::jsonb/);
  assert.match(migration,/workspace_activation_stage_detail_object/);
});
check("job status transitions automatically initialise durable UI stages",()=>{
  assert.match(migration,/workspace_activation_status_transition_v1/);
  for(const status of ["PENDING","RUNNING","SUCCEEDED","FAILED","NEEDS_INPUT"])assert(migration.includes(`WHEN '${status}'`));
  assert.match(migration,/CREATE TRIGGER workspace_activation_status_transition/);
});
check("only the active lease owner can publish intermediate stages",()=>{
  assert.match(migration,/marketroute_set_workspace_activation_stage_v1/);
  assert.match(migration,/status = 'RUNNING'[\s\S]*worker_id = p_worker_id[\s\S]*lease_expires_at > p_at/);
  assert.match(migration,/GRANT EXECUTE ON FUNCTION public\.marketroute_set_workspace_activation_stage_v1[\s\S]*TO service_role/);
  assert.match(migration,/REVOKE ALL ON FUNCTION public\.marketroute_set_workspace_activation_stage_v1[\s\S]*FROM PUBLIC, anon, authenticated/);
});
check("authenticated workspace members receive progress without table access",()=>{
  assert.match(migration,/marketroute_workspace_activation_status_v2/);
  assert.match(migration,/marketroute_is_org_member\(p_organisation_id\)/);
  assert.match(migration,/'stage',v_job\.activation_stage/);
  assert.match(migration,/'progress',v_job\.activation_progress/);
  assert.match(migration,/GRANT EXECUTE ON FUNCTION public\.marketroute_workspace_activation_status_v2[\s\S]*TO authenticated/);
  assert.match(session,/marketroute_workspace_activation_status_v2/);
});
check("bootstrap records every visible preparation boundary",()=>{
  for(const stage of ["SELLER_CONTEXT_READY","CREATING_CAMPAIGN","CAMPAIGN_CREATED","SELECTING_TARGETS","DISCOVERING_TARGETS","LINKING_COMPANIES","FINALISING"])assert(bootstrap.includes(`"${stage}"`));
  assert.match(repository,/marketroute_set_workspace_activation_stage_v1/);
  assert.match(bootstrap,/linkedCount:index\+1/);
});
check("progress UI refreshes from persisted state and survives navigation",()=>{
  assert(progress.startsWith('"use client"'));
  assert.match(progress,/router\.refresh\(\)/);
  assert.match(progress,/setInterval/);
  assert.match(progress,/This continues if you leave this page/);
  assert(campaigns.includes("CampaignActivationProgress"));
  assert(commandCentre.includes("CampaignActivationProgress"));
  assert(!/campaignAction==="processing"[^\n]*CampaignActivationProgress/.test(campaigns));
});
check("unsubmitted campaign brief is restored from local storage",()=>{
  assert(form.startsWith('"use client"'));
  assert(form.includes("marketroute:new-campaign-draft:v1"));
  assert.match(form,/localStorage\.getItem\(draftKey\)/);
  assert.match(form,/localStorage\.setItem\(draftKey/);
  assert(progress.includes('localStorage.removeItem("marketroute:new-campaign-draft:v1")'));
});
check("release adds no authority writer and preserves archive semantics",()=>{
  assert(migration.includes("'new_authority_writer',false"));
  assert(migration.includes("'archived_lineage_unchanged',true"));
  assert(!authorityWrite.test(migration));
  assert(!/DELETE\s+FROM\s+public\.campaigns/i.test(migration));
});

let passed=0;
console.log("\nMarketRoute V2 — Persistent campaign activation progress UI 0.18.3.16");
for(const [name,fn] of checks){try{fn();passed++;console.log(`PASS  ${name}`);}catch(error){console.error(`FAIL  ${name}: ${error instanceof Error?error.message:error}`);}}
console.log(`\n${passed}/${checks.length} PASS`);
if(passed!==checks.length)process.exitCode=1;
