import fs from "node:fs";
import path from "node:path";

const root = path.resolve(import.meta.dirname, "..");
const required = [
  "core/ai/semantic-operation.ts",
  "application/ai/execute-semantic-operation.ts",
  "platform/ai/semantic-provider.ts",
  "platform/ai/bedrock/bedrock-runtime.ts",
  "platform/ai/bedrock/bedrock-semantic-provider.ts",
];

const failures = [];
const check = (name, fn) => {
  try { fn(); console.log(`PASS  ${name}`); }
  catch (error) { failures.push(name); console.error(`FAIL  ${name}: ${error instanceof Error ? error.message : String(error)}`); }
};
const assert = (value, message) => { if (!value) throw new Error(message); };
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");

console.log("\nAWS V0 Build 7.1/7.2 — AI boundary static gate");
for (const file of required) check(`required file: ${file}`, () => assert(fs.existsSync(path.join(root, file)), "missing"));

const contract = read("core/ai/semantic-operation.ts");
const application = read("application/ai/execute-semantic-operation.ts");
const provider = read("platform/ai/semantic-provider.ts");
const bedrockRuntime = read("platform/ai/bedrock/bedrock-runtime.ts");
const bedrockProvider = read("platform/ai/bedrock/bedrock-semantic-provider.ts");

check("named operation is frozen", () => assert(contract.includes('"ai.semanticProbe"'), "semantic probe missing"));
check("typed structured semantic result exists", () => assert(contract.includes("SemanticProbeOutput") && contract.includes("SemanticOperationResult"), "typed result missing"));
check("application API is provider-neutral", () => assert(application.includes("executeSemanticOperation") && application.includes("SemanticProvider"), "boundary missing"));
check("retry policy is explicit", () => assert(application.includes("maxAttempts: 2") && application.includes("retryDelayMs: 150"), "retry policy missing"));
check("timeout policy is explicit and enforced", () => assert(application.includes("timeoutMs: 8_000") && application.includes("Promise.race") && application.includes("AbortController"), "timeout enforcement missing"));
check("public errors are sanitised", () => assert(application.includes("Semantic operation could not be completed.") && !application.includes("error.message") && !application.includes("error.stack"), "raw provider error may leak"));
check("provider contract is isolated", () => assert(provider.includes("export interface SemanticProvider"), "provider port missing"));
check("Bedrock SDK is confined to AWS platform adapter", () => assert(bedrockRuntime.includes('@aws-sdk/client-bedrock-runtime'), "SDK import missing"));
check("Bedrock adapter is fail closed before live stage", () => assert(bedrockProvider.includes('SemanticProviderError("NOT_LIVE", false)') && !bedrockProvider.includes(".send("), "adapter can invoke live provider"));
check("no canonical persistence exists in new AI boundary", () => {
  const combined = [contract, application, provider, bedrockRuntime, bedrockProvider].join("\n").toLowerCase();
  for (const forbidden of ["platform/database", "insert into", "update ", "delete from", "execute-statement", "rds-data"]) {
    assert(!combined.includes(forbidden), `forbidden persistence token: ${forbidden}`);
  }
});
check("no deterministic commercial authority is added", () => {
  const lower = contract.toLowerCase();
  for (const forbidden of ["opportunityrank", "routerank", "contactrank", "commercialscore", "executionpermission"]) {
    assert(!lower.includes(forbidden), `authority field present: ${forbidden}`);
  }
});
check("no browser credential path is introduced", () => {
  const combined = [application, provider, bedrockRuntime, bedrockProvider].join("\n");
  for (const forbidden of ['"use client"', "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "credentials:"]) {
    assert(!combined.includes(forbidden), `credential/browser token: ${forbidden}`);
  }
});

if (failures.length) process.exitCode = 1;
else console.log("\nPASS  Build 7.1/7.2 static architecture gate");
