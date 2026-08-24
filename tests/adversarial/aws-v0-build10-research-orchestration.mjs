import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const root = path.resolve(import.meta.dirname, "../..");
const executor = await import(pathToFileURL(path.join(root, "infrastructure/aws-v0/runtime/research-worker/executor.mjs")).href);
const migration = fs.readFileSync(path.join(root, "database/aws/0004_marketroute_aws_build10_research_orchestration.sql"), "utf8");
const planning = fs.readFileSync(path.join(root, "application/research/planning-automation.ts"), "utf8");
const dispatcher = fs.readFileSync(path.join(root, "application/research/aws-v0-dispatcher.ts"), "utf8");
const stack = fs.readFileSync(path.join(root, "infrastructure/aws-v0/lib/research-stack.ts"), "utf8");

const evidenceId = "55555555-5555-4555-8555-555555555555";
const dedupeKey = "a".repeat(64);
const envelope = {
  schemaVersion: "1",
  transport: "AWS_SQS",
  workUnitId: "11111111-1111-4111-8111-111111111111",
  enqueuedAt: "2026-08-24T12:00:00.000Z",
  organisationId: "22222222-2222-4222-8222-222222222222",
  campaignId: "33333333-3333-4333-8333-333333333333",
  companyId: "44444444-4444-4444-8444-444444444444",
  researchOrigin: "CUSTOMER_CAMPAIGN",
  dedupeKey,
  workUnit: {
    ordinal: 1,
    gapKey: "semantic:company-understanding",
    layer: "R4",
    tier: "ENRICHMENT",
    action: "SYNTHESIZE_COMPANY_UNDERSTANDING",
    subjectType: "COMPANY",
    subjectId: "44444444-4444-4444-8444-444444444444",
    claimKey: null,
    reasonCode: "COMPANY_UNDERSTANDING_REFRESH",
    queryHints: [],
    costCeilingUsd: 0.1,
    dedupeKey,
    payload: {
      metadata: {
        awsV0SyncContractVersion: "MR-AWS-V0-COMPANY-UNDERSTANDING-SYNC-1.0.0",
        awsV0Executor: {
          contractVersion: "MR-AWS-V0-COMPANY-UNDERSTANDING-1.0.0",
          operation: "ai.companyUnderstanding",
          input: {
            companyName: "Northstar Industrial Controls Ltd",
            requestedTier: "B",
            evidence: [{ evidenceId, sourceType: "WEBSITE", statement: "The company manufactures industrial monitoring components.", observedAt: "2026-08-24T10:00:00.000Z" }],
          },
        },
      },
      authorityEnvelopeFingerprint: "b".repeat(64),
      researchOrigin: "CUSTOMER_CAMPAIGN",
    },
  },
};

const semanticValue = {
  overview: { text: "The company manufactures industrial monitoring components.", evidenceIds: [evidenceId] },
  businessActivities: [], offerings: [], customerTypes: [], operatingSignals: [], uncertainty: "medium", unresolvedQuestions: [],
};

class Ledger {
  constructor({ claimOutcome = "CLAIMED", syncState = "SYNCED", failureState = "FAILED_TERMINAL" } = {}) { this.claimOutcome = claimOutcome; this.syncState = syncState; this.failureState = failureState; this.providerCompleted = 0; this.syncCalls = 0; }
  async claim() { return this.claimOutcome === "DEDUPLICATED" ? { outcome: "DEDUPLICATED", attemptCount: 1, resultFingerprint: "c".repeat(64) } : { outcome: this.claimOutcome, attemptCount: 1 }; }
  async complete() { this.providerCompleted += 1; return "c".repeat(64); }
  async sync() { this.syncCalls += 1; return this.syncState; }
  async fail() { return this.failureState; }
  async syncFailure() { this.syncCalls += 1; return "FAILED_SYNCED"; }
  destroy() {}
}
const provider = { calls: 0, async execute() { this.calls += 1; return { value: semanticValue, telemetry: { provider: "AWS_BEDROCK", modelIdentifier: "anthropic.claude-sonnet-4-5-20250929-v1:0", inferenceProfileIdentifier: "profile", usageUnit: "TOKEN", inputUnits: 100, outputUnits: 50, latencyMs: 1 } }; }, destroy() {} };
const now = () => new Date("2026-08-24T12:00:00.000Z");

const tests = [];
const test = (name, fn) => tests.push([name, fn]);

test("semantic synthesis is a distinct bounded action", () => {
  const input = executor.parseCompanyUnderstandingInput(envelope);
  if (input.evidence[0]?.evidenceId !== evidenceId) throw new Error("canonical evidence identifier rejected");
  if (!migration.includes("'SYNTHESIZE_COMPANY_UNDERSTANDING'::text")) throw new Error("database action constraint missing");
});

