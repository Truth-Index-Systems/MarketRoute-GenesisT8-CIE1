import fs from "node:fs";
import path from "node:path";
import { ROOT, assert, check, printResults, readJson, relative, sourceFiles } from "./lib/constitution.mjs";

const manifest = readJson("constitution/authority-manifest.json");
const results = [
  check("constitution is at schema-foundation state", () => assert(manifest.status === "SCHEMA_FOUNDATION", `status=${manifest.status}`)),
  check("Build 2 still declares zero authority writers", () => assert(manifest.authorityWriters.length === 0, "Build 2 must have zero authority writers")),
  check("future R4/R5/R6 stages remain declared conceptually", () => {
    const expected = ["commercial-reality", "route-authority", "contact-authority"];
    for (const item of expected) assert(manifest.declaredFutureAuthorityStages.includes(item), `${item} missing`);
  }),
  check("UI authority reconstruction forbidden", () => assert(manifest.rules.uiMayNotConstructAuthority === true, "UI rule missing")),
  check("workflow and authority explicitly separated", () => assert(manifest.rules.workflowStateIsNotAuthorityState === true, "state separation missing")),
  check("legacy runtime dependency forbidden", () => assert(manifest.rules.legacyRuntimeDependencies === false, "legacy runtime rule missing")),
  check("direct authority DML forbidden", () => assert(manifest.rules.directAuthorityDmlForbidden === true, "direct authority DML rule missing")),
  check("database must eventually recompute authority fingerprint", () => assert(manifest.rules.databaseMustRecomputeAuthorityFingerprint === true, "DB fingerprint law missing")),
];

results.push(check("no authority implementation exists before declaration", () => {
  const authorityFiles = sourceFiles().filter((f) => relative(f).startsWith("core/authority/") && !relative(f).endsWith("README.md"));
  assert(authorityFiles.length === 0, `undeclared authority implementation: ${authorityFiles.map(relative).join(", ")}`);
}));

results.push(check("Build 2 owns exactly five fresh SQL migrations", () => {
  const migrationDir = path.join(ROOT, "supabase/migrations");
  const sql = fs.readdirSync(migrationDir).filter((name) => name.endsWith(".sql")).sort();
  assert(sql.length === 5, `expected 5 migrations: ${sql.join(", ")}`);
  assert(sql[0].startsWith("0001_") && sql[4].startsWith("0005_"), `unexpected migration range: ${sql.join(", ")}`);
}));

printResults("MarketRoute V2 Build 2 — authority manifest", results);
