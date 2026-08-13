import fs from "node:fs";
import path from "node:path";
import { ROOT, assert, check, printResults } from "./lib/constitution.mjs";

const migrationDir = path.join(ROOT, "supabase/migrations");
const files = fs.readdirSync(migrationDir).filter((n) => /^000[1-5]_.*\.sql$/.test(n)).sort();
const results = [];

for (const name of files) {
  const text = fs.readFileSync(path.join(migrationDir, name), "utf8");
  results.push(check(`${name} is transaction-wrapped`, () => {
    assert(/^BEGIN;\s*/i.test(text), "missing leading BEGIN");
    assert(/COMMIT;\s*$/i.test(text), "missing trailing COMMIT");
    assert((text.match(/\$\$/g) ?? []).length % 2 === 0, "unbalanced $$ delimiter");
  }));
}

const all = files.map((name) => fs.readFileSync(path.join(migrationDir, name), "utf8")).join("\n");
results.push(check("no DROP TABLE / DROP SCHEMA destructive migration", () => assert(!/\bdrop\s+(table|schema)\b/i.test(all), "destructive drop found")));
results.push(check("no SECURITY DEFINER function has implicit search_path", () => {
  const chunks = all.split(/CREATE OR REPLACE FUNCTION/i).slice(1);
  for (const chunk of chunks) {
    if (/SECURITY DEFINER/i.test(chunk)) assert(/SET search_path\s*=\s*public,\s*pg_temp/i.test(chunk), "SECURITY DEFINER missing fixed search_path");
  }
}));
results.push(check("authority trigger checks registry stage/version", () => {
  assert(/r\.authority_stage\s*=\s*NEW\.authority_stage/i.test(all), "authority stage not checked");
  assert(/r\.writer_version\s*=\s*NEW\.writer_version/i.test(all), "writer version not checked");
}));
results.push(check("PostgREST reload occurs only in final migration", () => {
  const occurrences = (all.match(/NOTIFY\s+pgrst/gi) ?? []).length;
  assert(occurrences === 1, `expected one reload, found ${occurrences}`);
}));


results.push(check("combined Supabase installer exactly concatenates 0001-0005", () => {
  const expected = files.map((name) => fs.readFileSync(path.join(migrationDir, name), "utf8").trimEnd()).join("\n\n") + "\n";
  const actual = fs.readFileSync(path.join(ROOT, "APPLY-IN-SUPABASE-MARKETROUTE-V2-BUILD2.sql"), "utf8");
  assert(actual === expected, "combined installer differs from canonical migrations");
}));
results.push(check("authority record requires reasoning run and artifact lineage", () => {
  assert(/reasoning_run_id\s+uuid\s+not\s+null/i.test(all), "authority reasoning_run_id missing");
  assert(/reasoning_artifact_id\s+uuid\s+not\s+null/i.test(all), "authority reasoning_artifact_id missing");
  assert(/authority_records_reasoning_artifact_fk/i.test(all), "authority reasoning-artifact FK missing");
  assert(/MARKETROUTE_AUTHORITY_REASONING_LINEAGE_MISMATCH/i.test(all), "authority reasoning scope gate missing");
}));
results.push(check("claim/evidence private scope is database-enforced", () => {
  assert(/MARKETROUTE_CLAIM_EVIDENCE_TENANT_MISMATCH/i.test(all), "tenant mismatch guard missing");
  assert(/MARKETROUTE_GLOBAL_CLAIM_CANNOT_USE_PRIVATE_EVIDENCE/i.test(all), "global/private scope guard missing");
}));

printResults("MarketRoute V2 Build 2 — SQL safety", results);
