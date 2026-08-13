import fs from "node:fs";
import path from "node:path";
import { ROOT, assert, check, printResults, readJson, sourceFiles, relative } from "./lib/constitution.mjs";

const manifest = readJson("constitution/authority-manifest.json");
const pkg = readJson("package.json");
const css = fs.readFileSync(path.join(ROOT, "app/globals.css"), "utf8");
const home = fs.readFileSync(path.join(ROOT, "app/page.tsx"), "utf8");
const appPage = fs.readFileSync(path.join(ROOT, "app/app/page.tsx"), "utf8");
const appLayout = fs.readFileSync(path.join(ROOT, "app/app/layout.tsx"), "utf8");
const shell = fs.readFileSync(path.join(ROOT, "ui/shell/app-shell.tsx"), "utf8");
const results = [];

results.push(check("Build 14 remains presentation-only", () => assert(manifest.authorityWriters.length === 3, `writers=${manifest.authorityWriters.length}`)));
results.push(check("presentation build marker is 14", () => assert(manifest.presentationBuild === 14, `presentationBuild=${manifest.presentationBuild}`)));
results.push(check("package version advanced to 0.14.0", () => assert(pkg.version === "0.14.0", pkg.version)));
results.push(check("Build 14 validators wired", () => assert(pkg.scripts["constitution:ui"] && pkg.scripts["constitution:ui-adversarial"], "scripts")));
results.push(check("no Build 14 database migration introduced", () => {
  const migrations = fs.readdirSync(path.join(ROOT, "supabase/migrations")).filter((name) => /^\d{4}_.*\.sql$/.test(name)).sort();
  assert(migrations.at(-1)?.startsWith("0016_"), `latest=${migrations.at(-1)}`);
}));

for (const required of [
  "ui/brand/marketroute-logo.tsx",
  "ui/icons.tsx",
  "ui/shell/app-shell.tsx",
  "ui/shell/navigation.ts",
  "ui/primitives/panel.tsx",
  "ui/primitives/status-badge.tsx",
  "ui/primitives/metric-card.tsx",
  "ui/primitives/button.tsx",
  "ui/intelligence/truth-gauge.tsx",
  "ui/intelligence/authority-stack.tsx",
  "ui/intelligence/route-path.tsx",
  "ui/intelligence/research-pressure.tsx",
  "ui/intelligence/provenance-trail.tsx",
  "app/app/layout.tsx",
  "app/app/page.tsx",
  "app/design-system/page.tsx",
]) {
  results.push(check(`design-system file exists: ${required}`, () => assert(fs.existsSync(path.join(ROOT, required)), required)));
}

results.push(check("MarketRoute primary blue token preserved", () => assert(css.toLowerCase().includes("--mr-blue-500: #2f8cff"), "#2F8CFF")));
results.push(check("MarketRoute soft blue token preserved", () => assert(css.toLowerCase().includes("--mr-blue-400: #76b6ff"), "#76B6FF")));
results.push(check("near-black workspace token explicit", () => assert(css.toLowerCase().includes("--mr-bg: #05080d"), "#05080D")));
results.push(check("product shell is namespaced under /app", () => assert(appLayout.includes("<AppShell>") && fs.existsSync(path.join(ROOT, "app/app/page.tsx")), "/app shell")));
results.push(check("public root explains MarketRoute purpose", () => assert(home.includes("Know who to target") && home.includes("researches your market") && home.includes("evidence-backed routes"), "purpose copy")));
results.push(check("preview is explicitly non-authoritative", () => assert(appPage.includes("Non-authoritative sample data") && appPage.includes("Design system preview"), "preview label")));
results.push(check("app shell labels future Build 15 routes", () => assert(shell.includes("Build 15") && shell.includes("aria-disabled"), "future route state")));
results.push(check("responsive application shell present", () => assert(css.includes("@media (max-width: 820px)") && css.includes(".mr-mobile-nav"), "responsive shell")));
results.push(check("small-mobile layout present", () => assert(css.includes("@media (max-width: 390px)"), "small mobile")));
results.push(check("reduced-motion accessibility present", () => assert(css.includes("prefers-reduced-motion"), "reduced motion")));
results.push(check("keyboard focus treatment present", () => assert(css.includes(":focus-visible"), "focus-visible")));
results.push(check("Truth gauge says epistemic not probability", () => assert(appPage.includes("Epistemic quality, not probability."), "truth language")));
results.push(check("route preview states structural provenance", () => assert(appPage.includes("Every edge is structural or Truth-qualified"), "route provenance")));
results.push(check("human review stays downstream", () => assert(appPage.includes("founder review required") && appPage.includes("Send gate re-checks R4 → R5 → R6"), "workflow language")));

const presentationFiles = sourceFiles().filter((file) => {
  const rel = relative(file);
  return rel.startsWith("ui/") || rel.startsWith("app/");
});
results.push(check("presentation source has no direct database or provider imports", () => {
  for (const file of presentationFiles) {
    const text = fs.readFileSync(file, "utf8");
    assert(!text.includes("platform/database") && !text.includes("platform/ai") && !text.includes("@supabase"), relative(file));
  }
}));
results.push(check("Build 14 preview does not call application read service yet", () => {
  assert(!appPage.includes("ApplicationReadService") && !appPage.includes("application/read-model/service"), "Build 15 boundary");
}));

printResults("MarketRoute V2 Build 14 — design system + application shell static gate", results);
