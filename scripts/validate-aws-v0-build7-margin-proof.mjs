import fs from "node:fs";

const economics = fs.readFileSync("core/ai/semantic-economics.ts", "utf8");
const marginProof = fs.readFileSync("application/ai/semantic-margin-proof.ts", "utf8");
const pricing = fs.readFileSync("platform/ai/bedrock/bedrock-semantic-pricing.ts", "utf8");
const probe = fs.readFileSync("application/aws-v0/shadow-ai-semantic-probe.ts", "utf8");
const workflow = fs.readFileSync(".github/workflows/constitution.yml", "utf8");

for (const token of [
  "MATURE_SEMANTIC_COGS_TARGET_MIN = 0.2",
  "MATURE_SEMANTIC_COGS_TARGET_MAX = 0.3",
  "costPerOperationUsd",
  "costPer100Usd",
  "costPer1000Usd",
  "cogsRatio",
  "grossMarginRatio",
  "economicCostUsd",
  "cashCostUsd",
  "creditFundingCounts",
  "estimateSemanticTokenCostUsd",
  "projectSemanticEconomics",
]) {
  if (!economics.includes(token)) throw new Error(`Build 7.8 semantic economics missing: ${token}`);
}

for (const token of [
  "SONNET45_EU_GEO_INPUT_USD_PER_MILLION_TOKENS = 3.3",
  "SONNET45_EU_GEO_OUTPUT_USD_PER_MILLION_TOKENS = 16.5",
  'pricingBasis: "AWS_EU_GEO_CROSS_REGION_PUBLIC_PRICE"',
]) {
  if (!pricing.includes(token)) throw new Error(`Build 7.8 Bedrock pricing basis missing: ${token}`);
}

for (const token of [
  "buildSemanticMarginProof",
  "completeEconomicCoverage",
  "completeCashCoverage",
  "unpricedOperationCount",
  "cashAttributedOperationCount",
  "event.estimatedEquivalentCostUsd",
  "event.actualAttributedCostUsd",
  "fundingCounts[event.creditFunding] += 1",
  "projection = completeEconomicCoverage",
]) {
  if (!marginProof.includes(token)) throw new Error(`Build 7.8 margin proof missing: ${token}`);
}

if (!probe.includes("estimateSemanticTokenCostUsd")) throw new Error("Build 7.8 shadow probe does not use shared economic estimator");
if (!probe.includes("SONNET45_EU_GEO_PRICING")) throw new Error("Build 7.8 shadow probe does not use frozen Bedrock pricing basis");

if (!workflow.includes("node scripts/validate-aws-v0-build7-margin-proof.mjs")) {
  throw new Error("Build 7.8 validator missing from constitutional CI");
}
if (!workflow.includes("node tests/adversarial/aws-v0-build7-margin-proof.mjs")) {
  throw new Error("Build 7.8 adversarial gate missing from constitutional CI");
}

console.log("PASS AWS V0 Build 7.8 semantic margin/economic proof contract");
