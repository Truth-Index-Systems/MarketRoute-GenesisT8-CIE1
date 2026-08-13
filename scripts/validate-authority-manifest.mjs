import fs from "node:fs";
import path from "node:path";
import { ROOT, assert, check, printResults, readJson, relative, sourceFiles } from "./lib/constitution.mjs";

const manifest = readJson("constitution/authority-manifest.json");
const writers=new Map(manifest.authorityWriters.map((w)=>[w.writerKey,w]));
const results = [
  check("schema has advanced to Build 12", () => assert(manifest.schemaBuild >= 12, `schemaBuild=${manifest.schemaBuild}`)),
  check("R4 authority writer remains declared", () => { const w=writers.get("marketroute.r4.commercial-reality"); assert(w?.authorityStage === "COMMERCIAL_REALITY", "R4 writer missing"); }),
  check("R5 relationship graph writer is declared", () => { const w=writers.get("marketroute.r5.relationship-graph"); assert(w?.authorityStage === "ROUTE_AUTHORITY", "R5 writer missing"); }),
  check("R6 contact authority writer is declared", () => { const w=writers.get("marketroute.r6.contact-truth"); assert(w?.authorityStage === "CONTACT_AUTHORITY", "R6 writer missing"); }),
  check("only R4, R5 and R6 authority writers exist", () => assert(manifest.authorityWriters.length === 3, `writers=${manifest.authorityWriters.length}`)),
  check("numeric authority remains forbidden", () => { for(const w of manifest.authorityWriters) assert(w.numericAuthority === false, `${w.writerKey} numeric`); }),
  check("database recomputes decisions and fingerprints", () => { for(const w of manifest.authorityWriters) assert(w.databaseRecomputesDecision === true && w.databaseRecomputesFingerprint === true, w.writerKey); }),
  check("execution permission remains future-only", () => assert(manifest.declaredFutureAuthorityStages.includes("execution-permission"), "future stage mismatch")),
  check("UI authority reconstruction forbidden", () => assert(manifest.rules.uiMayNotConstructAuthority === true, "UI rule missing")),
  check("workflow and authority separated", () => assert(manifest.rules.workflowStateIsNotAuthorityState === true, "state separation missing")),
  check("legacy runtime dependency forbidden", () => assert(manifest.rules.legacyRuntimeDependencies === false, "legacy rule missing")),
  check("direct authority DML forbidden", () => assert(manifest.rules.directAuthorityDmlForbidden === true, "DML rule missing")),
];
results.push(check("only declared authority implementations exist", () => {
  const files=sourceFiles().filter((f)=>relative(f).startsWith("core/authority/") && !relative(f).endsWith("README.md")).map(relative).sort();
  assert(JSON.stringify(files)===JSON.stringify(["core/authority/commercial-reality.ts","core/authority/contact-authority.ts","core/authority/lifecycle.ts","core/authority/route-authority.ts"]), `unexpected authority files: ${files.join(", ")}`);
  assert(!files.filter((f)=>f.endsWith("lifecycle.ts")).some(()=>manifest.authorityWriters.some((w)=>w.coreModule==="core/authority/lifecycle")), "derived lifecycle must not be an authority writer");
}));
results.push(check("Build 2 migration foundation 0001-0005 remains intact", () => {
  const sql=fs.readdirSync(path.join(ROOT,"supabase/migrations")).filter((n)=>n.endsWith(".sql")).sort();
  const foundation=sql.filter((n)=>/^000[1-5]_/.test(n)); assert(foundation.length===5, `foundation changed: ${foundation.join(",")}`);
}));
printResults("MarketRoute V2 Build 12 — authority manifest", results);
