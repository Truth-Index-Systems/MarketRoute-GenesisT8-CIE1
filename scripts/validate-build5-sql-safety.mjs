import fs from "node:fs";
import path from "node:path";
import assert from "node:assert/strict";

const root = path.resolve(import.meta.dirname, "..");
const sql = fs.readFileSync(path.join(root, "supabase/migrations/0008_seller_commercial_genome.sql"), "utf8");
const standalone = fs.readFileSync(path.join(root, "APPLY-IN-SUPABASE-MARKETROUTE-V2-BUILD5.sql"), "utf8");
const tests = [];
const test = (name, fn) => tests.push({ name, fn });

test("migration is atomic", () => { assert.match(sql, /^BEGIN;/); assert.match(sql, /COMMIT;\s*$/); });
test("standalone SQL exactly matches canonical migration", () => assert.equal(standalone, sql));
test("Build 5 does not replace a prior function signature", () => {
  const prior = fs.readdirSync(path.join(root, "supabase/migrations")).filter((n) => /^000[1-7]_/.test(n)).map((n) => fs.readFileSync(path.join(root, "supabase/migrations", n), "utf8")).join("\n");
  for (const match of sql.matchAll(/CREATE OR REPLACE FUNCTION public\.([a-z0-9_]+)\(/g)) assert.equal(prior.includes(`FUNCTION public.${match[1]}(`), false, `prior function replaced: ${match[1]}`);
});
test("all five Build 5 functions revoke PUBLIC", () => {
  for (const fn of ["marketroute_seller_genome_validate_v1", "marketroute_record_seller_genome_source_v1", "marketroute_persist_seller_genome_v1", "marketroute_select_campaign_seller_context_v1", "marketroute_get_current_campaign_seller_context_v1"]) assert.match(sql, new RegExp(`REVOKE ALL ON FUNCTION public\\.${fn}\\(`));
});
test("internal validator is not executable by service role", () => assert.doesNotMatch(sql, /GRANT EXECUTE ON FUNCTION public\.marketroute_seller_genome_validate_v1/));
test("write RPCs are service-role only", () => {
  assert.match(sql, /GRANT EXECUTE ON FUNCTION public\.marketroute_record_seller_genome_source_v1[\s\S]*TO service_role/);
  assert.match(sql, /GRANT EXECUTE ON FUNCTION public\.marketroute_persist_seller_genome_v1[\s\S]*TO service_role/);
  assert.match(sql, /GRANT EXECUTE ON FUNCTION public\.marketroute_select_campaign_seller_context_v1[\s\S]*TO service_role/);
});
test("source table has seller scope composite FK", () => assert.match(sql, /seller_genome_source_materials_scope_fk[\s\S]*FOREIGN KEY \(organisation_id, seller_business_id\)/));
test("snapshot table has seller scope composite FK", () => assert.match(sql, /seller_genome_snapshots_scope_fk[\s\S]*FOREIGN KEY \(organisation_id, seller_business_id\)/));
test("campaign selection has campaign seller and snapshot scope FKs", () => {
  assert.match(sql, /campaign_seller_context_campaign_scope_fk/);
  assert.match(sql, /campaign_seller_context_seller_scope_fk/);
  assert.match(sql, /campaign_seller_context_genome_scope_fk/);
});
test("semantic fingerprint excludes source material and explanatory prose", () => {
  const block = sql.slice(sql.indexOf("v_semantic_fingerprint :="), sql.indexOf("v_content_fingerprint :="));
  assert.match(block, /marketroute_seller_genome_semantic_identity_v1\(p_canonical_genome_json\)/);
  assert.doesNotMatch(block, /v_source\.material_fingerprint/);
  assert.doesNotMatch(block, /explanatory/);
});
test("content fingerprint includes source material and full canonical genome", () => {
  const block = sql.slice(sql.indexOf("v_content_fingerprint :="), sql.indexOf("SELECT \* INTO v_existing", sql.indexOf("v_content_fingerprint :=")));
  assert.match(block, /v_source\.material_fingerprint/);
  assert.match(block, /p_canonical_genome_json::text/);
});
test("no caller-supplied fingerprint parameters exist", () => assert.doesNotMatch(sql, /p_(semantic|content|input)_fingerprint/));
test("Build 5 creates no authority records", () => assert.doesNotMatch(sql, /INSERT\s+INTO\s+public\.authority_records/i));
test("Build 5 creates no opportunity workflow transitions", () => assert.doesNotMatch(sql, /(INSERT\s+INTO|UPDATE)\s+public\.opportunities/i));
test("PostgREST schema reload is present", () => assert.match(sql, /NOTIFY pgrst, 'reload schema';/));

let passed = 0;
console.log("\nMarketRoute V2 Build 5 — SQL safety gate");
for (const { name, fn } of tests) {
  try { fn(); passed++; console.log(`PASS  ${name}`); }
  catch (error) { console.error(`FAIL  ${name}: ${error instanceof Error ? error.message : error}`); }
}
console.log(`\n${passed}/${tests.length} PASS`);
if (passed !== tests.length) process.exitCode = 1;
