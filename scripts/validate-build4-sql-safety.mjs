import fs from "node:fs";
import path from "node:path";
import { ROOT, assert, check, printResults } from "./lib/constitution.mjs";

const migrationPath = path.join(ROOT, "supabase/migrations/0007_truth_engine_v2.sql");
const standalonePath = path.join(ROOT, "APPLY-IN-SUPABASE-MARKETROUTE-V2-BUILD4.sql");
const sql = fs.readFileSync(migrationPath, "utf8");
const standalone = fs.readFileSync(standalonePath, "utf8");
const results = [];
const fn = (name) => sql.includes(`CREATE OR REPLACE FUNCTION public.${name}`);

results.push(check("migration is atomic", () => assert(/^BEGIN;/.test(sql.trimStart()) && /COMMIT;\s*$/.test(sql.trim()), "migration not atomic")));
results.push(check("migration reloads PostgREST schema", () => assert(sql.includes("NOTIFY pgrst, 'reload schema'"), "schema reload missing")));
results.push(check("standalone Build 4 installer exactly equals canonical 0007", () => assert(standalone === sql, "standalone SQL diverged from canonical migration")));
results.push(check("Build 4 release marker exists", () => assert(sql.includes("MRV2-BUILD4-TRUTH-ENGINE-V2"), "release marker missing")));
results.push(check("no authority writer is registered", () => assert(!/INSERT\s+INTO\s+public\.authority_writer_registry/i.test(sql), "Build 4 registers authority")));
results.push(check("no authority record is created", () => assert(!/INSERT\s+INTO\s+public\.authority_records/i.test(sql), "Build 4 writes commercial authority")));
results.push(check("truthProbability constrained null", () => assert((sql.match(/truth_probability IS NULL/g) ?? []).length >= 2, "null probability constraints missing")));
results.push(check("probability state constrained uncalibrated", () => assert((sql.match(/probability_state = 'UNCALIBRATED'/g) ?? []).length >= 2, "uncalibrated checks missing")));
results.push(check("Truth RPCs are service-role gated", () => assert((sql.match(/PERFORM public\.marketroute_require_service_role\(\);/g) ?? []).length >= 4, "service role gates missing")));
results.push(check("public execute is revoked on Truth RPCs", () => {
  for (const name of ["marketroute_get_claim_truth_context_v1", "marketroute_persist_claim_truth_v1", "marketroute_get_entity_truth_context_v1", "marketroute_persist_entity_truth_v1"]) {
    assert(sql.includes(`REVOKE ALL ON FUNCTION public.${name}`), `public revoke missing ${name}`);
  }
}));
results.push(check("only context/persistence RPCs are granted to service role", () => {
  assert(sql.includes("GRANT EXECUTE ON FUNCTION public.marketroute_get_claim_truth_context_v1"), "claim context grant missing");
  assert(sql.includes("GRANT EXECUTE ON FUNCTION public.marketroute_persist_claim_truth_v1"), "claim persist grant missing");
  assert(sql.includes("GRANT EXECUTE ON FUNCTION public.marketroute_get_entity_truth_context_v1"), "entity context grant missing");
  assert(sql.includes("GRANT EXECUTE ON FUNCTION public.marketroute_persist_entity_truth_v1"), "entity persist grant missing");
}));
results.push(check("internal Truth helpers are not granted", () => {
  for (const name of ["marketroute_truth_policy_for_claim_v1", "marketroute_truth_proposition_fingerprint_v1", "marketroute_truth_context_fingerprint_v1", "marketroute_truth_claim_facts_v1"]) {
    assert(fn(name), `helper missing ${name}`);
    assert(!sql.includes(`GRANT EXECUTE ON FUNCTION public.${name}`), `internal helper granted ${name}`);
  }
}));
results.push(check("no CREATE OR REPLACE view over historical V1 read models", () => {
  for (const legacy of ["opportunity_overview", "opportunity_detail", "commercial_routes"]) assert(!sql.includes(`VIEW public.${legacy}`), `legacy view touched ${legacy}`);
}));
results.push(check("snapshot tables remain service-role read only", () => {
  for (const table of ["truth_claim_snapshots", "truth_entity_snapshots"]) {
    assert(sql.includes(`REVOKE ALL ON public.${table} FROM anon, authenticated, service_role;`), `revoke missing ${table}`);
    assert(sql.includes(`GRANT SELECT ON public.${table} TO service_role;`), `select grant missing ${table}`);
    assert(!sql.includes(`GRANT SELECT, INSERT ON public.${table} TO service_role;`), `direct insert survives ${table}`);
  }
}));
results.push(check("SQL has balanced dollar-quote delimiters", () => assert((sql.match(/\$\$/g) ?? []).length % 2 === 0, "unbalanced $$ delimiters")));
results.push(check("SQL has one outer transaction", () => assert((sql.match(/^BEGIN;/gm) ?? []).length === 1 && (sql.match(/^COMMIT;/gm) ?? []).length === 1, "unexpected transaction boundaries")));

printResults("MarketRoute V2 Build 4 — SQL safety gate", results);
