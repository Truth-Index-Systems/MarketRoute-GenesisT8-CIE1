import fs from "node:fs";
import path from "node:path";
import { ROOT, assert, check, printResults } from "../../scripts/lib/constitution.mjs";

const home = fs.readFileSync(path.join(ROOT, "app/page.tsx"), "utf8");
const lower = home.toLowerCase();
const results = [];

results.push(check("public website does not lead with architecture jargon", () => {
  const hero = home.slice(0, home.indexOf("mr-site-proofbar"));
  for (const phrase of ["deterministic commercial graph calculus", "multidimensional", "udosib", "constitutional authority"]) assert(!hero.toLowerCase().includes(phrase), phrase);
}));
results.push(check("public website never claims a score creates opportunity authority", () => {
  assert(!/score\s*(?:>=|>)\s*\d/i.test(home), "numeric score threshold language");
  assert(!/score\s+(?:creates|grants|authorises|authorizes)\s+(?:an\s+)?opportunity/i.test(home), "score authority claim");
  assert(home.includes("not because a score crossed a line"), "explicit anti-score explanation");
}));
results.push(check("example data is visibly identified as example", () => {
  assert(lower.includes("example view") && lower.includes("example outcome"), "example labels");
}));
results.push(check("homepage cannot bypass walkthrough directly into signup", () => {
  assert(!/href=["']\/signup["']/.test(home), "direct signup link");
}));
results.push(check("marketing page contains no browser database or secret access", () => {
  for (const term of ["process.env", "SUPABASE_SERVICE_ROLE_KEY", ".rpc(", "/rest/v1/"]) assert(!home.includes(term), term);
}));
results.push(check("marketing claims preserve evidence uncertainty", () => {
  for (const phrase of ["unknowns visible", "stale", "contradicted", "evidence"]) assert(lower.includes(phrase), phrase);
}));
results.push(check("AI remains supporting language, not the product promise", () => {
  const firstHeading = home.match(/<h1>[\s\S]*?<\/h1>/)?.[0]?.toLowerCase() ?? "";
  assert(!firstHeading.includes("ai"), "AI in hero heading");
}));

printResults("MarketRoute V2 Build 16 — public website adversarial gate", results);
