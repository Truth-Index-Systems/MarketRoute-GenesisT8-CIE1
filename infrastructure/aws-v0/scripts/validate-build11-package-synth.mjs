// Prove CDK references the verified ZIP, not a source directory or another asset.
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const receipt = JSON.parse(execFileSync("python3", [path.join(root, "scripts/package-research-worker.py"), "verify"], { encoding: "utf8" }));
const out = path.join(root, "cdk.out");
const template = JSON.parse(fs.readFileSync(path.join(out, "MrAwsV0ResearchStack.template.json"), "utf8"));
const functions = Object.values(template.Resources).filter(r => r.Type === "AWS::Lambda::Function");
assert.equal(functions.length, 1);
const fn = functions[0].Properties;
assert.equal(fn.Handler, "index.handler");
assert.equal(fn.Runtime, "nodejs22.x");
assert.deepEqual(fn.Architectures, ["arm64"]);
assert.equal(fn.Code.ZipFile, undefined);
assert.equal(fn.Layers, undefined, "No hidden dependency layer allowed");
assert.equal(template.Outputs.ResearchWorkerPackageSha256.Value, receipt.archiveSha256);
const assets = JSON.parse(fs.readFileSync(path.join(out, "MrAwsV0ResearchStack.assets.json"), "utf8"));
const candidates = Object.values(assets.files ?? {}).filter(a => Object.values(a.destinations ?? {}).some(d => d.objectKey === fn.Code.S3Key));
assert.equal(candidates.length, 1, "Find the exact asset referenced by the function");
const asset = candidates[0];
assert.equal(asset.source.packaging, "file", "CDK must not repackage this ZIP");
const deployedBytes = fs.readFileSync(path.resolve(out, asset.source.path));
assert.equal(createHash("sha256").update(deployedBytes).digest("hex"), receipt.archiveSha256);
for (const r of Object.values(template.Resources).filter(r => r.Type === "AWS::Lambda::EventSourceMapping")) {
  assert.equal(r.Properties.Enabled, false, "Package proof cannot activate SQS");
}
console.log("PASS Build 11 synthesized function uses the verified, byte-identical worker ZIP; activation disabled");
