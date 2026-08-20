import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const root = process.cwd();
const adapter = readFileSync(resolve(root, "platform/database/aws-data-api.ts"), "utf8");
const operations = readFileSync(resolve(root, "platform/database/aws-data-api-operations.ts"), "utf8");
const types = readFileSync(resolve(root, "platform/database/aws-data-api-types.ts"), "utf8");

assert.match(adapter, /import\s+["']server-only["']/);
assert.match(adapter, /@aws-sdk\/client-rds-data/);
assert.match(adapter, /MARKETROUTE_AWS_RDS_CLUSTER_ARN/);
assert.match(adapter, /MARKETROUTE_AWS_RDS_SECRET_ARN/);
assert.match(adapter, /MARKETROUTE_AWS_RDS_DATABASE/);
assert.doesNotMatch(adapter, /SUPABASE_/);
assert.doesNotMatch(operations, /SUPABASE_/);
assert.doesNotMatch(types, /SUPABASE_/);

for (const operation of [
  "system.health",
  "system.currentDatabase",
  "commercial.publicPlans",
  "genesis.growthSettings",
  "truth.policyBinding",
]) assert.match(operations, new RegExp(operation.replace(".", "\\.")));

assert.match(adapter, /executeOperation<TName extends AwsDataApiOperationName>/);
assert.doesNotMatch(adapter, /executeSql\s*\(/);
assert.doesNotMatch(adapter, /querySql\s*\(/);
assert.doesNotMatch(adapter, /callRoutine\s*\(/);
assert.doesNotMatch(adapter, /selectTable\s*\(/);
assert.doesNotMatch(adapter, /console\.(?:log|info|warn|error)/);
assert.match(adapter, /definition\.kind === "READ" && !transactionId/);
assert.match(adapter, /uncertainWrite: definition\.kind === "WRITE"/);
assert.match(adapter, /TRANSACTION_CONCURRENT_EXECUTION_FORBIDDEN/);
assert.match(adapter, /rollback\([^)]*\)\.catch\(\(\) => undefined\)/);
assert.match(operations, /FROM public\.marketroute_plan_catalog/);
assert.match(operations, /FROM public\.genesis_growth_settings/);
assert.match(operations, /marketroute_truth_policy_for_claim_v1/);

console.log("AWS V0 Build 4 static adapter validation passed");
