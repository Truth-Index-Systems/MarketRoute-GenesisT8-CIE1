import fs from "node:fs";
import path from "node:path";
import assert from "node:assert/strict";

const root = path.resolve(import.meta.dirname, "../..");
const sql = fs.readFileSync(path.join(root, "supabase/migrations/0008_seller_commercial_genome.sql"), "utf8");
const tests = [];
const test = (name, fn) => tests.push({ name, fn });

test("client cannot choose semantic fingerprint", () => assert.doesNotMatch(sql, /marketroute_persist_seller_genome_v1\([\s\S]{0,1200}p_semantic_fingerprint/));
test("client cannot choose exact content fingerprint", () => assert.doesNotMatch(sql, /marketroute_persist_seller_genome_v1\([\s\S]{0,1200}p_content_fingerprint/));
test("semantic fingerprint is based only on semantic machine payload", () => assert.match(sql, /MRV2-SELLER-GENOME-SEMANTIC-1\.0\.0[\s\S]*marketroute_seller_genome_semantic_identity_v1\(p_canonical_genome_json\)/));
test("prose-only changes can preserve semantic fingerprint", () => {
  const semanticBlock = sql.slice(sql.indexOf("v_semantic_fingerprint :="), sql.indexOf("v_content_fingerprint :="));
  assert.doesNotMatch(semanticBlock, /sellerDisplayName|offeringCopy|objectiveCopy|statement|description/);
});
test("exact provenance includes source material fingerprint", () => assert.match(sql, /MRV2-SELLER-GENOME-CONTENT-1\.0\.0[\s\S]*v_source\.material_fingerprint/));
test("source material cannot cross seller scope", () => assert.match(sql, /MARKETROUTE_SELLER_GENOME_SOURCE_SCOPE_INVALID/));
test("source material creator must be an active member when supplied", () => assert.match(sql, /MARKETROUTE_SELLER_SOURCE_CREATOR_NOT_MEMBER/));
test("campaign cannot bind genome from a different seller", () => assert.match(sql, /v_genome\.seller_business_id <> v_campaign\.seller_business_id/));
test("campaign cannot bind nonexistent objective", () => assert.match(sql, /MARKETROUTE_SELLER_CONTEXT_OBJECTIVE_NOT_FOUND/));
test("campaign cannot bind an objective dimension declared unknown", () => assert.match(sql, /MARKETROUTE_SELLER_CONTEXT_OBJECTIVE_NOT_DECLARED/));
test("objective offering references must resolve within snapshot", () => assert.match(sql, /MARKETROUTE_SELLER_GENOME_OBJECTIVE_UNKNOWN_OFFERING/));
test("unknown dimension is not silently treated as explicit none", () => assert.match(sql, /v_state NOT IN \('DECLARED','EXPLICIT_NONE','UNKNOWN'\)/));
test("database rejects authority-like fields anywhere in canonical genome", () => assert.match(sql, /MARKETROUTE_SELLER_GENOME_FORBIDDEN_FIELD/));
test("database rejects unknown semantic keys", () => assert.match(sql, /MARKETROUTE_SELLER_GENOME_SEMANTIC_KEYS_INVALID/));
test("database canonicalises semantic array order before fingerprinting", () => assert.match(sql, /marketroute_seller_genome_semantic_identity_v1[\s\S]*marketroute_sort_jsonb_text_array_v1/));
test("database rejects duplicate machine codes inside arrays", () => assert.match(sql, /count\(DISTINCT value\)/));
test("declared constraint requires machine-readable value code", () => assert.match(sql, /jsonb_array_length\(v_item->'valueCodes'\) = 0/));
test("missing dimensions must exactly equal derived UNKNOWN dimensions", () => assert.match(sql, /MARKETROUTE_SELLER_GENOME_MISSING_DIMENSIONS_MISMATCH/));
test("declared list dimensions may not be empty", () => assert.match(sql, /MARKETROUTE_SELLER_GENOME_DECLARED_EMPTY/));
test("non-declared list dimensions may not carry hidden items", () => assert.match(sql, /MARKETROUTE_SELLER_GENOME_NONDECLARED_HAS_ITEMS/));
test("delivery unknown cannot carry hidden modes", () => assert.match(sql, /MARKETROUTE_SELLER_GENOME_NONDECLARED_HAS_VALUES:delivery/));
test("geography unknown cannot carry hidden geography values", () => assert.match(sql, /MARKETROUTE_SELLER_GENOME_NONDECLARED_HAS_VALUES:serviceGeography/));
test("target unknown cannot carry hidden target values", () => assert.match(sql, /MARKETROUTE_SELLER_GENOME_NONDECLARED_HAS_VALUES:targetCharacteristics/));
test("buyer unknown cannot carry hidden buyer values", () => assert.match(sql, /MARKETROUTE_SELLER_GENOME_NONDECLARED_HAS_VALUES:buyerAssumptions/));
test("seller display name is checked against canonical seller record", () => assert.match(sql, /MARKETROUTE_SELLER_GENOME_DISPLAY_NAME_MISMATCH/));
test("source fingerprint collision fails closed", () => assert.match(sql, /MARKETROUTE_SELLER_SOURCE_FINGERPRINT_COLLISION/));
test("content fingerprint collision fails closed", () => assert.match(sql, /MARKETROUTE_SELLER_GENOME_CONTENT_FINGERPRINT_COLLISION/));
test("campaign selection retries are idempotent by request ID", () => assert.match(sql, /WHERE selection_request_id = p_request_id/));
test("later intentional re-selection is not blocked by semantic input uniqueness", () => {
  const table = sql.slice(sql.indexOf("CREATE TABLE public.campaign_seller_context_selections"), sql.indexOf("CREATE INDEX campaign_seller_context_latest_idx"));
  assert.doesNotMatch(table, /input_fingerprint text NOT NULL UNIQUE/);
  assert.match(table, /selection_request_id uuid NOT NULL UNIQUE/);
});
test("request ID reuse with different selection fails closed", () => assert.match(sql, /MARKETROUTE_SELLER_CONTEXT_REQUEST_ID_REUSE_MISMATCH/));
test("semantic campaign context derives from seller semantic fingerprint", () => assert.match(sql, /MRV2-SELLER-CONTEXT-SEMANTIC-1\.0\.0[\s\S]*v_genome\.semantic_fingerprint/));
test("all three ledgers reject update/delete", () => {
  for (const trigger of ["seller_genome_source_materials_append_only", "seller_commercial_genome_snapshots_append_only", "campaign_seller_context_selections_append_only"]) assert.match(sql, new RegExp(trigger));
});
test("service role has SELECT but no direct seller-genome DML", () => {
  assert.match(sql, /GRANT SELECT ON public\.seller_commercial_genome_snapshots TO authenticated, service_role/);
  assert.doesNotMatch(sql, /GRANT (INSERT|UPDATE|DELETE)[^;]*seller_commercial_genome_snapshots[^;]*service_role/);
});
test("no numeric commercial score column exists", () => {
  const lower = sql.toLowerCase();
  for (const token of ["opportunity_score", "route_quality", "route_confidence", "company_fit", "business_fit", "is_viable"]) assert.equal(lower.includes(token), false, token);
});
test("authority registry remains untouched", () => assert.doesNotMatch(sql, /authority_writer_registry[\s\S]*INSERT/i));
test("workflow state remains untouched", () => assert.doesNotMatch(sql, /UPDATE\s+public\.campaigns[\s\S]*workflow_state|UPDATE\s+public\.opportunities/i));

let passed = 0;
console.log("\nMarketRoute V2 Build 5 — database-boundary adversarial gate");
for (const { name, fn } of tests) {
  try { fn(); passed++; console.log(`PASS  ${name}`); }
  catch (error) { console.error(`FAIL  ${name}: ${error instanceof Error ? error.message : error}`); }
}
console.log(`\n${passed}/${tests.length} PASS`);
if (passed !== tests.length) process.exitCode = 1;
