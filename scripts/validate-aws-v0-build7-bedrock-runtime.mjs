import fs from "node:fs";

const REQUIRED_VERSION = "3.1111.0";
const pkg = JSON.parse(fs.readFileSync(new URL("../package.json", import.meta.url), "utf8"));
const lock = JSON.parse(fs.readFileSync(new URL("../package-lock.json", import.meta.url), "utf8"));

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

console.log("\nAWS V0 Build 7.2 — Bedrock dependency/runtime gate");
assert(process.versions.node.split(".")[0] === "22", `Node 22 required; got ${process.versions.node}`);
console.log(`PASS  Node runtime ${process.versions.node}`);
assert(pkg.dependencies?.["@aws-sdk/client-bedrock-runtime"] === REQUIRED_VERSION, "package.json Bedrock SDK pin mismatch");
console.log("PASS  package.json exact Bedrock SDK pin");
assert(lock.packages?.[""]?.dependencies?.["@aws-sdk/client-bedrock-runtime"] === REQUIRED_VERSION, "package-lock root pin mismatch");
assert(lock.packages?.["node_modules/@aws-sdk/client-bedrock-runtime"]?.version === REQUIRED_VERSION, "package-lock installed SDK version mismatch");
console.log("PASS  package-lock exact Bedrock SDK pin");

const sdk = await import("@aws-sdk/client-bedrock-runtime");
assert(typeof sdk.BedrockRuntimeClient === "function", "BedrockRuntimeClient import missing");
const client = new sdk.BedrockRuntimeClient({ region: "eu-west-2", maxAttempts: 1 });
assert(typeof client.send === "function", "BedrockRuntimeClient runtime surface invalid");
client.destroy();
console.log("PASS  clean runtime import/constructor proof (no network invocation)");
console.log("\nPASS  Build 7.2 dependency/runtime gate");
