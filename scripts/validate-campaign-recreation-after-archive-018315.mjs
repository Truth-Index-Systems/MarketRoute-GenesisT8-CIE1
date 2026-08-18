import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const root=path.resolve(import.meta.dirname,"..");
const read=(file)=>fs.readFileSync(path.join(root,file),"utf8");
const migration=read("supabase/migrations/0035_campaign_recreation_after_archive.sql");
const applySql=read("APPLY-IN-SUPABASE-MARKETROUTE-V2-0.18.3.15-CAMPAIGN-RECREATION-AFTER-ARCHIVE.sql");
const repository=read("platform/database/production-activation-repository.ts");
const bootstrap=read("application/production/bootstrap.ts");
const session=read("application/session/service.ts");
const route=read("app/api/campaigns/route.ts");
const page=read("app/app/campaigns/new/page.tsx");
const list=read("app/app/campaigns/page.tsx");
const commandCentre=read("app/app/page.tsx");
const successor=read("supabase/migrations/0053_multi_campaign_plan_governance.sql");
const authorityWrite=/INSERT\s+INTO\s+public\.(?:commercial_reality_r4_records|route_authority_r5_records|contact_authority_r6_records|authority_records)/i;
const checks=[];
const check=(name,fn)=>checks.push([name,fn]);

check("deployable SQL exactly matches migration",()=>assert.equal(applySql,migration));
check("replacement submission is authenticated and admin scoped",()=>{
  assert.match(migration,/v_user\s+uuid\s*:=\s*auth\.uid\(\)/);
  assert.match(migration,/marketroute_is_org_admin\(p_organisation_id\)/);
  assert.match(migration,/GRANT EXECUTE ON FUNCTION public\.marketroute_submit_replacement_campaign_v1[\s\S]*TO authenticated/);
  assert.match(migration,/REVOKE ALL ON FUNCTION public\.marketroute_submit_replacement_campaign_v1[\s\S]*FROM PUBLIC, anon, service_role/);
});
check("a new campaign is allowed only after every prior campaign is archived",()=>{
  assert.match(migration,/workflow_state <> 'ARCHIVED'[\s\S]*MARKETROUTE_LIVE_CAMPAIGN_ALREADY_EXISTS/);
  assert(!/workflow_state\s*=\s*'ACTIVE'\s+WHERE[\s\S]*workflow_state\s*=\s*'ARCHIVED'/i.test(migration));
  assert(!/DELETE\s+FROM\s+public\.campaigns/i.test(migration));
});
check("replacement submission cannot overwrite a live activation lease",()=>assert.match(migration,/v_existing_status = 'RUNNING'[\s\S]*MARKETROUTE_CAMPAIGN_CREATION_ALREADY_PROCESSING/));
check("campaign names survive the activation queue and worker boundary",()=>{
  assert.match(migration,/ADD COLUMN IF NOT EXISTS campaign_name text/);
  assert.match(migration,/marketroute_claim_workspace_activation_v3/);
  assert.match(repository,/campaign_name:string\|null/);
  assert.match(repository,/marketroute_claim_workspace_activation_v3/);
  assert.match(repository,/marketroute_create_activation_campaign_v(?:2|3)/);
  assert.match(successor,/marketroute_create_activation_campaign_v3/);
  assert.match(bootstrap,/job\.campaign_name/);
});
check("migration-first rollout keeps V1 campaign creation compatible",()=>{
  assert.match(migration,/CREATE OR REPLACE FUNCTION public\.marketroute_create_activation_campaign_v1/);
  assert.match(migration,/COALESCE\(nullif\(btrim\(j\.campaign_name\), ''\), 'Initial market research'\)/);
  assert.match(migration,/migration_first_rollout_compatible',true/);
});
check("application validates the brief and calls only the guarded RPC",()=>{
  assert.match(session,/submitReplacementCampaign/);
  assert.match(session,/marketroute_submit_(?:replacement_campaign_v1|campaign_v2)/);
  assert.match(successor,/marketroute_submit_campaign_v2/);
  assert.match(session,/MARKETROUTE_CAMPAIGN_NAME_REQUIRED/);
});
check("creation endpoint enforces origin, authenticated workspace and admin role",()=>{
  assert(route.includes("sameOriginOrThrow(request)"));
  assert(route.includes("sessions.authenticate(accessToken)"));
  assert(route.includes('["OWNER","ADMIN"].includes(workspace.role)'));
  assert(route.includes("submitReplacementCampaign"));
});
check("successor UI always exposes configured Add campaign without bypassing the brief",()=>{
  assert(!page.includes("asObjectArray(model.campaigns).length>0"));
  assert(page.includes("Every campaign starts here"));
  assert(list.includes('href="/app/campaigns/new"'));
  assert(list.includes("Add campaign"));
  assert(commandCentre.includes('href="/app/campaigns/new"'));
  assert(successor.includes("campaign_configuration_required',true"));
});
check("release preserves archived lineage and creates no authority writer",()=>{
  assert(migration.includes("'archived_campaigns_restored',false"));
  assert(migration.includes("'archived_campaigns_deleted',false"));
  assert(migration.includes("'new_authority_writer',false"));
  assert(!authorityWrite.test(migration));
});

let passed=0;
console.log("\nMarketRoute V2 — Campaign recreation after archive 0.18.3.15");
for(const [name,fn] of checks){
  try{fn();passed++;console.log(`PASS  ${name}`);}
  catch(error){console.error(`FAIL  ${name}: ${error instanceof Error?error.message:error}`);}
}
console.log(`\n${passed}/${checks.length} PASS`);
if(passed!==checks.length)process.exitCode=1;
