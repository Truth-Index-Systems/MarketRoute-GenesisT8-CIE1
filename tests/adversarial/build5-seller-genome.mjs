import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";

const root = path.resolve(import.meta.dirname, "../..");
const temp = fs.mkdtempSync(path.join(os.tmpdir(), "mrv2-build5-seller-"));
try {
  execFileSync("tsc", [
    "core/evidence/contracts.ts", "core/evidence/canonical.ts", "core/evidence/index.ts",
    "core/seller-genome/contracts.ts", "core/seller-genome/canonical.ts", "core/seller-genome/index.ts",
    "platform/ai/seller-genome-extractor.ts",
    "--target", "ES2022", "--module", "NodeNext", "--moduleResolution", "NodeNext", "--outDir", temp,
    "--strict", "--skipLibCheck", "--lib", "ES2022,DOM,DOM.Iterable",
  ], { cwd: root, stdio: "pipe" });

  const genome = await import(pathToFileURL(path.join(temp, "core/seller-genome/canonical.js")).href + `?v=${Date.now()}`);
  const ai = await import(pathToFileURL(path.join(temp, "platform/ai/seller-genome-extractor.js")).href + `?v=${Date.now()}`);
  const contracts = await import(pathToFileURL(path.join(temp, "core/seller-genome/contracts.js")).href + `?v=${Date.now()}`);
  const tests = [];
  const test = (name, fn) => tests.push({ name, fn });
  const sellerId = "11111111-1111-1111-1111-111111111111";

  const complete = () => ({
    offerings: { state: "DECLARED", items: [{ offeringKey: "Custom Software", label: "Custom software", description: "We build bespoke applications.", problemCodes: ["manual_workflows"], outcomeCodes: ["automation"], deliveryModeCodes: ["project"] }] },
    capabilities: { state: "DECLARED", items: [{ capabilityKey: "full_stack_engineering", label: "Full-stack engineering" }] },
    commercialObjectives: { state: "DECLARED", items: [{ objectiveKey: "new_customers", objectiveType: "ACQUIRE_CUSTOMERS", statement: "Win more software projects.", offeringKeys: ["custom_software"], desiredActionCode: "book_discovery_call", outcomeCodes: ["new_revenue"] }] },
    delivery: { state: "DECLARED", modeCodes: ["remote", "project"] },
    serviceGeography: { state: "DECLARED", countryCodes: ["gb"], regionCodes: ["uk_wide"] },
    targetCharacteristics: { state: "DECLARED", industryCodes: ["professional_services"], companySizeBands: ["smb"], businessModelCodes: ["b2b"] },
    buyerAssumptions: { state: "DECLARED", roleCodes: ["founder", "operations_director"], departmentCodes: ["operations"], painCodes: ["manual_workflows"] },
    constraints: { state: "DECLARED", items: [{ constraintKey: "uk_only", constraintType: "geography", mode: "HARD", valueCodes: ["gb"], statement: "Serve UK customers only." }] },
  });

  test("complete genome canonicalises", () => {
    const result = genome.canonicaliseSellerGenome(sellerId, "Truth Index Systems", complete());
    assert.equal(result.semanticCompleteness, "COMPLETE");
    assert.deepEqual(result.missingDimensions, []);
  });
  test("codes are normalised and countries uppercased", () => {
    const result = genome.canonicaliseSellerGenome(sellerId, "Truth Index Systems", complete());
    assert.equal(result.semantic.offerings.items[0].offeringKey, "custom_software");
    assert.deepEqual(result.semantic.serviceGeography.countryCodes, ["GB"]);
  });
  test("array order does not change semantic identity", () => {
    const a = complete();
    const b = complete();
    b.delivery.modeCodes = ["project", "remote"];
    b.buyerAssumptions.roleCodes = ["operations_director", "founder"];
    const ca = genome.canonicaliseSellerGenome(sellerId, "Truth Index Systems", a);
    const cb = genome.canonicaliseSellerGenome(sellerId, "Truth Index Systems", b);
    assert.equal(genome.sellerGenomeSemanticIdentity(ca), genome.sellerGenomeSemanticIdentity(cb));
  });
  test("explanatory paraphrase does not change semantic identity", () => {
    const a = complete(); const b = complete();
    b.offerings.items[0].label = "Bespoke application engineering";
    b.offerings.items[0].description = "Purpose-built software for operational problems.";
    b.commercialObjectives.items[0].statement = "Acquire organisations that need custom applications.";
    const ca = genome.canonicaliseSellerGenome(sellerId, "Truth Index Systems", a);
    const cb = genome.canonicaliseSellerGenome(sellerId, "Truth Index Systems", b);
    assert.equal(genome.sellerGenomeSemanticIdentity(ca), genome.sellerGenomeSemanticIdentity(cb));
    assert.notDeepEqual(ca.explanatory, cb.explanatory);
  });
  test("semantic change changes semantic identity", () => {
    const a = complete(); const b = complete();
    b.commercialObjectives.items[0].desiredActionCode = "request_proposal";
    const ca = genome.canonicaliseSellerGenome(sellerId, "Truth Index Systems", a);
    const cb = genome.canonicaliseSellerGenome(sellerId, "Truth Index Systems", b);
    assert.notEqual(genome.sellerGenomeSemanticIdentity(ca), genome.sellerGenomeSemanticIdentity(cb));
  });
  test("unknown dimension is explicit and makes genome partial", () => {
    const c = complete(); c.buyerAssumptions = { state: "UNKNOWN", roleCodes: [], departmentCodes: [], painCodes: [] };
    const result = genome.canonicaliseSellerGenome(sellerId, "Truth Index Systems", c);
    assert.equal(result.semanticCompleteness, "PARTIAL");
    assert.deepEqual(result.missingDimensions, ["buyerAssumptions"]);
    assert.equal(result.explicitUnknowns[0].dimension, "buyerAssumptions");
  });
  test("explicit none is distinct from unknown", () => {
    const c = complete(); c.constraints = { state: "EXPLICIT_NONE", items: [] };
    const result = genome.canonicaliseSellerGenome(sellerId, "Truth Index Systems", c);
    assert.equal(result.semantic.constraints.state, "EXPLICIT_NONE");
    assert.equal(result.missingDimensions.includes("constraints"), false);
  });
  test("declared offerings cannot be empty", () => {
    const c = complete(); c.offerings.items = [];
    assert.throws(() => genome.canonicaliseSellerGenome(sellerId, "Truth Index Systems", c), /DECLARED_EMPTY:offerings/);
  });
  test("unknown offerings cannot contain items", () => {
    const c = complete(); c.offerings.state = "UNKNOWN";
    assert.throws(() => genome.canonicaliseSellerGenome(sellerId, "Truth Index Systems", c), /NONDECLARED_HAS_ITEMS:offerings/);
  });
  test("declared delivery requires a delivery mode", () => {
    const c = complete(); c.delivery.modeCodes = [];
    assert.throws(() => genome.canonicaliseSellerGenome(sellerId, "Truth Index Systems", c), /DECLARED_EMPTY:delivery/);
  });
  test("unknown delivery cannot smuggle delivery values", () => {
    const c = complete(); c.delivery.state = "UNKNOWN";
    assert.throws(() => genome.canonicaliseSellerGenome(sellerId, "Truth Index Systems", c), /NONDECLARED_HAS_VALUES:delivery/);
  });
  test("duplicate offering keys fail closed", () => {
    const c = complete(); c.offerings.items.push({ ...c.offerings.items[0], label: "Duplicate" });
    assert.throws(() => genome.canonicaliseSellerGenome(sellerId, "Truth Index Systems", c), /DUPLICATE_OFFERING_KEY/);
  });
  test("duplicate capability keys fail closed", () => {
    const c = complete(); c.capabilities.items.push({ ...c.capabilities.items[0], label: "Duplicate" });
    assert.throws(() => genome.canonicaliseSellerGenome(sellerId, "Truth Index Systems", c), /DUPLICATE_CAPABILITY_KEY/);
  });
  test("duplicate objective keys fail closed", () => {
    const c = complete(); c.commercialObjectives.items.push({ ...c.commercialObjectives.items[0], statement: "Duplicate" });
    assert.throws(() => genome.canonicaliseSellerGenome(sellerId, "Truth Index Systems", c), /DUPLICATE_OBJECTIVE_KEY/);
  });
  test("objective cannot reference an offering absent from the same snapshot", () => {
    const c = complete(); c.commercialObjectives.items[0].offeringKeys = ["other_service"];
    assert.throws(() => genome.canonicaliseSellerGenome(sellerId, "Truth Index Systems", c), /OBJECTIVE_UNKNOWN_OFFERING/);
  });
  test("AI numeric confidence field is forbidden", () => {
    const c = complete(); c.offerings.items[0].confidence = 0.99;
    assert.throws(() => genome.canonicaliseSellerGenome(sellerId, "Truth Index Systems", c), /FORBIDDEN_AI_FIELD/);
  });
  test("AI fit score field is forbidden even when descriptive", () => {
    const c = complete(); c.targetCharacteristics.fitScore = "high";
    assert.throws(() => genome.canonicaliseSellerGenome(sellerId, "Truth Index Systems", c), /FORBIDDEN_AI_FIELD/);
  });
  test("AI priority field is forbidden", () => {
    const c = complete(); c.commercialObjectives.items[0].priority = 1;
    assert.throws(() => genome.canonicaliseSellerGenome(sellerId, "Truth Index Systems", c), /FORBIDDEN_AI_FIELD/);
  });
  test("unknown non-authority AI field is rejected rather than silently discarded", () => {
    const c = complete(); c.offerings.items[0].mysterySemantic = "something important";
    assert.throws(() => genome.canonicaliseSellerGenome(sellerId, "Truth Index Systems", c), /UNKNOWN_FIELD/);
  });
  test("declared constraint requires machine-readable value semantics", () => {
    const c = complete(); c.constraints.items[0].valueCodes = [];
    assert.throws(() => genome.canonicaliseSellerGenome(sellerId, "Truth Index Systems", c), /CONSTRAINT_VALUE_REQUIRED/);
  });
  test("semantic extractor envelope rejects wrong contract version", () => {
    assert.throws(() => ai.validateSellerGenomeExtractionEnvelope({ contractVersion: "OLD", extractorVersion: "test", candidate: complete() }), /CONTRACT_VERSION_MISMATCH/);
  });
  test("semantic extractor envelope requires extractor version", () => {
    assert.throws(() => ai.validateSellerGenomeExtractionEnvelope({ contractVersion: contracts.SELLER_GENOME_EXTRACTION_CONTRACT_VERSION, extractorVersion: " ", candidate: complete() }), /EXTRACTOR_VERSION_REQUIRED/);
  });
  test("constraint mode is preserved categorically", () => {
    const result = genome.canonicaliseSellerGenome(sellerId, "Truth Index Systems", complete());
    assert.equal(result.semantic.constraints.items[0].mode, "HARD");
  });
  test("seller prose cannot alter semantic payload", () => {
    const a = genome.canonicaliseSellerGenome(sellerId, "Truth Index Systems", complete());
    const b = genome.canonicaliseSellerGenome(sellerId, "  Truth   Index Systems  ", complete());
    assert.deepEqual(a.semantic, b.semantic);
  });
  test("bad country code fails", () => {
    const c = complete(); c.serviceGeography.countryCodes = ["United Kingdom"];
    assert.throws(() => genome.canonicaliseSellerGenome(sellerId, "Truth Index Systems", c), /COUNTRY_CODE_INVALID/);
  });
  test("bad machine key fails", () => {
    const c = complete(); c.offerings.items[0].offeringKey = "!!!";
    assert.throws(() => genome.canonicaliseSellerGenome(sellerId, "Truth Index Systems", c), /OFFERING_KEY_INVALID/);
  });
  test("commercial objective remains semantics, not authority", () => {
    const result = genome.canonicaliseSellerGenome(sellerId, "Truth Index Systems", complete());
    const text = JSON.stringify(result).toLowerCase();
    for (const forbidden of ["commercial_candidate", "route_authority", "contact_authority", "execution_permission"]) assert.equal(text.includes(forbidden), false);
  });

  let passed = 0;
  console.log("\nMarketRoute V2 Build 5 — Seller Genome adversarial gate");
  for (const { name, fn } of tests) {
    try { await fn(); passed++; console.log(`PASS  ${name}`); }
    catch (error) { console.error(`FAIL  ${name}: ${error instanceof Error ? error.message : error}`); }
  }
  console.log(`\n${passed}/${tests.length} PASS`);
  if (passed !== tests.length) process.exitCode = 1;
} finally {
  fs.rmSync(temp, { recursive: true, force: true });
}
