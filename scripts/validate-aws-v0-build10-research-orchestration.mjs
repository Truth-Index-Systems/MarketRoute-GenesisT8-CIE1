import fs from "node:fs";

const read = (file) => fs.readFileSync(file, "utf8");
const migration = read("database/aws/0004_marketroute_aws_build10_research_orchestration.sql");
const contracts = read("core/research/contracts.ts");
const transport = read("core/research/aws-v0-transport.ts");
const planning = read("application/research/planning-automation.ts");
const dispatcher = read("application/research/aws-v0-dispatcher.ts");
const executor = read("infrastructure/aws-v0/runtime/research-worker/executor.mjs");
const stack = read("infrastructure/aws-v0/lib/research-stack.ts");
const build = read("infrastructure/aws-v0/BUILD10-RESEARCH-ORCHESTRATION.md");
const constitution = read(".github/workflows/constitution.yml");
const infrastructureWorkflow = read(".github/workflows/aws-v0-infrastructure.yml");

for (const token of [
  "SYNTHESIZE_COMPANY_UNDERSTANDING",
  "marketroute_aws_v0_research_dispatches",
  "marketroute_aws_v0_company_understanding_artifacts",
  "MR-AWS-V0-RESEARCH-DISPATCH-1.0.0",
  "MR-AWS-V0-COMPANY-UNDERSTANDING-SYNC-1.0.0",
  "marketroute_prepare_aws_v0_research_dispatch_v1",
  "marketroute_mark_aws_v0_research_dispatch_sent_v1",
  "marketroute_fail_aws_v0_research_dispatch_v1",
  "marketroute_claim_aws_v0_research_execution_v2",
  "marketroute_sync_aws_v0_research_execution_v1",
  "marketroute_sync_aws_v0_research_failure_v1",
  "ownership_expires_at>p_at",
  "IF v_dispatch_state='SENT' THEN RETURN",
  "semanticArtifactOnly",
  "marketroute_complete_research_work_v1",
]) if (!migration.includes(token)) throw new Error(`Build 10 migration invariant missing: ${token}`);

for (const token of [
  "e.tenant_scope_organisation_id IS NOT NULL",
  "e.subject_id<>v_work.company_id",
  "supplied->>'statement' IS DISTINCT FROM e.excerpt_text",
  "v_cited_ids <@ v_input_ids",
  "truthAuthorityGranted",
  "deterministicCommercialAuthorityGranted",
]) if (!migration.includes(token)) throw new Error(`Build 10 evidence/authority guard missing: ${token}`);

for (const forbidden of [
  "INSERT INTO public.truth_claim_snapshots",
  "INSERT INTO public.authority_records",
  "INSERT INTO public.commercial_reality_r4_records",
  "INSERT INTO public.route_authority_r5_records",
  "INSERT INTO public.contact_authority_r6_records",
  "INSERT INTO public.opportunities",
]) if (migration.includes(forbidden)) throw new Error(`Build 10 sync crossed authority boundary: ${forbidden}`);

if (!contracts.includes('"SYNTHESIZE_COMPANY_UNDERSTANDING"') || !transport.includes('"SYNTHESIZE_COMPANY_UNDERSTANDING"')) {
  throw new Error("Build 10 synthesis action is not end-to-end in the frozen contract");
}
for (const token of ["workersRequired: false", "ResearchPlanningAutomationService"]) if (!planning.includes(token)) throw new Error(`Build 10 independent planner missing: ${token}`);
for (const token of ["AwsV0ResearchDispatcher", "prepareAwsV0Dispatch", "publisher.publish", "markAwsV0DispatchSent", "MARKETROUTE_AWS_V0_DISPATCH_CAPABILITY_UNSUPPORTED"]) if (!dispatcher.includes(token)) throw new Error(`Build 10 dispatcher missing: ${token}`);
for (const token of ["marketroute_claim_aws_v0_research_execution_v2", "marketroute_sync_aws_v0_research_execution_v1", "marketroute_sync_aws_v0_research_failure_v1", '"SYNC_BLOCKED"', 'acknowledge: syncState === "SYNCED" || syncState === "ALREADY_SYNCED"']) if (!executor.includes(token)) throw new Error(`Build 10 worker/sync handshake missing: ${token}`);

if (!stack.includes("enabled: false") || !stack.includes("DISABLED_PENDING_PLANNER_AND_QUOTA_PROOF")) throw new Error("Build 10 event source activated or activation reason missing");
if (!build.includes("Evidence acquisition is not silently reclassified") && !build.includes("does not acquire new evidence")) throw new Error("Build 10 capability correction undocumented");
for (const workflow of [constitution, infrastructureWorkflow]) {
  if (!workflow.includes("validate-aws-v0-build10-research-orchestration.mjs")) throw new Error("Build 10 source validator missing from CI");
  if (!workflow.includes("aws-v0-build10-research-orchestration.mjs")) throw new Error("Build 10 adversarial validator missing from CI");
}
if (!infrastructureWorkflow.includes("npm run deploy:database") || infrastructureWorkflow.includes("npm run deploy:research")) throw new Error("Build 10 changed automatic deploy away from database-only");

console.log("PASS AWS V0 Build 10 research orchestration source boundary");
