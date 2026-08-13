import fs from "node:fs";
import path from "node:path";
import { ROOT, assert, check, importDecision, importsFromText, printResults, readJson, relative, sourceFiles, topLayer } from "./lib/constitution.mjs";

const rules = readJson("constitution/layer-rules.json");
const results = [];

for (const required of ["core", "platform", "application", "ui", "app", "constitution"]) {
  results.push(check(`required layer exists: ${required}`, () => assert(fs.existsSync(path.join(ROOT, required)), `${required} missing`)));
}

for (const file of sourceFiles()) {
  const rel = relative(file);
  const sourceLayer = topLayer(rel);
  if (!sourceLayer) continue;
  const text = fs.readFileSync(file, "utf8");
  for (const specifier of importsFromText(text)) {
    const decision = importDecision(rel, specifier, rules);
    if (!decision.internal) continue;
    results.push(check(`${rel} may import ${specifier}`, () => {
      assert(decision.allowed, `${rel}: ${decision.reason}`);
    }));
  }
}

results.push(check("core is framework independent", () => {
  for (const file of sourceFiles().filter((f) => relative(f).startsWith("core/"))) {
    const text = fs.readFileSync(file, "utf8");
    for (const forbidden of ["next/", "react", "@supabase", "openai"]) {
      assert(!text.includes(`from \"${forbidden}`) && !text.includes(`from '${forbidden}`), `${relative(file)} imports ${forbidden}`);
    }
  }
}));

printResults("MarketRoute V2 Build 1 — architecture boundary", results);