test("worker acknowledges only after canonical synchronization", async () => {
  const ledger = new Ledger({ syncState: "SYNCED" });
  const result = await executor.executeResearchEnvelope(envelope, { workerId: "worker-1" }, { ledger, provider, now });
  if (!result.acknowledge || result.syncState !== "SYNCED" || ledger.syncCalls !== 1) throw new Error("synchronized execution was not acknowledged exactly once");
});

test("blocked synchronization keeps the queue message", async () => {
  const ledger = new Ledger({ syncState: "BLOCKED_CAPABILITY" });
  const result = await executor.executeResearchEnvelope(envelope, { workerId: "worker-2" }, { ledger, provider, now });
  if (result.acknowledge || result.outcome !== "SYNC_BLOCKED") throw new Error("blocked sync was acknowledged");
});

test("deduplicated execution still synchronizes before acknowledgment", async () => {
  const ledger = new Ledger({ claimOutcome: "DEDUPLICATED", syncState: "ALREADY_SYNCED" });
  const replayProvider = { ...provider, calls: 0 };
  const result = await executor.executeResearchEnvelope(envelope, { workerId: "worker-3" }, { ledger, provider: replayProvider, now });
  if (!result.acknowledge || replayProvider.calls !== 0 || ledger.syncCalls !== 1) throw new Error("replay bypassed sync or reran provider");
});

test("terminal provider failure settles canonical work before acknowledgment", async () => {
  const ledger = new Ledger();
  const failedProvider = { async execute() { throw new executor.AwsV0ResearchExecutionError("MARKETROUTE_AWS_V0_SYNTHETIC_TERMINAL", false); }, destroy() {} };
  const result = await executor.executeResearchEnvelope(envelope, { workerId: "worker-terminal" }, { ledger, provider: failedProvider, now });
  if (!result.acknowledge || result.outcome !== "FAILED_TERMINAL" || result.syncState !== "FAILED_SYNCED") throw new Error("terminal failure was deleted before canonical failure settlement");
});

test("evidence acquisition cannot masquerade as semantic synthesis", () => {
  if (!migration.includes("v_work.action<>'SYNTHESIZE_COMPANY_UNDERSTANDING'")) throw new Error("dispatch capability gate missing");
  if (!dispatcher.includes('work.action !== "SYNTHESIZE_COMPANY_UNDERSTANDING"')) throw new Error("application dispatcher capability gate missing");
});

test("ambiguous send acknowledgment cannot release sent canonical work", () => {
  if (!migration.includes("IF v_dispatch_state='SENT' THEN RETURN")) throw new Error("sent dispatch can be failed after an ambiguous publisher response");
  if (!migration.includes("sqs_message_id=COALESCE(sqs_message_id")) throw new Error("duplicate transport send is not idempotent");
});

test("synchronizer re-verifies evidence scope and exact content", () => {
  for (const token of ["e.subject_id<>v_work.company_id", "e.tenant_scope_organisation_id<>v_work.organisation_id", "supplied->>'statement' IS DISTINCT FROM e.excerpt_text", "v_cited_ids <@ v_input_ids"]) {
    if (!migration.includes(token)) throw new Error(`evidence re-verification missing: ${token}`);
  }
});

test("semantic artifacts cannot write Truth or authority", () => {
  for (const forbidden of ["INSERT INTO public.truth_claim_snapshots", "INSERT INTO public.authority_records", "INSERT INTO public.commercial_reality_r4_records", "INSERT INTO public.route_authority_r5_records", "INSERT INTO public.contact_authority_r6_records"]) {
    if (migration.includes(forbidden)) throw new Error(`authority write leaked: ${forbidden}`);
  }
  if (!migration.includes("semanticArtifactOnly")) throw new Error("semantic-only settlement metadata missing");
});

test("planning is provider-free and can run with zero workers", () => {
  if (!planning.includes("workersRequired: false") || planning.includes("ResearchProvider") || planning.includes("ResearchWorker")) throw new Error("planning still depends on a worker/provider");
});

test("activation remains physically disabled", () => {
  if (!stack.includes("enabled: false") || !stack.includes("DISABLED_PENDING_PLANNER_AND_QUOTA_PROOF")) throw new Error("event source activation drifted");
});

let passed = 0;
console.log("\nAWS V0 Build 10 — adversarial research orchestration");
for (const [name, fn] of tests) {
  try { await fn(); passed += 1; console.log(`PASS  ${name}`); }
  catch (error) { console.error(`FAIL  ${name}: ${error instanceof Error ? error.message : String(error)}`); }
}
console.log(`\n${passed}/${tests.length} PASS`);
if (passed !== tests.length) process.exitCode = 1;
