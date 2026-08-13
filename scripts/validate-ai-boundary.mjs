import fs from "node:fs";
import { assert, check, printResults, readJson, relative, sourceFiles } from "./lib/constitution.mjs";

const contract = readJson("constitution/ai-boundary.json");
const results = [
  check("AI contract has explicit permitted capabilities", () => assert(contract.aiMay.length >= 5, "aiMay incomplete")),
  check("AI contract has explicit forbidden authority capabilities", () => assert(contract.aiMayNot.length >= 6, "aiMayNot incomplete")),
  check("AI cannot grant commercial viability", () => assert(contract.aiMayNot.includes("decide_commercial_viability"), "commercial viability missing")),
  check("AI cannot grant route authority", () => assert(contract.aiMayNot.includes("grant_route_authority"), "route authority missing")),
  check("AI cannot grant contact authority", () => assert(contract.aiMayNot.includes("grant_contact_authority"), "contact authority missing")),
  check("AI cannot grant execution permission", () => assert(contract.aiMayNot.includes("grant_execution_permission"), "execution permission missing")),
];

results.push(check("core authority has no AI transport dependency", () => {
  for (const file of sourceFiles().filter((f) => relative(f).startsWith("core/authority/"))) {
    const text = fs.readFileSync(file, "utf8");
    for (const token of ["platform/ai", "openai", "chat.completions", "responses.create"]) {
      assert(!text.toLowerCase().includes(token.toLowerCase()), `${relative(file)} contains ${token}`);
    }
  }
}));

printResults("MarketRoute V2 Build 1 — AI boundary", results);
