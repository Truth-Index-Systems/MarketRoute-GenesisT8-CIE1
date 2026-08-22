import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const root = path.resolve(import.meta.dirname, "../..");
const runtimePath = path.join(root, "infrastructure/aws-v0/runtime/research-worker/index.mjs");
const stack = fs.readFileSync(path.join(root, "infrastructure/aws-v0/lib/research-stack.ts"), "utf8");
const runtime = fs.readFileSync(runtimePath, "utf8");
const { handler } = await import(pathToFileURL(runtimePath).href);

const validEnvelope = {
  schemaVersion: "1",
  transport: "AWS_SQS",
  workUnitId: "build8-work-unit-1",
  enqueuedAt: "2026-08-22T16:00:00.000Z",
  organisationId: "org-1",
  campaignId: "campaign-1",
  companyId: "company-1",
  researchOrigin: "CUSTOMER_CAMPAIGN",
  dedupeKey: "research:company-1:r4",
  workUnit: {
    ordinal: 0,
    gapKey: "r4:company-1",
    layer: "R4",
    tier: "DECISION_BLOCKER",
    action: "ACQUIRE_CLAIM_EVIDENCE",
    subjectType: "COMPANY",
    subjectId: "company-1",
    claimKey: "company.description",
    reasonCode: "CURRENT_R4_REQUIRED",
    queryHints: ["company website"],
    costCeilingUsd: 0.1,
    dedupeKey: "research:company-1:r4",
    payload: { synthetic: true },
  },
};

function sqsEvent(messageId, body) {
  return { Records: [{ messageId, body }] };
}

const originalExecutorState = process.env.MARKETROUTE_AWS_RESEARCH_EXECUTOR_ENABLED;
try {
  process.env.MARKETROUTE_AWS_RESEARCH_EXECUTOR_ENABLED = "false";
  const validResult = await handler(sqsEvent("valid-1", JSON.stringify(validEnvelope)));
  if (JSON.stringify(validResult) !== JSON.stringify({ batchItemFailures: [{ itemIdentifier: "valid-1" }] })) {
    throw new Error("Build 8 valid research work was acknowledged before executor activation");
  }

  const malformedResult = await handler(sqsEvent("bad-json", "{"));
  if (malformedResult.batchItemFailures?.[0]?.itemIdentifier !== "bad-json") throw new Error("Build 8 malformed work did not fail independently");

  const oversizedResult = await handler(sqsEvent("oversized", "x".repeat(65_537)));
  if (oversizedResult.batchItemFailures?.[0]?.itemIdentifier !== "oversized") throw new Error("Build 8 oversized work did not fail closed");

  process.env.MARKETROUTE_AWS_RESEARCH_EXECUTOR_ENABLED = "true";
  const tamperedResult = await handler(sqsEvent("tampered", JSON.stringify(validEnvelope)));
  if (tamperedResult.batchItemFailures?.[0]?.itemIdentifier !== "tampered") throw new Error("Build 8 runtime acknowledged work after executor-latch tampering");
} finally {
  if (originalExecutorState === undefined) delete process.env.MARKETROUTE_AWS_RESEARCH_EXECUTOR_ENABLED;
  else process.env.MARKETROUTE_AWS_RESEARCH_EXECUTOR_ENABLED = originalExecutorState;
}

for (const forbidden of ["fetch(", "@aws-sdk", "rds-data", "bedrock", "openai", "secretsmanager", "dynamodb", "insert into", "update ", "delete from"]) {
  if (runtime.toLowerCase().includes(forbidden.toLowerCase())) throw new Error(`Build 8 worker runtime authority leak: ${forbidden}`);
}
for (const required of ["enabled: false", "batchSize: BATCH_SIZE", "reportBatchItemFailures: true", "maxConcurrency: MAX_CONCURRENCY", "maxReceiveCount: MAX_RECEIVE_COUNT"]) {
  if (!stack.includes(required)) throw new Error(`Build 8 bounded transport control missing: ${required}`);
}
for (const forbidden of ["grantSendMessages", "sqs:SendMessage", "bedrock:", "rds-data:", "secretsmanager:", "iam:PassRole", "FunctionUrl", "HttpApi", "RestApi"]) {
  if (stack.includes(forbidden)) throw new Error(`Build 8 stack gained forbidden producer/runtime authority: ${forbidden}`);
}

console.log("PASS AWS V0 Build 8 adversarial research transport checks");
