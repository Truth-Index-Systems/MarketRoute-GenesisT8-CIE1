import fs from "node:fs";
import path from "node:path";
import assert from "node:assert/strict";

const root = path.resolve(import.meta.dirname, "../..");
const sql = fs.readFileSync(path.join(root, "supabase/migrations/0006_evidence_provenance_runtime.sql"), "utf8");
const manifest = JSON.parse(fs.readFileSync(path.join(root, "constitution/authority-manifest.json"), "utf8"));
const cases = [];
const test = (name, fn) => cases.push({ name, fn });

for (const table of ["source_records","source_acquisitions","evidence_items","claims","claim_supersessions","claim_evidence_links"]) {
  test(`${table} has no direct service_role INSERT after Build 3`, () => {
    const afterRevoke = sql.slice(sql.lastIndexOf(`REVOKE ALL ON public.${table}`));
    assert.ok(!new RegExp(`GRANT\\s+[^;]*INSERT[^;]*ON\\s+public\\.${table}\\s+TO\\s+service_role`, "i").test(afterRevoke));
  });
}
test("claim caller cannot choose dependence family", () => {
  const start = sql.indexOf("CREATE OR REPLACE FUNCTION public.marketroute_record_claim_evidence_v1");
  const end = sql.indexOf(")\nRETURNS TABLE", start);
  assert.ok(!sql.slice(start, end).includes("p_dependence_family"));
  assert.ok(sql.slice(start).includes("SELECT dependence_family_key INTO v_family"));
});
test("manual claim-link family mismatch is rejected by trigger", () => assert.ok(sql.includes("MARKETROUTE_DEPENDENCE_FAMILY_MUST_INHERIT_EVIDENCE")));
test("same source fingerprint with changed canonical identity is rejected", () => assert.ok(sql.includes("MARKETROUTE_SOURCE_FINGERPRINT_COLLISION")));
test("same evidence fingerprint with changed payload is rejected", () => assert.ok(sql.includes("MARKETROUTE_EVIDENCE_FINGERPRINT_COLLISION")));
test("same claim fingerprint with changed payload is rejected", () => assert.ok(sql.includes("MARKETROUTE_CLAIM_FINGERPRINT_COLLISION")));
test("source identity fields cannot mutate", () => {
  for (const field of ["source_kind","canonical_url","publisher_domain","source_identity_fingerprint","stable_locator","dependence_family_key","normalisation_version"]) assert.ok(sql.includes(`NEW.${field} IS DISTINCT FROM OLD.${field}`));
});
test("every write RPC checks backend role", () => assert.equal((sql.match(/PERFORM public\.marketroute_require_service_role\(\);/g) ?? []).length, 3));
test("evidence dedupe still records a new acquisition", () => {
  const acquisitionPos = sql.indexOf("INSERT INTO public.source_acquisitions");
  const evidencePos = sql.indexOf("INSERT INTO public.evidence_items");
  assert.ok(acquisitionPos > 0 && evidencePos > acquisitionPos);
});
test("evidence dedupe uses immutable fingerprint uniqueness", () => assert.ok(sql.includes("ON CONFLICT (evidence_fingerprint) DO NOTHING")));
test("source dedupe uses canonical source identity fingerprint", () => assert.ok(sql.includes("ON CONFLICT (source_identity_fingerprint) DO NOTHING")));
test("claim dedupe uses canonical claim fingerprint", () => assert.ok(sql.includes("ON CONFLICT (claim_fingerprint) DO NOTHING")));
test("claim/evidence link is idempotent", () => assert.ok(sql.includes("ON CONFLICT (claim_id, evidence_item_id, polarity) DO NOTHING")));
test("global claim cannot consume private evidence", () => assert.ok(sql.includes("MARKETROUTE_GLOBAL_CLAIM_CANNOT_USE_PRIVATE_EVIDENCE")));
test("cross-tenant evidence linking remains forbidden", () => assert.ok(sql.includes("MARKETROUTE_CLAIM_EVIDENCE_TENANT_MISMATCH")));
test("cross-subject evidence linking is forbidden", () => assert.ok(sql.includes("MARKETROUTE_CLAIM_EVIDENCE_SUBJECT_MISMATCH")));
test("same evidence cannot be both support and contradiction for one claim", () => assert.ok(sql.includes("claim_evidence_links_single_polarity_unique")));
test("Build 3 migration remains non-authoritative in successor repo", () => { assert.ok(!sql.includes("INSERT INTO public.authority_records")); assert.ok(!sql.includes("authority_writer_registry")); });
test("Build 3 migration never writes authority table", () => assert.ok(!sql.includes("INSERT INTO public.authority_records")));
test("Build 3 migration never writes opportunity workflow", () => assert.ok(!sql.includes("UPDATE public.opportunities")));

let passed = 0;
console.log("\nMarketRoute V2 Build 3 — database adversarial gate");
for (const { name, fn } of cases) {
  try { fn(); passed++; console.log(`PASS  ${name}`); }
  catch (error) { console.error(`FAIL  ${name}: ${error instanceof Error ? error.message : error}`); }
}
console.log(`\n${passed}/${cases.length} PASS`);
if (passed !== cases.length) process.exitCode = 1;
