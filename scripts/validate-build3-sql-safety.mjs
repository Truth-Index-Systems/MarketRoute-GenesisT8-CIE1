import fs from "node:fs";
import path from "node:path";
import { ROOT, assert, check, printResults } from "./lib/constitution.mjs";

const sqlPath = path.join(ROOT, "supabase/migrations/0006_evidence_provenance_runtime.sql");
const sql = fs.readFileSync(sqlPath, "utf8");
const applyPath = path.join(ROOT, "APPLY-IN-SUPABASE-MARKETROUTE-V2-BUILD3.sql");
const apply = fs.readFileSync(applyPath, "utf8");
const results = [];

results.push(check("migration is atomic", () => assert(sql.trim().startsWith("BEGIN;") && sql.trim().endsWith("COMMIT;"), "missing transaction boundary")));
results.push(check("standalone installer equals migration exactly", () => assert(apply === sql, "standalone SQL differs from canonical 0006")));
results.push(check("dollar quotes are balanced", () => assert((sql.match(/\$\$/g) ?? []).length % 2 === 0, "unbalanced $$")));
results.push(check("no CREATE OR REPLACE changes an OUT-table signature from Builds 1-2", () => {
  const replaced = [...sql.matchAll(/CREATE OR REPLACE FUNCTION\s+public\.([a-z0-9_]+)/g)].map((m) => m[1]);
  const oldFunctions = new Set(["marketroute_validate_claim_evidence_scope"]);
  for (const name of replaced) {
    if (oldFunctions.has(name)) {
      const start = sql.indexOf(`CREATE OR REPLACE FUNCTION public.${name}`);
      const tail = sql.slice(start, start + 500);
      assert(tail.includes("RETURNS trigger"), `${name} return contract changed`);
    }
  }
}));
results.push(check("new RPCs are revoked from PUBLIC", () => {
  for (const name of ["marketroute_ingest_evidence_v1", "marketroute_record_claim_evidence_v1", "marketroute_supersede_claim_v1"]) {
    assert(sql.includes(`REVOKE ALL ON FUNCTION public.${name}`), `${name} PUBLIC revoke missing`);
  }
}));
results.push(check("only service_role can execute write RPCs", () => {
  assert((sql.match(/GRANT EXECUTE ON FUNCTION public\.marketroute_/g) ?? []).length === 3, "unexpected execute grants");
  assert(!sql.includes("TO authenticated;\n\nGRANT EXECUTE"), "authenticated write RPC grant detected");
}));
results.push(check("migration reloads PostgREST schema", () => assert(sql.includes("NOTIFY pgrst, 'reload schema';"), "PostgREST reload missing")));
results.push(check("migration does not touch authority writer registry", () => assert(!sql.includes("INSERT INTO public.authority_writer_registry"), "Build 3 registered authority writer")));
results.push(check("migration does not create opportunity transition RPC", () => assert(!/FUNCTION\s+public\.[a-z0-9_]*opportunit[a-z0-9_]*\s*\(/i.test(sql), "Build 3 creates workflow capability")));
results.push(check("source identity backfill is explicit and versioned", () => assert(sql.includes("MRV2-EVIDENCE-NORM-PREBUILD3") && sql.includes("MRV2-DEPENDENCE-BACKFILL"), "pre-Build3 backfill not quarantined")));
results.push(check("claim link backfill temporarily disables only append-only trigger", () => {
  assert(sql.includes("ALTER TABLE public.claim_evidence_links DISABLE TRIGGER claim_evidence_links_append_only;"), "controlled backfill disable missing");
  assert(sql.includes("ALTER TABLE public.claim_evidence_links ENABLE TRIGGER claim_evidence_links_append_only;"), "controlled backfill re-enable missing");
}));

printResults("MarketRoute V2 Build 3 — SQL safety gate", results);
