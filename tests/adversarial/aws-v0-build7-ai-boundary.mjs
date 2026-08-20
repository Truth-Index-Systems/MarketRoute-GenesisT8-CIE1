import fs from "node:fs";
import path from "node:path";

const root = path.resolve(import.meta.dirname, "../..");
const layers = ["core", "application", "platform", "ui", "app"];
const extensions = new Set([".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs"]);
const failures = [];
const assert = (value, message) => { if (!value) throw new Error(message); };
const check = (name, fn) => {
  try { fn(); console.log(`PASS  ${name}`); }
  catch (error) { failures.push(name); console.error(`FAIL  ${name}: ${error instanceof Error ? error.message : String(error)}`); }
};
function walk(dir) {
  if (!fs.existsSync(dir)) return [];
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const absolute = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...walk(absolute));
    else if (extensions.has(path.extname(entry.name))) out.push(absolute);
  }
  return out;
}
const files = layers.flatMap((layer) => walk(path.join(root, layer)));
const rel = (file) => path.relative(root, file).replaceAll(path.sep, "/");

console.log("\nAWS V0 Build 7 — adversarial AI boundary through 7.5");
check("Bedrock SDK cannot leak outside platform/ai/bedrock", () => {
  const offenders = files.filter((file) => fs.readFileSync(file, "utf8").includes("@aws-sdk/client-bedrock-runtime"))
    .map(rel)
    .filter((file) => !file.startsWith("platform/ai/bedrock/"));
  assert(offenders.length === 0, `SDK leaked: ${offenders.join(", ")}`);
});
check("core authority cannot import AI transport", () => {
  const offenders = files.filter((file) => rel(file).startsWith("core/authority/"))
    .filter((file) => fs.readFileSync(file, "utf8").includes("platform/ai"))
    .map(rel);
  assert(offenders.length === 0, `authority leak: ${offenders.join(", ")}`);
});
check("UI cannot import AI transport", () => {
  const offenders = files.filter((file) => rel(file).startsWith("ui/"))
    .filter((file) => fs.readFileSync(file, "utf8").includes("platform/ai"))
    .map(rel);
  assert(offenders.length === 0, `UI transport leak: ${offenders.join(", ")}`);
});
check("7.5 Bedrock invocation exists only in certified adapter", () => {
  const commandFiles = files.filter((file) => fs.readFileSync(file, "utf8").includes("ConverseCommand")).map(rel);
  assert(JSON.stringify(commandFiles) === JSON.stringify(["platform/ai/bedrock/bedrock-semantic-provider.ts"]), `Converse leaked: ${commandFiles.join(", ")}`);
  const bedrock = fs.readFileSync(path.join(root, "platform/ai/bedrock/bedrock-semantic-provider.ts"), "utf8");
  for (const forbidden of ["ConverseStreamCommand", "InvokeModelCommand", "InvokeModelWithResponseStreamCommand"]) {
    assert(!bedrock.includes(forbidden), `forbidden provider command: ${forbidden}`);
  }
});
check("semantic public contract exposes no provider internals", () => {
  const text = fs.readFileSync(path.join(root, "core/ai/semantic-operation.ts"), "utf8");
  for (const forbidden of ["modelId", "providerRequestId", "rawPrompt", "rawResponse", "stack"]) {
    assert(!text.includes(forbidden), `public provider detail: ${forbidden}`);
  }
});
check("semantic execution boundary does not persist canonical state", () => {
  const text = fs.readFileSync(path.join(root, "application/ai/execute-semantic-operation.ts"), "utf8").toLowerCase();
  for (const forbidden of ["database", "repository", "persist", "insert", "upsert", "updatecanonical"]) {
    assert(!text.includes(forbidden), `persistence capability: ${forbidden}`);
  }
});

if (failures.length) process.exitCode = 1;
else console.log("\nPASS  Build 7 adversarial AI boundary through 7.5");
