import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";

const root = path.resolve(import.meta.dirname, "../..");
const temp = fs.mkdtempSync(path.join(os.tmpdir(), "mrv2-build4-truth-"));
try {
  execFileSync("tsc", [
    "core/evidence/contracts.ts",
    "core/evidence/canonical.ts",
    "core/evidence/index.ts",
    "core/truth/contracts.ts",
    "core/truth/engine.ts",
    "core/truth/index.ts",
    "--target", "ES2022",
    "--module", "NodeNext",
    "--moduleResolution", "NodeNext",
    "--outDir", temp,
    "--strict",
    "--skipLibCheck",
    "--lib", "ES2022,DOM,DOM.Iterable",
  ], { cwd: root, stdio: "pipe" });

  const truth = await import(pathToFileURL(path.join(temp, "truth/engine.js")).href + `?v=${Date.now()}`);
  const tests = [];
  const test = (name, fn) => tests.push({ name, fn });
  const reference = "2026-08-13T18:00:00.000Z";
  const companyId = "11111111-1111-1111-1111-111111111111";
  const orgId = "22222222-2222-2222-2222-222222222222";
  const policy = { policyKey: "GENERAL_FACT_V1", policyVersion: "1.0.0", maxAgeDays: 180, knownSupportFamilyRequirement: 2 };
  const ev = (family, polarity = "SUPPORTS", overrides = {}) => ({
    evidenceItemId: `${family}-${polarity}-${Math.random()}`,
    evidenceFingerprint: "a".repeat(64),
    polarity,
    dependenceFamilyKey: family,
    observedAt: "2026-08-10T18:00:00.000Z",
    originPublishedAt: "2026-08-10T18:00:00.000Z",
    sourcePublishedAt: null,
    ...overrides,
  });
  const ctx = (evidence, overrides = {}) => ({
    claimId: "33333333-3333-3333-3333-333333333333",
    tenantScopeOrganisationId: orgId,
    subjectType: "COMPANY",
    subjectId: companyId,
    claimKey: "operation.current",
    claimFingerprint: "b".repeat(64),
    propositionFingerprint: "f".repeat(64),
    referenceTime: reference,
    contextFingerprint: "c".repeat(64),
    policy,
    evidence,
    ...overrides,
  });

  test("one independent current support family is SUPPORTED", () => {
    assert.equal(truth.evaluateTruthClaim(ctx([ev("family:a")])).truthState, "SUPPORTED");
  });
  test("duplicate evidence in one family cannot manufacture KNOWN", () => {
    const result = truth.evaluateTruthClaim(ctx([ev("family:a"), ev("family:a"), ev("family:a")]));
    assert.equal(result.truthState, "SUPPORTED");
    assert.equal(result.currentSupportFamilyCount, 1);
  });
  test("two independent current support families establish KNOWN", () => {
    const result = truth.evaluateTruthClaim(ctx([ev("family:a"), ev("family:b")]));
    assert.equal(result.truthState, "KNOWN");
    assert.equal(result.evidenceSufficiency, 1);
  });
  test("explicit contradiction cannot be numerically outvoted", () => {
    const evidence = Array.from({ length: 10 }, (_, i) => ev(`family:s${i}`));
    evidence.push(ev("family:contra", "CONTRADICTS"));
    const result = truth.evaluateTruthClaim(ctx(evidence));
    assert.equal(result.truthState, "CONTRADICTED");
  });
  test("support and contradiction in one dependence family is a conflict", () => {
    const result = truth.evaluateTruthClaim(ctx([ev("family:a"), ev("family:a", "CONTRADICTS")]));
    assert.equal(result.truthState, "CONTRADICTED");
    assert.equal(result.currentContradictionFamilyCount, 1);
    assert.equal(result.currentSupportFamilyCount, 0);
  });
  test("stale support is STALE rather than SUPPORTED", () => {
    const result = truth.evaluateTruthClaim(ctx([ev("family:a", "SUPPORTS", { originPublishedAt: "2025-01-01T00:00:00Z", observedAt: "2025-01-01T00:00:00Z" })]));
    assert.equal(result.truthState, "STALE");
  });
  test("undated evidence ages from observedAt", () => {
    const result = truth.evaluateTruthClaim(ctx([ev("family:a", "SUPPORTS", { originPublishedAt: null, sourcePublishedAt: null, observedAt: "2025-01-01T00:00:00Z" })]));
    assert.equal(result.truthState, "STALE");
  });
  test("freshness is evaluated against referenceTime, not ingestion time", () => {
    const evidence = [ev("family:a", "SUPPORTS", { originPublishedAt: "2026-01-01T00:00:00Z", observedAt: "2026-01-01T00:00:00Z" })];
    const early = truth.evaluateTruthClaim(ctx(evidence, { referenceTime: "2026-02-01T00:00:00Z" }));
    const late = truth.evaluateTruthClaim(ctx(evidence, { referenceTime: "2026-12-01T00:00:00Z" }));
    assert.equal(early.truthState, "SUPPORTED");
    assert.equal(late.truthState, "STALE");
  });

  test("freshness decays diagnostically without changing categorical support before expiry", () => {
    const early = truth.evaluateTruthClaim(ctx([ev("family:a", "SUPPORTS", { originPublishedAt: "2026-08-01T18:00:00Z", observedAt: "2026-08-01T18:00:00Z" })], { referenceTime: "2026-08-02T18:00:00Z" }));
    const late = truth.evaluateTruthClaim(ctx([ev("family:a", "SUPPORTS", { originPublishedAt: "2026-08-01T18:00:00Z", observedAt: "2026-08-01T18:00:00Z" })], { referenceTime: "2026-12-01T18:00:00Z" }));
    assert.equal(early.truthState, "SUPPORTED");
    assert.equal(late.truthState, "SUPPORTED");
    assert.ok(early.freshnessCoverage > late.freshnessCoverage);
  });

  test("evidence expires exactly at the policy boundary", () => {
    const result = truth.evaluateTruthClaim(ctx([ev("family:a", "SUPPORTS", {
      originPublishedAt: "2026-02-14T18:00:00.000Z",
      observedAt: "2026-02-14T18:00:00.000Z",
    })]));
    assert.equal(result.truthState, "STALE");
  });
  test("future-dated evidence beyond tolerance is excluded and flagged", () => {
    const result = truth.evaluateTruthClaim(ctx([ev("family:a", "SUPPORTS", {
      originPublishedAt: "2026-08-13T18:10:01.000Z",
      observedAt: "2026-08-13T18:10:01.000Z",
    })]));
    assert.equal(result.truthState, "UNRESOLVED");
    assert.equal(result.temporalAnomalyCount, 1);
  });

  test("historical stale families do not penalise refreshed current evidence", () => {
    const stale = Array.from({ length: 5 }, (_, i) => ev(`old:${i}`, "SUPPORTS", { originPublishedAt: "2025-01-01T00:00:00Z", observedAt: "2025-01-01T00:00:00Z" }));
    const result = truth.evaluateTruthClaim(ctx([
      ev("fresh:a", "SUPPORTS", { originPublishedAt: reference, observedAt: reference }),
      ev("fresh:b", "SUPPORTS", { originPublishedAt: reference, observedAt: reference }),
      ...stale,
    ]));
    assert.equal(result.truthState, "KNOWN");
    assert.equal(result.freshnessCoverage, 1);
  });

  test("truth probability is never invented", () => {
    const result = truth.evaluateTruthClaim(ctx([ev("family:a"), ev("family:b")]));
    assert.equal(result.truthProbability, null);
    assert.equal(result.probabilityState, "UNCALIBRATED");
  });
  test("diagnostic evidence balance cannot determine categorical truth", () => {
    const result = truth.evaluateTruthClaim(ctx([ev("family:a"), ev("family:b"), ev("family:c", "CONTRADICTS")]));
    assert.ok(result.evidenceBalance > 0);
    assert.equal(result.truthState, "CONTRADICTED");
  });
  test("next revalidation is the earliest current evidence expiry", () => {
    const p = { ...policy, maxAgeDays: 10 };
    const result = truth.evaluateTruthClaim(ctx([
      ev("family:a", "SUPPORTS", { originPublishedAt: "2026-08-05T18:00:00Z", observedAt: "2026-08-05T18:00:00Z" }),
      ev("family:b", "SUPPORTS", { originPublishedAt: "2026-08-10T18:00:00Z", observedAt: "2026-08-10T18:00:00Z" }),
    ], { policy: p }));
    assert.equal(result.nextRevalidationAt, "2026-08-15T18:00:00.000Z");
  });
  test("KNOWN policy cannot require fewer than two families", () => {
    assert.throws(() => truth.evaluateTruthClaim(ctx([ev("family:a")], { policy: { ...policy, knownSupportFamilyRequirement: 1 } })), /KNOWN_REQUIREMENT_INVALID/);
  });
  test("all required KNOWN claims yield KNOWN entity with freshness-sensitive Truth Index", () => {
    const keys = ["identity.canonical_name", "identity.canonical_domain", "operation.current"];
    const profile = { profileKey: "COMPANY_CORE_V1", profileVersion: "1.0.0", subjectType: "COMPANY", requiredClaimKeys: keys };
    const claims = keys.map((claimKey, i) => ({ claimKey, evaluations: [truth.evaluateTruthClaim(ctx([ev(`f${i}a`), ev(`f${i}b`)], { claimKey, claimId: `33333333-3333-3333-3333-33333333333${i}` }))] }));
    const result = truth.evaluateTruthEntity(companyId, reference, profile, claims);
    assert.equal(result.entityState, "KNOWN");
    assert.equal(result.truthIndex, 98.33);
  });
  test("all required one-family claims yield SUPPORTED entity, not KNOWN", () => {
    const keys = ["identity.canonical_name", "identity.canonical_domain", "operation.current"];
    const profile = { profileKey: "COMPANY_CORE_V1", profileVersion: "1.0.0", subjectType: "COMPANY", requiredClaimKeys: keys };
    const claims = keys.map((claimKey, i) => ({ claimKey, evaluations: [truth.evaluateTruthClaim(ctx([ev(`f${i}`)], { claimKey }))] }));
    const result = truth.evaluateTruthEntity(companyId, reference, profile, claims);
    assert.equal(result.entityState, "SUPPORTED");
    assert.equal(result.truthIndex, 50);
  });
  test("missing required claim keeps entity PARTIAL and bottlenecks Truth Index", () => {
    const keys = ["identity.canonical_name", "identity.canonical_domain", "operation.current"];
    const profile = { profileKey: "COMPANY_CORE_V1", profileVersion: "1.0.0", subjectType: "COMPANY", requiredClaimKeys: keys };
    const claims = [
      { claimKey: keys[0], evaluations: [truth.evaluateTruthClaim(ctx([ev("a1"), ev("a2")], { claimKey: keys[0] }))] },
      { claimKey: keys[1], evaluations: [truth.evaluateTruthClaim(ctx([ev("b1"), ev("b2")], { claimKey: keys[1] }))] },
      { claimKey: keys[2], evaluations: [] },
    ];
    const result = truth.evaluateTruthEntity(companyId, reference, profile, claims);
    assert.equal(result.entityState, "PARTIAL");
    assert.equal(result.currentCoverage, 0.666667);
    assert.equal(result.truthIndex, 65.56); // maximin reflects both the missing boundary and age of represented evidence.
  });
  test("two supported propositions for one required key create entity contradiction", () => {
    const key = "identity.canonical_domain";
    const profile = { profileKey: "P", profileVersion: "1", subjectType: "COMPANY", requiredClaimKeys: [key] };
    const a = truth.evaluateTruthClaim(ctx([ev("a")], { claimKey: key, claimId: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", claimFingerprint: "d".repeat(64), propositionFingerprint: "1".repeat(64) }));
    const b = truth.evaluateTruthClaim(ctx([ev("b")], { claimKey: key, claimId: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", claimFingerprint: "e".repeat(64), propositionFingerprint: "2".repeat(64) }));
    const result = truth.evaluateTruthEntity(companyId, reference, profile, [{ claimKey: key, evaluations: [a, b] }]);
    assert.equal(result.entityState, "CONTRADICTED");
    assert.equal(result.coherence, 0);
  });
  test("global and tenant copies of the same supported proposition do not create false contradiction", () => {
    const key = "identity.canonical_domain";
    const profile = { profileKey: "P", profileVersion: "1", subjectType: "COMPANY", requiredClaimKeys: [key] };
    const proposition = "7".repeat(64);
    const globalCopy = truth.evaluateTruthClaim(ctx([ev("global")], {
      tenantScopeOrganisationId: null, claimKey: key, claimId: "aaaaaaaa-1111-1111-1111-111111111111", claimFingerprint: "8".repeat(64), propositionFingerprint: proposition,
    }));
    const tenantCopy = truth.evaluateTruthClaim(ctx([ev("tenant")], {
      claimKey: key, claimId: "bbbbbbbb-2222-2222-2222-222222222222", claimFingerprint: "9".repeat(64), propositionFingerprint: proposition,
    }));
    const result = truth.evaluateTruthEntity(companyId, reference, profile, [{ claimKey: key, evaluations: [globalCopy, tenantCopy] }]);
    assert.equal(result.entityState, "SUPPORTED");
    assert.equal(result.contradictedClaimCount, 0);
  });

  test("explicit contradicted claim outranks a KNOWN copy at the same required boundary", () => {
    const key = "operation.current";
    const profile = { profileKey: "P", profileVersion: "1", subjectType: "COMPANY", requiredClaimKeys: [key] };
    const known = truth.evaluateTruthClaim(ctx([ev("known:a"), ev("known:b")], {
      claimKey: key, claimId: "cccccccc-3333-3333-3333-333333333333", propositionFingerprint: "a".repeat(64),
    }));
    const conflicted = truth.evaluateTruthClaim(ctx([ev("conflict", "CONTRADICTS")], {
      claimKey: key, claimId: "dddddddd-4444-4444-4444-444444444444", propositionFingerprint: "a".repeat(64), claimFingerprint: "d".repeat(64),
    }));
    assert.equal(known.truthState, "KNOWN");
    assert.equal(conflicted.truthState, "CONTRADICTED");
    const result = truth.evaluateTruthEntity(companyId, reference, profile, [{ claimKey: key, evaluations: [known, conflicted] }]);
    assert.equal(result.entityState, "CONTRADICTED");
    assert.equal(result.coherence, 0);
  });

  test("stale-only entity is STALE", () => {
    const key = "operation.current";
    const profile = { profileKey: "P", profileVersion: "1", subjectType: "COMPANY", requiredClaimKeys: [key] };
    const stale = truth.evaluateTruthClaim(ctx([ev("a", "SUPPORTS", { originPublishedAt: "2025-01-01T00:00:00Z", observedAt: "2025-01-01T00:00:00Z" })], { claimKey: key }));
    assert.equal(truth.evaluateTruthEntity(companyId, reference, profile, [{ claimKey: key, evaluations: [stale] }]).entityState, "STALE");
  });
  test("entity with no claims is UNRESOLVED", () => {
    const key = "operation.current";
    const profile = { profileKey: "P", profileVersion: "1", subjectType: "COMPANY", requiredClaimKeys: [key] };
    const result = truth.evaluateTruthEntity(companyId, reference, profile, [{ claimKey: key, evaluations: [] }]);
    assert.equal(result.entityState, "UNRESOLVED");
    assert.equal(result.truthIndex, 0);
  });
  test("Truth Index is explicitly not probability", () => {
    const key = "operation.current";
    const profile = { profileKey: "P", profileVersion: "1", subjectType: "COMPANY", requiredClaimKeys: [key] };
    const known = truth.evaluateTruthClaim(ctx([
      ev("a", "SUPPORTS", { originPublishedAt: reference, observedAt: reference }),
      ev("b", "SUPPORTS", { originPublishedAt: reference, observedAt: reference }),
    ], { claimKey: key }));
    const result = truth.evaluateTruthEntity(companyId, reference, profile, [{ claimKey: key, evaluations: [known] }]);
    assert.equal(result.truthIndex, 100);
    assert.equal(result.truthProbability, null);
    assert.equal(result.probabilityState, "UNCALIBRATED");
  });

  let passed = 0;
  console.log("\nMarketRoute V2 Build 4 — Truth Engine adversarial gate");
  for (const { name, fn } of tests) {
    try { await fn(); passed++; console.log(`PASS  ${name}`); }
    catch (error) { console.error(`FAIL  ${name}: ${error instanceof Error ? error.message : error}`); }
  }
  console.log(`\n${passed}/${tests.length} PASS`);
  if (passed !== tests.length) process.exitCode = 1;
} finally {
  fs.rmSync(temp, { recursive: true, force: true });
}
