import fs from "node:fs";
import path from "node:path";
import { ROOT, assert, check, printResults, readJson } from "./lib/constitution.mjs";

const migration = fs.readFileSync(path.join(ROOT, "supabase/migrations/0006_evidence_provenance_runtime.sql"), "utf8");
const db = readJson("constitution/database-boundary.json");
const authority = readJson("constitution/authority-manifest.json");
const pkg = readJson("package.json");
const results = [];

results.push(check("Build 3 schema version declared", () => assert(db.build >= 3, `database boundary regressed below Build 3: ${db.build}`)));
results.push(check("authority registry remains empty", () => assert(authority.authorityWriters.length === 0, "Build 3 must not create authority")));
results.push(check("authority manifest advances schema build only", () => assert(authority.schemaBuild >= 3 && authority.authorityWriters.length === 0, "authority manifest regressed or introduced authority")));
results.push(check("evidence runtime is RPC-write-only constitutionally", () => assert(db.principles.evidenceRuntimeIsRpcWriteOnly === true, "RPC-only evidence boundary missing")));
results.push(check("dependence family belongs to evidence", () => assert(db.principles.dependenceFamilyOwnedByEvidence === true, "dependence ownership missing")));
results.push(check("source identity is immutable", () => assert(db.principles.sourceIdentityIsImmutable === true, "source identity immutability missing")));
results.push(check("Build 3 evidence remains non-authoritative after successor builds", () => assert(db.principles.evidenceIsNotAuthority === true && authority.authorityWriters.length === 0, "evidence gained authority")));
results.push(check("migration adds source identity fingerprint", () => assert(migration.includes("source_identity_fingerprint"), "source identity fingerprint missing")));
results.push(check("migration adds evidence dependence family snapshot", () => assert(migration.includes("ADD COLUMN dependence_family_key text"), "evidence family snapshot missing")));
results.push(check("migration versions evidence fingerprints", () => assert(migration.includes("ADD COLUMN fingerprint_version text"), "fingerprint version missing")));
results.push(check("source identity mutation trigger exists", () => assert(migration.includes("source_records_identity_immutable"), "source identity trigger missing")));
results.push(check("claim link family must inherit evidence", () => assert(migration.includes("MARKETROUTE_DEPENDENCE_FAMILY_MUST_INHERIT_EVIDENCE"), "family inheritance gate missing")));
results.push(check("claim/evidence subject identity must match", () => assert(migration.includes("MARKETROUTE_CLAIM_EVIDENCE_SUBJECT_MISMATCH"), "subject identity gate missing")));
results.push(check("one evidence item has one polarity per claim", () => assert(migration.includes("claim_evidence_links_single_polarity_unique"), "single-polarity uniqueness missing")));
results.push(check("transactional evidence RPC exists", () => assert(migration.includes("marketroute_ingest_evidence_v1"), "evidence RPC missing")));
results.push(check("transactional claim/evidence RPC exists", () => assert(migration.includes("marketroute_record_claim_evidence_v1"), "claim RPC missing")));
results.push(check("claim supersession RPC exists", () => assert(migration.includes("marketroute_supersede_claim_v1"), "supersession RPC missing")));
results.push(check("source collisions fail closed", () => assert(migration.includes("MARKETROUTE_SOURCE_FINGERPRINT_COLLISION"), "source collision gate missing")));
results.push(check("evidence collisions fail closed", () => assert(migration.includes("MARKETROUTE_EVIDENCE_FINGERPRINT_COLLISION"), "evidence collision gate missing")));
results.push(check("claim collisions fail closed", () => assert(migration.includes("MARKETROUTE_CLAIM_FINGERPRINT_COLLISION"), "claim collision gate missing")));
results.push(check("service role direct evidence DML is revoked", () => {
  for (const table of db.evidenceRpcOnlyWriteTables) {
    assert(migration.includes(`REVOKE ALL ON public.${table} FROM anon, authenticated, service_role;`), `missing revoke ${table}`);
    assert(migration.includes(`GRANT SELECT ON public.${table} TO service_role;`), `missing read-only grant ${table}`);
    assert(!migration.includes(`GRANT SELECT, INSERT ON public.${table} TO service_role;`), `direct insert survives for ${table}`);
  }
}));
results.push(check("evidence RPC requires service role", () => assert(migration.includes("PERFORM public.marketroute_require_service_role();"), "service-role gate not used")));
results.push(check("claim linking RPC does not accept dependence family", () => {
  const signature = migration.slice(migration.indexOf("CREATE OR REPLACE FUNCTION public.marketroute_record_claim_evidence_v1"), migration.indexOf(")\nRETURNS TABLE", migration.indexOf("CREATE OR REPLACE FUNCTION public.marketroute_record_claim_evidence_v1")));
  assert(!signature.includes("p_dependence_family"), "caller may supply dependence family");
}));
results.push(check("database release explicitly records zero authority", () => assert(migration.includes("'authority_writers', 0"), "release overclaims authority")));
results.push(check("runtime database adapter exists", () => assert(fs.existsSync(path.join(ROOT, "platform/database/evidence-repository.ts")), "repository missing")));
results.push(check("application evidence service exists", () => assert(fs.existsSync(path.join(ROOT, "application/evidence/service.ts")), "application service missing")));
results.push(check("core evidence has no Truth output", () => {
  const text = fs.readFileSync(path.join(ROOT, "core/evidence/contracts.ts"), "utf8").toLowerCase();
  for (const token of ["truthprobability", "commercial_candidate", "route authority", "contact authority"]) assert(!text.includes(token), `premature authority token ${token}`);
}));
results.push(check("Build 3 scripts are wired", () => assert(pkg.scripts["constitution:evidence"] && pkg.scripts["constitution:evidence-adversarial"], "Build 3 scripts missing")));

printResults("MarketRoute V2 Build 3 — evidence provenance static gate", results);
