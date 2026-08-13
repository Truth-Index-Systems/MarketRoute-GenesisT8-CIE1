import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";

const root = path.resolve(import.meta.dirname, "../..");
const temp = fs.mkdtempSync(path.join(os.tmpdir(), "mrv2-build3-"));
try {
  execFileSync("tsc", [
    "core/evidence/contracts.ts",
    "core/evidence/canonical.ts",
    "core/evidence/index.ts",
    "--target", "ES2022",
    "--module", "NodeNext",
    "--moduleResolution", "NodeNext",
    "--outDir", temp,
    "--strict",
    "--skipLibCheck",
    "--lib", "ES2022,DOM,DOM.Iterable",
  ], { cwd: root, stdio: "pipe" });

  const c = await import(pathToFileURL(path.join(temp, "canonical.js")).href + `?v=${Date.now()}`);
  const tests = [];
  const test = (name, fn) => tests.push({ name, fn });
  const source = (overrides = {}) => c.canonicaliseSource({ sourceKind: "WEB", url: "https://Example.com/news/launch?utm_source=x", title: " Launch  ", ...overrides });

  test("SHA-256 implementation matches standard vector", () => assert.equal(c.sha256Hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"));
  test("tracking parameters do not change source identity", () => {
    const a = source({ url: "https://example.com/news/launch?utm_source=a&fbclid=1" });
    const b = source({ url: "http://www.example.com:80/news/launch" });
    assert.equal(a.sourceIdentityFingerprint, b.sourceIdentityFingerprint);
  });
  test("meaningful query parameters do change source identity", () => {
    assert.notEqual(source({ url: "https://example.com/report?id=1" }).sourceIdentityFingerprint, source({ url: "https://example.com/report?id=2" }).sourceIdentityFingerprint);
  });
  test("query order is canonical", () => assert.equal(source({ url: "https://example.com/x?b=2&a=1" }).sourceIdentityFingerprint, source({ url: "https://example.com/x?a=1&b=2" }).sourceIdentityFingerprint));
  test("title changes do not change source identity", () => assert.equal(source({ title: "A" }).sourceIdentityFingerprint, source({ title: "B" }).sourceIdentityFingerprint));
  test("same publisher domain collapses into one dependence family", () => assert.equal(source({ url: "https://example.com/a" }).dependenceFamilyKey, source({ url: "https://example.com/b" }).dependenceFamilyKey));
  test("different publishers produce different dependence families", () => assert.notEqual(source({ url: "https://example.com/a" }).dependenceFamilyKey, source({ url: "https://different.example/a" }).dependenceFamilyKey));
  test("publisher URL mismatch is rejected", () => assert.throws(() => source({ url: "https://example.com/a", publisherDomain: "evil.example" }), /PUBLISHER_DOMAIN_URL_MISMATCH/));
  test("unsupported protocols are rejected", () => assert.throws(() => source({ url: "ftp://example.com/a" }), /UNSUPPORTED_SOURCE_PROTOCOL/));
  test("non-URL sources require a stable locator", () => assert.throws(() => c.canonicaliseSource({ sourceKind: "DOCUMENT" }), /STABLE_LOCATOR_REQUIRED/));
  test("stable JSON ignores object key insertion order", () => assert.equal(c.stableJson({ b: 2, a: 1 }), c.stableJson({ a: 1, b: 2 })));
  test("stable JSON preserves array order", () => assert.notEqual(c.stableJson([1, 2]), c.stableJson([2, 1])));
  test("non-finite numbers are rejected", () => assert.throws(() => c.stableJson({ x: Number.NaN }), /NON_FINITE_JSON_NUMBER/));
  test("repeated observation time does not duplicate identical evidence", () => {
    const s = source();
    const base = { subjectType: "COMPANY", subjectId: "11111111-1111-1111-1111-111111111111", evidenceKind: "QUOTE", excerptText: "Acme   builds widgets", extractionMethod: "DETERMINISTIC", extractionVersion: "parser-1" };
    const a = c.canonicaliseEvidence(s, { ...base, observedAt: "2026-08-13T10:00:00Z" });
    const b = c.canonicaliseEvidence(s, { ...base, observedAt: "2026-08-14T10:00:00Z" });
    assert.equal(a.evidenceFingerprint, b.evidenceFingerprint);
  });
  test("whitespace-only excerpt differences deduplicate", () => {
    const s = source();
    const base = { subjectType: "COMPANY", subjectId: "11111111-1111-1111-1111-111111111111", evidenceKind: "QUOTE", extractionMethod: "DETERMINISTIC", extractionVersion: "parser-1" };
    assert.equal(c.canonicaliseEvidence(s, { ...base, excerptText: "A  B" }).evidenceFingerprint, c.canonicaliseEvidence(s, { ...base, excerptText: " A\nB " }).evidenceFingerprint);
  });
  test("changed evidence content changes fingerprint", () => {
    const s = source();
    const base = { subjectType: "COMPANY", subjectId: "11111111-1111-1111-1111-111111111111", evidenceKind: "QUOTE", extractionMethod: "DETERMINISTIC", extractionVersion: "parser-1" };
    assert.notEqual(c.canonicaliseEvidence(s, { ...base, excerptText: "A" }).evidenceFingerprint, c.canonicaliseEvidence(s, { ...base, excerptText: "B" }).evidenceFingerprint);
  });
  test("extraction version changes evidence provenance fingerprint", () => {
    const s = source();
    const base = { subjectType: "COMPANY", subjectId: "11111111-1111-1111-1111-111111111111", evidenceKind: "QUOTE", excerptText: "A", extractionMethod: "AI_EXTRACTED" };
    assert.notEqual(c.canonicaliseEvidence(s, { ...base, extractionVersion: "v1" }).evidenceFingerprint, c.canonicaliseEvidence(s, { ...base, extractionVersion: "v2" }).evidenceFingerprint);
  });
  test("tenant scope changes evidence fingerprint", () => {
    const s = source();
    const base = { subjectType: "COMPANY", subjectId: "11111111-1111-1111-1111-111111111111", evidenceKind: "QUOTE", excerptText: "A", extractionMethod: "DETERMINISTIC" };
    assert.notEqual(c.canonicaliseEvidence(s, base).evidenceFingerprint, c.canonicaliseEvidence(s, { ...base, tenantScopeOrganisationId: "22222222-2222-2222-2222-222222222222" }).evidenceFingerprint);
  });
  test("claim object key order does not change claim identity", () => {
    const base = { subjectType: "COMPANY", subjectId: "11111111-1111-1111-1111-111111111111", claimKey: "company.current_operation", predicate: "operates_as", canonicalValueText: "Active" };
    assert.equal(c.canonicaliseClaim({ ...base, object: { b: 2, a: 1 } }).claimFingerprint, c.canonicaliseClaim({ ...base, object: { a: 1, b: 2 } }).claimFingerprint);
  });
  test("different claim value changes claim identity", () => {
    const base = { subjectType: "COMPANY", subjectId: "11111111-1111-1111-1111-111111111111", claimKey: "company.current_operation", predicate: "operates_as" };
    assert.notEqual(c.canonicaliseClaim({ ...base, object: { state: "ACTIVE" } }).claimFingerprint, c.canonicaliseClaim({ ...base, object: { state: "DISSOLVED" } }).claimFingerprint);
  });
  test("claim tenant scope is part of claim identity", () => {
    const base = { subjectType: "COMPANY", subjectId: "11111111-1111-1111-1111-111111111111", claimKey: "x", predicate: "is", object: true };
    assert.notEqual(c.canonicaliseClaim(base).claimFingerprint, c.canonicaliseClaim({ ...base, tenantScopeOrganisationId: "22222222-2222-2222-2222-222222222222" }).claimFingerprint);
  });

  let passed = 0;
  console.log("\nMarketRoute V2 Build 3 — evidence canonicalisation adversarial gate");
  for (const { name, fn } of tests) {
    try { await fn(); passed++; console.log(`PASS  ${name}`); }
    catch (error) { console.error(`FAIL  ${name}: ${error instanceof Error ? error.message : error}`); }
  }
  console.log(`\n${passed}/${tests.length} PASS`);
  if (passed !== tests.length) process.exitCode = 1;
} finally {
  fs.rmSync(temp, { recursive: true, force: true });
}
