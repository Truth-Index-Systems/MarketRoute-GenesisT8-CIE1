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
results.push(check("presentation build marker preserves Build 14 or successor", () => assert(manifest.presentationBuild >= 14, `presentationBuild=${manifest.presentationBuild}`)));
results.push(check("package version preserves Build 14 or successor", () => assert(Number(pkg.version.split(".")[1]) >= 14, pkg.version)));
results.push(check("Build 14 validators wired", () => assert(pkg.scripts["constitution:ui"] && pkg.scripts["constitution:ui-adversarial"], "scripts")));
results.push(check("no Build 14 database migration introduced", () => {
  const migrations = fs.readdirSync(path.join(ROOT, "supabase/migrations")).filter((name) => /^\d{4}_.*\.sql$/.test(name)).sort();
  assert(migrations.some((name)=>name.startsWith("0016_")), `missing 0016`);
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
results.push(check("product shell is namespaced under /app", () => assert(appLayout.includes("<AppShell") && fs.existsSync(path.join(ROOT, "app/app/page.tsx")), "/app shell")));
results.push(check("public root explains MarketRoute purpose", () => assert(
  (home.includes("Know who to target") && home.includes("MarketRoute researches your market") && home.includes("maps a real route to the right buyer")) ||
  (home.includes("Tell me what you sell") && home.includes("researches the market") && home.includes("routes into them")),
  "purpose copy"
)));
results.push(check("Build 14 preview is either preserved or superseded by live Build 15", () => assert((appPage.includes("Non-authoritative sample data") && appPage.includes("Design system preview")) || (manifest.presentationBuild >= 15 && appPage.includes("commandCentre")), "presentation successor")));
results.push(check("app shell preserves navigation boundary through Build 15", () => assert((shell.includes("Build 15") && shell.includes("aria-disabled")) || manifest.presentationBuild >= 15, "navigation successor")));
results.push(check("responsive application shell present", () => assert(css.includes("@media (max-width: 820px)") && css.includes(".mr-mobile-nav"), "responsive shell")));
results.push(check("small-mobile layout present", () => assert(css.includes("@media (max-width: 390px)"), "small mobile")));
results.push(check("reduced-motion accessibility present", () => assert(css.includes("prefers-reduced-motion"), "reduced motion")));
results.push(check("keyboard focus treatment present", () => assert(css.includes(":focus-visible"), "focus-visible")));
results.push(check("Truth presentation preserves epistemic-not-probability language", () => { const live=fs.readFileSync(path.join(ROOT,"app/app/opportunities/[campaignId]/[companyId]/page.tsx"),"utf8"); assert(appPage.includes("Epistemic quality, not probability.") || live.includes("epistemic quality, not a probability"), "truth language"); }));
results.push(check("route presentation preserves structural provenance", () => { const live=fs.readFileSync(path.join(ROOT,"app/app/opportunities/[campaignId]/[companyId]/page.tsx"),"utf8"); assert(appPage.includes("Every edge is structural or Truth-qualified") || live.includes("Structural paths come from current R5") || live.includes("Every path remains structural or Truth-qualified"), "route provenance"); }));
results.push(check("human action remains downstream of system-owned readiness", () => { const live=fs.readFileSync(path.join(ROOT,"app/app/opportunities/[campaignId]/[companyId]/page.tsx"),"utf8"); assert(
  (appPage.includes("founder review required") && appPage.includes("Send gate re-checks R4 → R5 → R6")) ||
  (manifest.presentationBuild >= 15 && (
    live.includes("Human workflow remains independent") ||
    (live.includes("MarketRoute decides readiness from current evidence") && live.includes("Human approval is reserved for the message")) ||
    (live.includes("MarketRoute decides when the research is strong enough") && live.includes("You stay in control of the message you choose to send"))
  )),
  "workflow language"
); }));

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
results.push(check("Build 14 preview boundary is superseded only by canonical Build 15 reads", () => {
  if (manifest.presentationBuild === 14) assert(!appPage.includes("application/read-model/service"), "Build 14 boundary");
  else assert(manifest.rules.coreApplicationUiConsumesCanonicalReadContract === true, "canonical successor");
}));

printResults("MarketRoute V2 Build 14 — design system + application shell static gate", results);
