import fs from "node:fs";
import path from "node:path";

const root = path.resolve(import.meta.dirname, "../..");
const economics = fs.readFileSync(path.join(root, "core/ai/semantic-economics.ts"), "utf8");
const marginProof = fs.readFileSync(path.join(root, "application/ai/semantic-margin-proof.ts"), "utf8");
const pricing = fs.readFileSync(path.join(root, "platform/ai/bedrock/bedrock-semantic-pricing.ts"), "utf8");

const failures = [];
const assert = (value, message) => { if (!value) throw new Error(message); };
const check = (name, fn) => {
  try { fn(); console.log(`PASS  ${name}`); }
  catch (error) { failures.push(name); console.error(`FAIL  ${name}: ${error instanceof Error ? error.message : String(error)}`); }
};

console.log("\nAWS V0 Build 7.8 — adversarial semantic economics boundary");

check("credits cannot erase economic cost", () => {
  assert(economics.includes("input.economicCostUsd / input.operationCount"), "cost per operation is not based on economic cost");
  assert(economics.includes("input.economicCostUsd / input.revenueUsd"), "COGS ratio is not based on economic cost");
  assert(!economics.includes("creditFunding ==="), "economic projection branches on credit funding");
  assert(!marginProof.includes("creditFunding ==="), "margin proof branches on credit funding to alter cost");
});

check("cash cost remains a separate accounting field", () => {
  assert(economics.includes("cashCostUsd: number | null"), "cash cost field missing");
  assert(marginProof.includes("event.actualAttributedCostUsd !== null"), "actual attributed cash cost is not tracked");
  assert(marginProof.includes("completeCashCoverage ? cashCostUsd : null"), "partial cash coverage may be presented as complete");
});

check("unknown token economics cannot silently understate projection", () => {
  assert(marginProof.includes("unpricedOperationCount"), "unpriced operation count missing");
  assert(marginProof.includes("completeEconomicCoverage = pricedOperationCount === totalOperationCount"), "complete economic coverage check missing");
  assert(marginProof.includes("projection = completeEconomicCoverage"), "projection is not fail-closed on incomplete economic coverage");
});

check("mature COGS target is explicit and bounded", () => {
  assert(economics.includes("MATURE_SEMANTIC_COGS_TARGET_MIN = 0.2"), "20% target floor missing");
  assert(economics.includes("MATURE_SEMANTIC_COGS_TARGET_MAX = 0.3"), "30% target ceiling missing");
  assert(economics.includes('return "ABOVE_TARGET"'), "above-target state missing");
});

check("pricing is explicit rather than inferred from credits", () => {
  assert(pricing.includes("3.3"), "input price missing");
  assert(pricing.includes("16.5"), "output price missing");
  assert(pricing.includes("AWS_EU_GEO_CROSS_REGION_PUBLIC_PRICE"), "pricing basis missing");
  assert(!pricing.toLowerCase().includes("credit"), "provider pricing is contaminated by credit funding");
});

check("economics layer has no persistence or billing authority", () => {
  const combined = [economics, marginProof, pricing].join("\n").toLowerCase();
  for (const forbidden of [
    "insert into",
    "update ",
    "delete from",
    "rds-data",
    "supabase",
    "stripe",
    "charge(",
    "invoice",
  ]) {
    assert(!combined.includes(forbidden), `forbidden persistence/billing capability: ${forbidden}`);
  }
});

if (failures.length) process.exitCode = 1;
else console.log("\nPASS  Build 7.8 adversarial semantic economics boundary");
