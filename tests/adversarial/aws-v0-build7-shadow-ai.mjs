import fs from "node:fs";

const route = fs.readFileSync("app/api/aws-v0/shadow/ai/route.ts", "utf8");
const application = fs.readFileSync("application/aws-v0/shadow-ai-semantic-probe.ts", "utf8");
const runtime = fs.readFileSync("application/aws-v0/shadow-ai-runtime.ts", "utf8");
const provider = fs.readFileSync("platform/ai/bedrock/bedrock-semantic-provider.ts", "utf8");
const definition = fs.readFileSync("core/ai/semantic-probe-definition.ts", "utf8");

for (const forbidden of [
  "process.env",
  "AWS_ACCESS_KEY_ID",
  "AWS_SECRET_ACCESS_KEY",
  "credentials:",
  "@aws-sdk/client-bedrock-runtime",
  "BedrockSemanticProvider",
  "inferenceProfileArn",
  "providerRequestId",
  "modelIdentifier",
  "rawPrompt",
  "rawResponse",
  "request.json",
  "request.text",
]) {
  if (route.includes(forbidden)) throw new Error(`Build 7.5 route boundary leak: ${forbidden}`);
}
for (const forbidden of [
  "platform/database",
  "aws-data-api",
  "insert",
  "upsert",
  "updatecanonical",
  "TruthIndex",
  "opportunityRank",
  "routeRank",
  "contactRank",
]) {
  if (application.includes(forbidden)) throw new Error(`Build 7.5 application probe acquired forbidden authority: ${forbidden}`);
}
for (const forbidden of ["ConverseStreamCommand", "InvokeModelCommand", "InvokeModelWithResponseStreamCommand", "console.log", "console.error", "rawPrompt", "rawResponse"]) {
  if (provider.includes(forbidden)) throw new Error(`Build 7.5 provider unsafe capability/logging: ${forbidden}`);
}
if (!provider.includes("this.client.send(command, { abortSignal: signal })")) throw new Error("Build 7.5 provider does not pass abort signal to Bedrock");
if (!provider.includes("parseSemanticProbeOutput(JSON.parse(text))")) throw new Error("Build 7.5 response is not locally schema validated after Bedrock validation");
if (!definition.includes("Do not perform Truth Index, CIE, UDOSIB, or deterministic commercial mathematics.")) throw new Error("Build 7.5 semantic authority instruction drifted");
if (!runtime.includes('import "server-only"')) throw new Error("Build 7.5 environment profile reader is not server-only");
if (!application.includes('import "server-only"')) throw new Error("Build 7.5 application probe is not server-only");
if (!application.includes("InMemorySemanticProbeTelemetrySink")) throw new Error("Build 7.5 must not persist probe telemetry yet");
if (!application.includes("SONNET45_EU_GEO_INPUT_USD_PER_MILLION_TOKENS = 3.3") || !application.includes("SONNET45_EU_GEO_OUTPUT_USD_PER_MILLION_TOKENS = 16.5")) {
  throw new Error("Build 7.5 EU equivalent-cost basis drifted");
}
if (!route.includes('return NextResponse.json({ error: "not_found" }, { status: 404, headers: noStoreHeaders })')) throw new Error("Build 7.5 must disappear outside shadow mode");
if (!route.includes("productionCutover: false") || !route.includes("genesisEnabled: false")) throw new Error("Build 7.5 hard latches missing");

console.log("PASS AWS V0 Build 7.5 adversarial private semantic probe checks");
