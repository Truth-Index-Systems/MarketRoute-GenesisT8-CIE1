import fs from "node:fs";
import path from "node:path";
import { ROOT, assert, check, printResults, readJson, importDecision, sourceFiles, relative } from "../../scripts/lib/constitution.mjs";

const rules = readJson("constitution/layer-rules.json");
const manifest = readJson("constitution/authority-manifest.json");
const appPage = fs.readFileSync(path.join(ROOT, "app/app/page.tsx"), "utf8");
const home = fs.readFileSync(path.join(ROOT, "app/page.tsx"), "utf8");
const css = fs.readFileSync(path.join(ROOT, "app/globals.css"), "utf8");
const navigation = fs.readFileSync(path.join(ROOT, "ui/shell/navigation.ts"), "utf8");
const results = [];

const importAttacks = [
  ["ui/attack.tsx", "@/platform/database/postgrest-rpc", false],
  ["ui/attack.tsx", "@/platform/ai/research-provider", false],
  ["ui/attack.tsx", "@/core/authority/lifecycle", false],
  ["ui/attack.tsx", "@/application/read-model/contracts", true],
  ["ui/attack.tsx", "@/ui/primitives/panel", true],
  ["app/attack.tsx", "@/platform/database/application-read-repository", false],
  ["app/attack.tsx", "@/core/truth/engine", false],
  ["app/attack.tsx", "@/application/read-model/service", true],
  ["app/attack.tsx", "@/ui/shell/app-shell", true],
];
for (const [source, target, expected] of importAttacks) {
  results.push(check(`${source} ${expected ? "may" : "may not"} import ${target}`, () => {
    const decision = importDecision(source, target, rules);
    assert(decision.allowed === expected, `${decision.allowed}:${decision.reason}`);
  }));
}

const presentationFiles = sourceFiles().filter((file) => {
  const rel = relative(file);
  return rel.startsWith("ui/") || rel.startsWith("app/");
});
results.push(check("UI cannot call Supabase RPC directly", () => {
  for (const file of presentationFiles) {
    const text = fs.readFileSync(file, "utf8");
    assert(!/\.rpc\s*\(/.test(text) && !/\.from\s*\(/.test(text), relative(file));
  }
}));
results.push(check("UI cannot read service-role environment", () => {
  for (const file of presentationFiles) {
    const text = fs.readFileSync(file, "utf8");
    assert(!text.includes("SUPABASE_SERVICE_ROLE_KEY") && !text.includes("process.env"), relative(file));
  }
}));
results.push(check("UI cannot use legacy commercial score vocabulary", () => {
  const forbidden = ["opportunity_score", "route_quality", "route_confidence", "is_viable", "fit_breakdown", "overall_confidence"];
  const combined = presentationFiles.map((file) => fs.readFileSync(file, "utf8").toLowerCase()).join("\n");
  for (const term of forbidden) assert(!combined.includes(term), term);
}));
results.push(check("UI contains no numeric authority threshold", () => {
  const combined = presentationFiles.map((file) => fs.readFileSync(file, "utf8")).join("\n");
  assert(!/if\s*\([^)]*(?:authority|r4|r5|r6)[^)]*[<>]=?\s*\d/i.test(combined), "numeric authority branch");
}));
results.push(check("preview is explicit or canonical live successor is active", () => assert(appPage.includes("Non-authoritative sample data") || manifest.presentationBuild >= 15, "presentation state")));
results.push(check("public copy says what product does", () => assert((home.includes("researches your market") && home.includes("qualifies commercial reality") && home.includes("maps evidence-backed routes")) || (home.includes("Tell me what you sell") && home.includes("researches the market") && home.includes("routes into them")), "purpose")));
results.push(check("future product routes remain disabled only before Build 15", () => { if (manifest.presentationBuild < 15) assert((navigation.match(/enabled: false/g) ?? []).length >= 5, "future nav"); else assert(!navigation.includes("enabled: false"), "Build 15 nav"); }));
results.push(check("primary MarketRoute blue cannot drift", () => assert(css.toLowerCase().includes("#2f8cff") && css.toLowerCase().includes("#76b6ff"), "brand blues")));
results.push(check("Build 14 adds no authority writer", () => assert(manifest.authorityWriters.length === 3, `writers=${manifest.authorityWriters.length}`)));
results.push(check("execution permission remains future authority stage", () => assert(manifest.declaredFutureAuthorityStages.includes("execution-permission"), "future execution")));
results.push(check("presentation-only rule is constitutional", () => assert(manifest.rules.designSystemIsPresentationOnly === true && manifest.rules.uiShellMayNotCreateAuthority === true, "manifest")));
results.push(check("preview-data rule is constitutional", () => assert(manifest.rules.uiPreviewDataMustBeExplicitlyNonAuthoritative === true, "preview rule")));
results.push(check("/app namespace rule is constitutional", () => assert(manifest.rules.productRoutesNamespacedUnderApp === true, "app namespace")));
results.push(check("public acquisition route is reserved", () => assert(manifest.rules.publicRootReservedForAcquisitionExperience === true, "public root")));

printResults("MarketRoute V2 Build 14 — presentation-boundary adversarial gate", results);
