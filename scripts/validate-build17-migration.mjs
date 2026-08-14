import fs from "node:fs";
import path from "node:path";
import { ROOT, assert, check, printResults } from "./lib/constitution.mjs";
import { validateBundle } from "./migration/v1-contract.mjs";

const sql = fs.readFileSync(path.join(ROOT, "supabase/migrations/0019_v1_evidence_migration.sql"), "utf8");
const readme = fs.readFileSync(path.join(ROOT, "migration/v1/README.md"), "utf8");
const example = JSON.parse(fs.readFileSync(path.join(ROOT, "migration/v1/example.bundle.json"), "utf8"));
const results = [];
results.push(check("Build 17 migration SQL exists", () => assert(sql.length > 10000, "migration SQL unexpectedly small")));
results.push(check("Build 17 declares factual-only contract", () => assert(sql.includes("MRV2-V1-FACTUAL-EXPORT-1.0.0") && readme.includes("factual/evidence"), "contract")));
results.push(check("V1 source remains offline from V2 runtime", () => assert(readme.includes("static export file") && readme.includes("does not import V1 code") && readme.includes("call V1 RPCs"), "offline bridge")));
results.push(check("migration supports company people contact seller campaign evidence history", () => {
  for (const fn of ["import_v1_company","import_v1_person","import_v1_access_point","import_v1_seller_business","import_v1_seller_source","import_v1_campaign","import_v1_campaign_scope","import_v1_evidence","import_v1_historical_research"]) assert(sql.includes(`marketroute_${fn}_v1`), fn);
}));
results.push(check("mapping is explicit and immutable", () => assert(sql.includes("marketroute_v1_migration_id_map") && sql.includes("marketroute_v1_migration_id_map_append_only"), "mapping")));
results.push(check("rejections and audit events are append-only", () => assert(sql.includes("marketroute_v1_migration_rejections_append_only") && sql.includes("marketroute_v1_migration_audit_append_only"), "audit append-only")));
results.push(check("database recomputes per-record import fingerprint", () => assert(sql.includes("marketroute_v1_record_fingerprint_v1") && sql.includes("MRV2-V1-IMPORT-RECORD-1.0.0"), "fingerprint")));
results.push(check("forbidden V1 authority keys are rejected recursively", () => assert(sql.includes("marketroute_v1_payload_forbidden_keys_v1") && sql.includes("MARKETROUTE_V1_AUTHORITY_FIELD_REJECTED") && sql.includes("opportunityscore") && sql.includes("truthindex"), "forbidden keys")));
results.push(check("campaigns are imported as DRAFT", () => assert(/INSERT INTO public\.campaigns[\s\S]*?'DRAFT'/i.test(sql), "campaign state")));
results.push(check("migrated evidence is explicitly MIGRATED", () => assert((sql.match(/'MIGRATED'/g) ?? []).length >= 4, "MIGRATED markers")));
results.push(check("completion explicitly hands off to V2 recomputation", () => assert(sql.includes("RECOMPUTE_V2_TRUTH_R4_R5_R6") && sql.includes("V2_TRUTH_THEN_R4_THEN_R5_THEN_R6"), "recompute handoff")));
results.push(check("example bundle validates", () => assert(validateBundle(example).totalRecords === 9, "example")));
results.push(check("standalone installer equals canonical migration", () => assert(fs.readFileSync(path.join(ROOT,"APPLY-IN-SUPABASE-MARKETROUTE-V2-BUILD17.sql"),"utf8") === sql, "installer mismatch")));
printResults("MarketRoute V2 Build 17 — migration contract", results);
