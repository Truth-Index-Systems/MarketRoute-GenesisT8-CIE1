import fs from "node:fs";
import path from "node:path";
import assert from "node:assert/strict";

const root = path.resolve(import.meta.dirname, "../..");
const sql = fs.readFileSync(path.join(root, "supabase/migrations/0007_truth_engine_v2.sql"), "utf8");
const tests = [];
const test = (name, fn) => tests.push({ name, fn });

test("caller cannot persist calibrated probability", () => assert.match(sql, /MARKETROUTE_TRUTH_PROBABILITY_FORBIDDEN_UNTIL_CALIBRATED/));
test("claim state is independently re-derived in database", () => assert.match(sql, /p_truth_state IS DISTINCT FROM v_facts\.truth_state/));
test("support family count is independently verified", () => assert.match(sql, /p_current_support_family_count IS DISTINCT FROM v_facts\.current_support_family_count/));
test("contradiction family count is independently verified", () => assert.match(sql, /p_current_contradiction_family_count IS DISTINCT FROM v_facts\.current_contradiction_family_count/));
test("DB contradiction precedes KNOWN", () => {
  const facts = sql.slice(sql.indexOf("truth_state := CASE"), sql.indexOf("next_revalidation_at := v_next"));
  assert.ok(facts.indexOf("WHEN v_contradiction > 0") < facts.indexOf("WHEN v_support >="));
});
test("same family support plus contradiction counts as contradiction", () => assert.match(sql, /COUNT\(\*\) FILTER \(WHERE current_contradiction\)/));
test("support family excludes conflicted family", () => assert.match(sql, /current_support AND NOT current_contradiction/));
test("currentness expires strictly before max age", () => assert.match(sql, /p_reference_time - effective_origin < make_interval/));
test("staleness begins at exact max age", () => assert.match(sql, /p_reference_time - effective_origin >= make_interval/));
test("undated evidence uses observed time fallback", () => assert.match(sql, /COALESCE\(e\.origin_published_at, s\.published_at, e\.observed_at\)/));
test("future timestamps are treated as anomalies", () => assert.match(sql, /interval '5 minutes'/));
test("context fingerprint includes exact reference time", () => assert.match(sql, /MRV2-TRUTH-CONTEXT-1\.0\.0[\s\S]*v_reference_text/));
test("context fingerprint includes evidence fingerprints", () => assert.match(sql, /e\.evidence_fingerprint/));
test("superseded claims cannot be evaluated", () => assert.match(sql, /MARKETROUTE_TRUTH_SUPERSEDED_CLAIM_FORBIDDEN/));
test("stale context cannot be persisted", () => assert.match(sql, /v_current_context IS DISTINCT FROM p_context_fingerprint/));
test("claim snapshot fingerprint is database-generated", () => assert.match(sql, /v_snapshot_fingerprint := encode\(extensions\.digest/));
test("entity profile map must contain every required key", () => assert.match(sql, /MARKETROUTE_TRUTH_ENTITY_SNAPSHOT_MAP_KEYS_MISMATCH/));
test("entity duplicate snapshot IDs are rejected", () => assert.match(sql, /MARKETROUTE_TRUTH_ENTITY_DUPLICATE_CLAIM_SNAPSHOT/));
test("entity cannot use claim snapshot from wrong subject", () => assert.match(sql, /MARKETROUTE_TRUTH_ENTITY_CLAIM_SNAPSHOT_SCOPE_MISMATCH/));
test("entity cannot mix reference times", () => assert.match(sql, /v_snapshot\.reference_time IS DISTINCT FROM p_reference_time/));
test("multiple positive propositions become entity contradiction", () => assert.match(sql, /COUNT\(DISTINCT proposition_fingerprint\)[\s\S]*IF v_contradicted_candidates > 0 THEN[\s\S]*ELSIF v_positive > 1 THEN/));
test("explicit entity contradiction precedes positive proposition selection", () => {
  const contradiction = sql.indexOf("IF v_contradicted_candidates > 0 THEN");
  const positive = sql.indexOf("ELSIF v_positive = 1 THEN", contradiction);
  assert.ok(contradiction >= 0 && positive > contradiction);
});
test("proposition fingerprint is database generated", () => {
  assert.match(sql, /marketroute_truth_proposition_fingerprint_v1\(p_claim_id\)/);
  assert.doesNotMatch(sql, /marketroute_persist_claim_truth_v1\([\s\S]{0,1200}p_proposition_fingerprint/);
});
test("tenant entity context can reuse global claims but not other tenant claims", () => {
  assert.match(sql, /p_tenant_scope_organisation_id IS NOT NULL AND \(c\.tenant_scope_organisation_id IS NULL OR c\.tenant_scope_organisation_id = p_tenant_scope_organisation_id\)/);
  assert.match(sql, /p_tenant_scope_organisation_id IS NOT NULL AND v_snapshot\.tenant_scope_organisation_id IS NOT NULL[\s\S]*v_snapshot\.tenant_scope_organisation_id <> p_tenant_scope_organisation_id/);
});
test("entity output is independently recomputed", () => assert.match(sql, /MARKETROUTE_TRUTH_ENTITY_OUTPUT_DOES_NOT_MATCH_CLAIM_TRUTH/));
test("Truth Index is database maximin", () => assert.match(sql, /LEAST\(v_expected_current_coverage, v_expected_sufficiency, v_expected_freshness, v_expected_coherence\) \* 100/));
test("Truth snapshots cannot be directly mutated", () => {
  assert.match(sql, /truth_claim_snapshots_append_only/);
  assert.match(sql, /truth_entity_snapshots_append_only/);
});
test("generic reasoning direct writes are revoked", () => {
  assert.match(sql, /REVOKE INSERT, UPDATE, DELETE ON public\.reasoning_runs FROM service_role/);
  assert.match(sql, /REVOKE INSERT, UPDATE, DELETE ON public\.reasoning_artifacts FROM service_role/);
});
test("no commercial authority registry mutation occurs", () => assert.doesNotMatch(sql, /INSERT\s+INTO\s+public\.authority_writer_registry/i));
test("no opportunity workflow mutation occurs", () => assert.doesNotMatch(sql, /UPDATE\s+public\.opportunities/i));

let passed = 0;
console.log("\nMarketRoute V2 Build 4 — database-boundary adversarial gate");
for (const { name, fn } of tests) {
  try { fn(); passed++; console.log(`PASS  ${name}`); }
  catch (error) { console.error(`FAIL  ${name}: ${error instanceof Error ? error.message : error}`); }
}
console.log(`\n${passed}/${tests.length} PASS`);
if (passed !== tests.length) process.exitCode = 1;
