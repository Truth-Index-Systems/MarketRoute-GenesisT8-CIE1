import fs from "node:fs";
import path from "node:path";
import { ROOT, assert, check, printResults } from "./lib/constitution.mjs";

const home = fs.readFileSync(path.join(ROOT, "app/page.tsx"), "utf8");
const preview = fs.readFileSync(path.join(ROOT, "app/preview/page.tsx"), "utf8");
const css = fs.readFileSync(path.join(ROOT, "app/globals.css"), "utf8");
const layout = fs.readFileSync(path.join(ROOT, "app/layout.tsx"), "utf8");
const results = [];


results.push(check("Build 16 presentation marker is active", () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(ROOT, "constitution/authority-manifest.json"), "utf8"));
  assert(manifest.presentationBuild >= 16 && manifest.schemaBuild === 15, `${manifest.presentationBuild}/${manifest.schemaBuild}`);
  assert(manifest.rules.publicWebsiteIsPresentationOnly && manifest.rules.publicAcquisitionValueFirst, "Build 16 rules");
}));

results.push(check("Build 16 homepage makes the product obvious", () => {
  for (const phrase of ["Know who to target", "MarketRoute researches your market", "worth pursuing", "evidence-backed routes to the right buyer"]) assert(home.includes(phrase), phrase);
}));
results.push(check("Build 16 homepage includes required product story", () => {
  for (const id of ['id="how-it-works"', 'id="intelligence"', 'id="example"', 'id="genesis"']) assert(home.includes(id), id);
}));
results.push(check("Build 16 covers Company Truth, Commercial Reality, Relationship Route and Contact readiness", () => {
  for (const phrase of ["Company truth", "Commercial reality", "Relationship route", "Contact readiness"]) assert(home.includes(phrase), phrase);
}));
results.push(check("Build 16 acquisition remains value-first", () => {
  assert(home.includes('href="/preview"'), "homepage preview link");
  assert(!home.includes('href="/signup"'), "signup must not precede public value");
  assert(preview.includes('href="/signup"'), "signup follows walkthrough");
}));
results.push(check("Build 16 keeps sign-in available but secondary", () => {
  assert(home.includes('href="/login"'), "login link");
  assert(home.includes("mr-site-nav__signin"), "secondary sign-in treatment");
}));
results.push(check("Build 16 uses MarketRoute light/navy/blue visual identity", () => {
  for (const token of ["mr-site", "#fbfcfd", "#2f8cff", "#081d34", "linear-gradient"]) assert(css.includes(token), token);
}));
results.push(check("Build 16 public site is responsive", () => {
  for (const breakpoint of ["@media (max-width: 1240px)", "@media (max-width: 900px)", "@media (max-width: 700px)"]) assert(css.includes(breakpoint), breakpoint);
}));
results.push(check("Build 16 metadata is commercially explicit", () => {
  assert(layout.includes("Know who to target, why, and how to reach them"), "title");
  assert(layout.includes("turning market research into actionable B2B opportunities"), "description");
}));
results.push(check("Build 16 does not import authority implementation", () => {
  for (const forbidden of ["core/authority", "platform/database", "application/read-model", "application/opportunities"]) assert(!home.includes(forbidden), forbidden);
}));
results.push(check("Build 16 has no new SQL migration", () => {
  const files = fs.readdirSync(ROOT).filter((name) => /BUILD16.*\.sql$/i.test(name));
  assert(files.length === 0, files.join(","));
}));

printResults("MarketRoute V2 Build 16 — public website static gate", results);
