import fs from "node:fs";
import path from "node:path";
import { ROOT, assert, check, printResults, readJson, relative, sourceFiles } from "./lib/constitution.mjs";

const manifest = readJson("constitution/authority-manifest.json");
const results = [
  check("schema has advanced to Build 6", () => assert(manifest.schemaBuild >= 6, `schemaBuild=${manifest.schemaBuild}`)),
  check("exactly one authority writer exists at Build 6", () => assert(manifest.authorityWriters.length === 1, `writers=${manifest.authorityWriters.length}`)),
  check("the only writer is R4 commercial reality", () => { const w=manifest.authorityWriters[0]; assert(w.writerKey === "marketroute.r4.commercial-reality" && w.authorityStage === "COMMERCIAL_REALITY", "unexpected writer"); }),
  check("R4 has no numeric authority", () => assert(manifest.authorityWriters[0].numericAuthority === false, "numeric R4 authority forbidden")),
  check("database recomputes R4 decision and fingerprint", () => assert(manifest.authorityWriters[0].databaseRecomputesDecision === true && manifest.authorityWriters[0].databaseRecomputesFingerprint === true, "DB recomputation missing")),
  check("R5/R6 remain future-only", () => { for (const item of ["route-authority","contact-authority"]) assert(manifest.declaredFutureAuthorityStages.includes(item), `${item} missing`); }),
  check("UI authority reconstruction forbidden", () => assert(manifest.rules.uiMayNotConstructAuthority === true, "UI rule missing")),
  check("workflow and authority separated", () => assert(manifest.rules.workflowStateIsNotAuthorityState === true, "state separation missing")),
  check("legacy runtime dependency forbidden", () => assert(manifest.rules.legacyRuntimeDependencies === false, "legacy rule missing")),
  check("direct authority DML forbidden", () => assert(manifest.rules.directAuthorityDmlForbidden === true, "DML rule missing")),
];
results.push(check("only declared authority implementation exists", () => {
  const files=sourceFiles().filter((f)=>relative(f).startsWith("core/authority/") && !relative(f).endsWith("README.md"));
  assert(files.length === 1 && relative(files[0]) === "core/authority/commercial-reality.ts", `unexpected authority files: ${files.map(relative).join(", ")}`);
}));
results.push(check("Build 2 migration foundation 0001-0005 remains intact", () => {
  const sql=fs.readdirSync(path.join(ROOT,"supabase/migrations")).filter((n)=>n.endsWith(".sql")).sort();
  const foundation=sql.filter((n)=>/^000[1-5]_/.test(n)); assert(foundation.length===5, `foundation changed: ${foundation.join(",")}`);
}));
printResults("MarketRoute V2 Build 6 — authority manifest", results);
