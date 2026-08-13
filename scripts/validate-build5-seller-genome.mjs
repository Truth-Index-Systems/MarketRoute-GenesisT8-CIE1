import fs from "node:fs";
import path from "node:path";
import { ROOT, assert, check, printResults, readJson } from "./lib/constitution.mjs";

const migration = fs.readFileSync(path.join(ROOT, "supabase/migrations/0008_seller_commercial_genome.sql"), "utf8");
const contracts = fs.readFileSync(path.join(ROOT, "core/seller-genome/contracts.ts"), "utf8");
const canonical = fs.readFileSync(path.join(ROOT, "core/seller-genome/canonical.ts"), "utf8");
const ai = fs.readFileSync(path.join(ROOT, "platform/ai/seller-genome-extractor.ts"), "utf8");
const pkg = readJson("package.json");
const authority = readJson("constitution/authority-manifest.json");
const results = [];

for (const table of ["seller_genome_source_materials", "seller_commercial_genome_snapshots", "campaign_seller_context_selections"]) {
  results.push(check(`Build 5 table exists: ${table}`, () => assert(migration.includes(`CREATE TABLE public.${table}`), `${table} missing`)));
}
results.push(check("seller semantic and explanatory payloads are separate", () => assert(contracts.includes("SellerGenomeSemanticPayload") && contracts.includes("SellerGenomeExplanatoryPayload"), "semantic/prose separation missing")));
results.push(check("all eight seller dimensions are modelled", () => {
  for (const key of ["offerings", "capabilities", "commercialObjectives", "delivery", "serviceGeography", "targetCharacteristics", "buyerAssumptions", "constraints"]) assert(contracts.includes(key), `dimension missing ${key}`);
}));
results.push(check("unknown and explicit-none are distinct", () => assert(contracts.includes('"DECLARED" | "EXPLICIT_NONE" | "UNKNOWN"'), "dimension state contract incomplete")));
results.push(check("constraint hard/preference semantics are categorical", () => assert(contracts.includes('"HARD" | "PREFERENCE"'), "constraint mode missing")));
results.push(check("seller canonicaliser blocks authority-like AI fields", () => assert(canonical.includes("FORBIDDEN_AUTHORITY_KEY") && canonical.includes("MARKETROUTE_SELLER_GENOME_FORBIDDEN_AI_FIELD"), "AI field quarantine missing")));
results.push(check("AI adapter has semantic extraction interface only", () => assert(ai.includes("SellerGenomeSemanticExtractor") && !ai.includes("commercial authority"), "AI extraction boundary missing")));
results.push(check("objective references are validated against same snapshot offerings", () => assert(canonical.includes("OBJECTIVE_UNKNOWN_OFFERING") && migration.includes("OBJECTIVE_UNKNOWN_OFFERING"), "offering reference guard missing")));
results.push(check("database recomputes semantic fingerprint", () => assert(migration.includes("MRV2-SELLER-GENOME-SEMANTIC-1.0.0") && migration.includes("p_canonical_genome_json->'semantic'"), "semantic fingerprint recomputation missing")));
results.push(check("database recomputes exact content fingerprint", () => assert(migration.includes("MRV2-SELLER-GENOME-CONTENT-1.0.0") && migration.includes("v_source.material_fingerprint"), "content fingerprint recomputation missing")));
results.push(check("campaign context has exact and semantic fingerprints", () => assert(migration.includes("input_fingerprint") && migration.includes("semantic_context_fingerprint"), "dual context fingerprint missing")));
results.push(check("campaign objective binding is validated", () => assert(migration.includes("MARKETROUTE_SELLER_CONTEXT_OBJECTIVE_NOT_FOUND"), "campaign objective binding guard missing")));
results.push(check("seller context persistence is RPC-only", () => {
  for (const table of ["seller_genome_source_materials", "seller_commercial_genome_snapshots", "campaign_seller_context_selections"]) {
    assert(migration.includes(`REVOKE ALL ON public.${table} FROM anon, authenticated, service_role`), `${table} DML not revoked`);
  }
}));
results.push(check("Build 5 ledgers are append-only", () => {
  for (const trigger of ["seller_genome_source_materials_append_only", "seller_commercial_genome_snapshots_append_only", "campaign_seller_context_selections_append_only"]) assert(migration.includes(trigger), `${trigger} missing`);
}));
results.push(check("source material identity is database computed", () => assert(migration.includes("MRV2-SELLER-SOURCE-1.0.0") && migration.includes("material_fingerprint"), "source fingerprint missing")));
results.push(check("source fingerprint collisions fail closed", () => assert(migration.includes("MARKETROUTE_SELLER_SOURCE_FINGERPRINT_COLLISION"), "source collision guard missing")));
results.push(check("content fingerprint collisions fail closed", () => assert(migration.includes("MARKETROUTE_SELLER_GENOME_CONTENT_FINGERPRINT_COLLISION"), "content collision guard missing")));
results.push(check("database validates seller display name against canonical seller", () => assert(migration.includes("MARKETROUTE_SELLER_GENOME_DISPLAY_NAME_MISMATCH"), "seller identity presentation guard missing")));
results.push(check("current campaign context returns persisted fingerprints", () => assert(migration.includes("marketroute_get_current_campaign_seller_context_v1") && migration.includes("semanticContextFingerprint"), "current context RPC missing")));
results.push(check("authority registry remains empty", () => assert(!/INSERT\s+INTO\s+public\.authority_writer_registry/i.test(migration), "Build 5 migration created authority")));
results.push(check("migration does not mutate authority writer registry", () => assert(!/INSERT\s+INTO\s+public\.authority_writer_registry/i.test(migration), "Build 5 mutated authority registry")));
results.push(check("migration does not mutate opportunities", () => assert(!/UPDATE\s+public\.opportunities/i.test(migration), "Build 5 mutated workflow")));
results.push(check("seller contracts contain no target Truth ownership", () => assert(!contracts.includes("TruthState") && !contracts.includes("truthProbability"), "Truth ownership leaked into seller genome")));
results.push(check("Build 5 scripts are wired", () => assert(pkg.scripts["constitution:seller"] && pkg.scripts["constitution:seller-adversarial"], "Build 5 scripts missing")));
results.push(check("Build 5 application service exists", () => assert(fs.existsSync(path.join(ROOT, "application/seller-genome/service.ts")), "seller service missing")));
results.push(check("Build 5 repository exists", () => assert(fs.existsSync(path.join(ROOT, "platform/database/seller-genome-repository.ts")), "seller repository missing")));
results.push(check("Build 5 schema release explicitly says no commercial authority", () => assert(migration.includes("'commercial_authority', false") && migration.includes("'authority_writers', 0"), "release metadata overclaims authority")));

printResults("MarketRoute V2 Build 5 — Seller Commercial Genome static gate", results);
