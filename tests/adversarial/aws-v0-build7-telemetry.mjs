import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const contract = fs.readFileSync(path.join(root, "core/ai/semantic-telemetry.ts"), "utf8");
const publicContract = fs.readFileSync(path.join(root, "core/ai/semantic-operation.ts"), "utf8");
const executor = fs.readFileSync(path.join(root, "application/ai/execute-semantic-operation.ts"), "utf8");
const telemetryApplication = fs.readFileSync(path.join(root, "application/ai/semantic-telemetry.ts"), "utf8");

for (const forbidden of ["rawPrompt", "rawResponse", "promptText", "responseText", "modelOutput", "secretArn", "resourceArn", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"]) {
  if (contract.includes(forbidden) || executor.includes(forbidden) || telemetryApplication.includes(forbidden)) {
    throw new Error(`Build 7.3 telemetry may capture sensitive provider/content detail: ${forbidden}`);
  }
}

if (/telemetry\s*\?\s*:/.test(executor)) throw new Error("Build 7.3 telemetry sink became optional");
if (/telemetryContext\s*\?\s*:/.test(executor)) throw new Error("Build 7.3 telemetry context became optional");
if (!executor.includes("telemetry: SemanticTelemetrySink;")) throw new Error("Build 7.3 mandatory telemetry sink contract drifted");
if (!executor.includes("telemetryContext: SemanticTelemetryContext;")) throw new Error("Build 7.3 mandatory telemetry context contract drifted");
if (!executor.includes("retryCount: Math.max(0, args.attemptCount - 1)")) throw new Error("Build 7.3 retry economics are not represented");
if (!executor.includes("mergeProviderTelemetry(providerTelemetry, execution.telemetry)")) throw new Error("Build 7.3 successful provider usage is not aggregated");
if (!executor.includes("mergeProviderTelemetry(providerTelemetry, error.telemetry)")) throw new Error("Build 7.3 failed/retried provider usage is not aggregated");
if (!executor.includes('creditFunding: args.context.creditFunding ?? "UNKNOWN"')) throw new Error("Build 7.3 credit accounting must remain unknown unless accounting supplies it");
if (!telemetryApplication.includes('product: "MarketRoute"')) throw new Error("Build 7.3 product attribution drifted");

for (const forbidden of ["providerRequestId", "modelIdentifier", "inferenceProfileIdentifier", "inputUnits", "outputUnits", "estimatedEquivalentCostUsd", "actualAttributedCostUsd", "creditFunding"]) {
  if (publicContract.includes(forbidden)) throw new Error(`Build 7.3 internal economics leaked to public result: ${forbidden}`);
}
for (const forbidden of ["database", "repository", "persist", "insert", "upsert", "updatecanonical", "truth index", "opportunityrank", "routerank", "contactrank"]) {
  if (executor.toLowerCase().includes(forbidden)) throw new Error(`Build 7.3 telemetry acquired forbidden authority: ${forbidden}`);
}

const presentationRoots = ["app", "ui"];
for (const presentationRoot of presentationRoots) {
  const start = path.join(root, presentationRoot);
  if (!fs.existsSync(start)) continue;
  const stack = [start];
  while (stack.length) {
    const dir = stack.pop();
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const file = path.join(dir, entry.name);
      if (entry.isDirectory()) stack.push(file);
      else if (/\.(ts|tsx|js|jsx|mjs|cjs)$/.test(entry.name)) {
        const text = fs.readFileSync(file, "utf8");
        if (text.includes("semantic-telemetry")) throw new Error(`Build 7.3 telemetry leaked to presentation surface: ${path.relative(root, file)}`);
      }
    }
  }
}

console.log("PASS AWS V0 Build 7.3 adversarial telemetry boundary checks");
