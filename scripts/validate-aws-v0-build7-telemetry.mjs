import fs from "node:fs";

const read = (file) => fs.readFileSync(file, "utf8");
const telemetryContract = read("core/ai/semantic-telemetry.ts");
const telemetryApplication = read("application/ai/semantic-telemetry.ts");
const executor = read("application/ai/execute-semantic-operation.ts");
const provider = read("platform/ai/semantic-provider.ts");
const publicContract = read("core/ai/semantic-operation.ts");
const workflow = read(".github/workflows/constitution.yml");

const requiredTelemetryFields = [
  "operationId",
  "invocationTimestamp",
  "modelIdentifier",
  "inferenceProfileIdentifier",
  "providerRequestId",
  "inputUnits",
  "outputUnits",
  "attemptCount",
  "retryCount",
  "escalationTier",
  "success",
  "latencyMs",
  "estimatedEquivalentCostUsd",
  "actualAttributedCostUsd",
  "creditFunding",
  "attribution",
];

for (const field of requiredTelemetryFields) {
  if (!telemetryContract.includes(field)) throw new Error(`Build 7.3 telemetry field missing: ${field}`);
}
if (!telemetryContract.includes('product: "MarketRoute"')) throw new Error("Build 7.3 product attribution is not frozen to MarketRoute");
if (!telemetryApplication.includes("export interface SemanticTelemetrySink")) throw new Error("Build 7.3 telemetry sink contract missing");
if (!executor.includes("telemetry: SemanticTelemetrySink;")) throw new Error("Build 7.3 telemetry sink must be mandatory");
if (!executor.includes("telemetryContext: SemanticTelemetryContext;")) throw new Error("Build 7.3 telemetry context must be mandatory");
if (!executor.includes("await sink.record(event)")) throw new Error("Build 7.3 executor does not record telemetry");
if (!executor.includes('code: "TELEMETRY_UNAVAILABLE"')) throw new Error("Build 7.3 telemetry failure is not fail-closed");
if (!provider.includes("SemanticProviderTelemetryMetadata")) throw new Error("Build 7.3 provider usage metadata contract missing");
if (!publicContract.includes('"TELEMETRY_UNAVAILABLE"')) throw new Error("Build 7.3 public sanitised telemetry failure code missing");

for (const forbidden of ["rawPrompt", "rawResponse", "promptText", "responseText", "modelOutput", "providerRequestId", "modelIdentifier", "inferenceProfileIdentifier", "inputUnits", "outputUnits", "actualAttributedCostUsd"]) {
  if (publicContract.includes(forbidden)) throw new Error(`Build 7.3 provider/economic detail leaked into public semantic contract: ${forbidden}`);
}
for (const forbidden of ["platform/database", "insert into", "update ", "delete from", "execute-statement", "console.log(event", "JSON.stringify(event)"]) {
  if (telemetryApplication.toLowerCase().includes(forbidden.toLowerCase()) || executor.toLowerCase().includes(forbidden.toLowerCase())) {
    throw new Error(`Build 7.3 telemetry boundary contains forbidden persistence/logging token: ${forbidden}`);
  }
}
if (!workflow.includes("node scripts/validate-aws-v0-build7-telemetry.mjs")) throw new Error("Build 7.3 telemetry validator is not in CI");
if (!workflow.includes("node tests/adversarial/aws-v0-build7-telemetry.mjs")) throw new Error("Build 7.3 telemetry adversarial gate is not in CI");

console.log("PASS AWS V0 Build 7.3 semantic economic telemetry contract");
