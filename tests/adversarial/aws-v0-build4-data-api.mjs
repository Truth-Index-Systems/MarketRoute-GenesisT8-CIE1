import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const adapter = readFileSync(resolve(process.cwd(), "platform/database/aws-data-api.ts"), "utf8");
const operations = readFileSync(resolve(process.cwd(), "platform/database/aws-data-api-operations.ts"), "utf8");

// Adversarial boundary: callers get named operations, never arbitrary SQL/routine/table names.
assert.doesNotMatch(adapter, /public\s+async\s+(?:execute|query)\s*\([^)]*sql/i);
assert.doesNotMatch(adapter, /function\s+awsDataApiOperationDefinition\([^)]*string/);
assert.match(operations, /type AwsDataApiOperationName\s*=\s*[\s\S]*"truth\.policyBinding"/);

// All SQL is registry-owned and parameterised. No caller input is interpolated into SQL text.
assert.doesNotMatch(operations, /\$\{[^}]+\}/);
assert.match(operations, /:subject_type/);
assert.match(operations, /:claim_key/);

// Secret material is only forwarded to the driver; it is never included in public error text or logging.
assert.doesNotMatch(adapter, /console\./);
assert.doesNotMatch(adapter, /JSON\.stringify\([^)]*secretArn/);
assert.doesNotMatch(adapter, /JSON\.stringify\([^)]*clusterArn/);

// Retry policy is deliberately asymmetric: safe reads may retry outside transactions; writes never do.
assert.match(adapter, /const retryLimit = definition\.kind === "READ" && !transactionId/);
assert.doesNotMatch(adapter, /definition\.kind === "WRITE"[^\n]*retry/i);

// Transaction operations cannot overlap, preventing accidental parallel use of one Data API transaction.
assert.match(adapter, /if \(inFlight\) throw new Error\("MARKETROUTE_AWS_DATA_API_TRANSACTION_CONCURRENT_EXECUTION_FORBIDDEN"\)/);

console.log("AWS V0 Build 4 adversarial database boundary checks passed");
