import fs from "node:fs";
const root = "infrastructure/aws-v0/runtime/research-worker/";
const read = p => fs.readFileSync(p, "utf8");
if (!read(root + "index.mjs").includes('from "./admitted-executor.mjs"')) throw new Error("Production entry bypasses admission");
const runtime = read(root + "admitted-executor.mjs");
for (const item of ["admission.preflight", "provider.prepare", "admission.admit", "provider.executePrepared", "admission.settle"]) {
  if (!runtime.includes(item)) throw new Error(`Missing mandatory admission stage: ${item}`);
}
if (runtime.includes("createBedrockCompanyUnderstandingProvider")) throw new Error("Unguarded legacy provider fallback");
const provider = read(root + "prepared-provider.mjs");
for (const item of ["maxAttempts: 1", "CountTokensCommand", "InvokeModelCommand", "prepared.delete(plan)", "output_config"]) {
  if (!provider.includes(item)) throw new Error(`Missing prepared-request invariant: ${item}`);
}
const migration = read("database/aws/0006_marketroute_aws_build11_inference_admission.sql");
for (const item of ["DEFAULT false", "BETWEEN 11 AND 3600", "clock_timestamp()", "FOR UPDATE", "CANONICAL_RESERVATION_REQUIRED", "MEASURED_USAGE_EXCEEDED_RESERVATION"]) {
  if (!migration.includes(item)) throw new Error(`Missing admission persistence invariant: ${item}`);
}
for (const table of ["claims", "truth_claim_snapshots", "authority_records", "commercial_reality_r4_records", "route_authority_r5_records", "contact_authority_r6_records"]) {
  if (new RegExp(`(?:INSERT INTO|UPDATE|DELETE FROM) public\\.${table}\\b`, "i").test(migration)) throw new Error(`Admission acquired authority: ${table}`);
}
console.log("PASS Build 11 production entry and admission source boundaries");
