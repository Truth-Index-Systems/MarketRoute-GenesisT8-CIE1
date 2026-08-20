import fs from "node:fs";

const route = fs.readFileSync("app/api/aws-v0/shadow/ai/route.ts", "utf8");
const application = fs.readFileSync("application/aws-v0/shadow-ai-semantic-probe.ts", "utf8");
const runtime = fs.readFileSync("application/aws-v0/shadow-ai-runtime.ts", "utf8");
const provider = fs.readFileSync("platform/ai/bedrock/bedrock-semantic-provider.ts", "utf8");
const definition = fs.readFileSync("core/ai/semantic-probe-definition.ts", "utf8");
const workflow = fs.readFileSync(".github/workflows/constitution.yml", "utf8");

for (const token of [
  'export const runtime = "nodejs"',
  'export const dynamic = "force-dynamic"',
  'isAwsV0ShadowModeEnabled()',
  'runAwsV0SyntheticSemanticProbe()',
  '"cache-control": "no-store"',
  'operation: "ai.semanticProbe"',
  'structuredOutput: true',
  'productionCutover: false',
  'genesisEnabled: false',
]) {
  if (!route.includes(token)) throw new Error(`Build 7.5 shadow route missing: ${token}`);
}
for (const token of [
  'subject: "Northstar Industrial Controls Ltd (synthetic)"',
  'requestedTier: "B"',
  'executeSemanticOperation("ai.semanticProbe", SYNTHETIC_PROBE_INPUT',
  'timeoutMs: 60_000',
  'maxAttempts: 2',
  'creditFunding: "UNKNOWN"',
  'actualAttributedCostUsd: null',
]) {
  if (!application.includes(token)) throw new Error(`Build 7.5 controlled application probe missing: ${token}`);
}
if (!runtime.includes("MARKETROUTE_AWS_BEDROCK_INFERENCE_PROFILE_ARN")) throw new Error("Build 7.5 server-only Bedrock profile lookup missing");
for (const token of ["ConverseCommand", "outputConfig", 'type: "json_schema"', "SEMANTIC_PROBE_JSON_SCHEMA", "parseStructuredText", "response.usage?.inputTokens", "response.usage?.outputTokens"]) {
  if (!provider.includes(token)) throw new Error(`Build 7.5 Bedrock provider missing: ${token}`);
}
for (const token of ["additionalProperties: false", "parseSemanticProbeOutput", "SEMANTIC_PROBE_SYSTEM_INSTRUCTION"]) {
  if (!definition.includes(token)) throw new Error(`Build 7.5 semantic schema/validator missing: ${token}`);
}
for (const forbidden of ["request.json", "request.text", "NextRequest", "process.env", "@aws-sdk", "platform/ai", "MARKETROUTE_AWS_BEDROCK_INFERENCE_PROFILE_ARN", "providerRequestId", "modelIdentifier", "inferenceProfileIdentifier"]) {
  if (route.includes(forbidden)) throw new Error(`Build 7.5 route exposes or accepts forbidden detail: ${forbidden}`);
}
if (!workflow.includes("node scripts/validate-aws-v0-build7-shadow-ai.mjs")) throw new Error("Build 7.5 validator missing from constitutional CI");
if (!workflow.includes("node tests/adversarial/aws-v0-build7-shadow-ai.mjs")) throw new Error("Build 7.5 adversarial gate missing from constitutional CI");

console.log("PASS AWS V0 Build 7.5 private structured semantic probe route");
