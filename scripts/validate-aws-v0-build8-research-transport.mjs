import fs from "node:fs";

const contract = fs.readFileSync("core/research/aws-v0-transport.ts", "utf8");
const stack = fs.readFileSync("infrastructure/aws-v0/lib/research-stack.ts", "utf8");
const runtime = fs.readFileSync("infrastructure/aws-v0/runtime/research-worker/index.mjs", "utf8");
const app = fs.readFileSync("infrastructure/aws-v0/bin/aws-v0.ts", "utf8");
const packageJson = fs.readFileSync("infrastructure/aws-v0/package.json", "utf8");
const constitution = fs.readFileSync(".github/workflows/constitution.yml", "utf8");
const infrastructureWorkflow = fs.readFileSync(".github/workflows/aws-v0-infrastructure.yml", "utf8");

for (const token of [
  'AWS_V0_RESEARCH_TRANSPORT_SCHEMA_VERSION = "1"',
  "AWS_V0_RESEARCH_MAX_MESSAGE_BYTES = 65_536",
  "AWS_V0_RESEARCH_MAX_BATCH_SIZE = 1",
  "AWS_V0_RESEARCH_MAX_CONCURRENT_WORK_UNITS = 2",
  "AWS_V0_RESEARCH_WORKER_TIMEOUT_SECONDS = 240",
  "AWS_V0_RESEARCH_VISIBILITY_TIMEOUT_SECONDS = 1_440",
  "AWS_V0_RESEARCH_DLQ_MAX_RECEIVE_COUNT = 5",
  "parseAwsV0ResearchWorkEnvelope",
  "serialiseAwsV0ResearchWorkEnvelope",
  "workUnit.dedupeKey !== dedupeKey",
]) {
  if (!contract.includes(token)) throw new Error(`Build 8 transport contract missing: ${token}`);
}

for (const token of [
  'queueName: "marketroute-aws-v0-research-work"',
  'queueName: "marketroute-aws-v0-research-dlq"',
  "QueueEncryption.SQS_MANAGED",
  "enforceSSL: true",
  "Duration.seconds(VISIBILITY_TIMEOUT_SECONDS)",
  "maxReceiveCount: MAX_RECEIVE_COUNT",
  "Runtime.NODEJS_22_X",
  "Architecture.ARM_64",
  "timeout: Duration.seconds(WORKER_TIMEOUT_SECONDS)",
  "memorySize: 512",
  'MARKETROUTE_AWS_RESEARCH_EXECUTOR_ENABLED: "false"',
  "batchSize: BATCH_SIZE",
  "enabled: false",
  "reportBatchItemFailures: true",
  "maxConcurrency: MAX_CONCURRENCY",
]) {
  if (!stack.includes(token)) throw new Error(`Build 8 research stack missing: ${token}`);
}

if (!app.includes('new MrAwsV0ResearchStack(app, "MrAwsV0ResearchStack"')) throw new Error("Build 8 research stack is not active in CDK app");
if (app.includes('new FoundationStack(app, "MrAwsV0ResearchStack"')) throw new Error("Build 8 research boundary is still a placeholder");

for (const token of ["batchItemFailures", "Buffer.byteLength", 'TRANSPORT_SCHEMA_VERSION = "1"', 'TRANSPORT_NAME = "AWS_SQS"']) {
  if (!runtime.includes(token)) throw new Error(`Build 8 worker runtime missing: ${token}`);
}
for (const forbidden of ["fetch(", "http.request", "https.request", "@aws-sdk", "rds-data", "bedrock", "openai", "secretsmanager", "dynamodb", "process.env.AWS_ACCESS_KEY_ID", "process.env.AWS_SECRET_ACCESS_KEY"]) {
  if (runtime.toLowerCase().includes(forbidden.toLowerCase())) throw new Error(`Build 8 worker acquired forbidden capability: ${forbidden}`);
}

if (!packageJson.includes("validate-build8-research-synth.mjs")) throw new Error("Build 8 synthesized research gate is not wired into IaC validation");
for (const workflow of [constitution, infrastructureWorkflow]) {
  if (!workflow.includes("validate-aws-v0-build8-research-transport.mjs")) throw new Error("Build 8 source validator missing from CI");
  if (!workflow.includes("aws-v0-build8-research-transport.mjs")) throw new Error("Build 8 adversarial validator missing from CI");
}

console.log("PASS AWS V0 Build 8 research transport source boundary");
