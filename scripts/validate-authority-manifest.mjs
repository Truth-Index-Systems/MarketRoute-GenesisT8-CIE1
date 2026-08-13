import fs from "node:fs";
import path from "node:path";
import { ROOT, assert, check, printResults, readJson, relative, sourceFiles } from "./lib/constitution.mjs";

const manifest = readJson("constitution/authority-manifest.json");
const results = [
  check("constitution is foundation-only", () => assert(manifest.status === "FOUNDATION_ONLY", "status must be FOUNDATION_ONLY")),
  check("Build 1 declares zero authority writers", () => assert(manifest.authorityWriters.length === 0, "Build 1 must have zero authority writers")),
  check("future R4/R5/R6 stages are declared conceptually", () => {
    const expected = ["commercial-reality", "route-authority", "contact-authority"];
    for (const item of expected) assert(manifest.declaredFutureAuthorityStages.includes(item), `${item} missing`);
  }),
  check("UI authority reconstruction forbidden", () => assert(manifest.rules.uiMayNotConstructAuthority === true, "UI rule missing")),
  check("workflow and authority explicitly separated", () => assert(manifest.rules.workflowStateIsNotAuthorityState === true, "state separation missing")),
  check("legacy runtime dependency forbidden", () => assert(manifest.rules.legacyRuntimeDependencies === false, "legacy runtime rule missing")),
];

results.push(check("no authority implementation exists before declaration", () => {
  const authorityFiles = sourceFiles().filter((f) => relative(f).startsWith("core/authority/") && !relative(f).endsWith("README.md"));
  assert(authorityFiles.length === 0, `undeclared authority implementation: ${authorityFiles.map(relative).join(", ")}`);
}));

results.push(check("Build 1 has no SQL migration", () => {
  const migrationDir = path.join(ROOT, "supabase/migrations");
  const sql = fs.readdirSync(migrationDir).filter((name) => name.endsWith(".sql"));
  assert(sql.length === 0, `Build 1 must not own DB schema: ${sql.join(", ")}`);
}));

printResults("MarketRoute V2 Build 1 — authority manifest", results);
