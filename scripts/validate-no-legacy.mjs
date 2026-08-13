import fs from "node:fs";
import path from "node:path";
import { ROOT, assert, check, printResults, relative, sourceFiles, walk } from "./lib/constitution.mjs";

const forbiddenDirectories = ["legacy", "compatibility", "genesis-g4", "genesis-g5", "genesis-g8", "salespilot"];
const forbiddenRuntimeTokens = [
  "opportunity_score",
  "route_quality",
  "route_confidence",
  "is_viable",
  "review_salespilot_opportunity_scoped",
  "opportunity_overview",
  "opportunity_detail",
];
const results = [];

results.push(check("no forbidden legacy directory exists", () => {
  for (const file of walk()) {
    const parts = relative(file).toLowerCase().split("/");
    for (const dir of forbiddenDirectories) assert(!parts.includes(dir), `forbidden directory ${dir}: ${relative(file)}`);
  }
}));

results.push(check("runtime source contains no V1 authority token", () => {
  const runtimeRoots = ["app/", "core/", "platform/", "application/", "ui/"];
  for (const file of sourceFiles().filter((f) => runtimeRoots.some((r) => relative(f).startsWith(r)))) {
    const text = fs.readFileSync(file, "utf8").toLowerCase();
    for (const token of forbiddenRuntimeTokens) assert(!text.includes(token), `${relative(file)} contains legacy token ${token}`);
  }
}));

results.push(check("package name is V2, not Genesis/SalesPilot", () => {
  const pkg = JSON.parse(fs.readFileSync(path.join(ROOT, "package.json"), "utf8"));
  assert(pkg.name === "marketroute-v2", `unexpected package name ${pkg.name}`);
}));

printResults("MarketRoute V2 Build 1 — legacy quarantine", results);
