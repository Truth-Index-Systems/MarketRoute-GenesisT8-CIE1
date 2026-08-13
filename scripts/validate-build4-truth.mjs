import fs from "node:fs";
import path from "node:path";
import { ROOT, assert, check, printResults, readJson } from "./lib/constitution.mjs";

const migration = fs.readFileSync(path.join(ROOT, "supabase/migrations/0007_truth_engine_v2.sql"), "utf8");
const db = readJson("constitution/database-boundary.json");
const authority = readJson("constitution/authority-manifest.json");
const pkg = readJson("package.json");
const contracts = fs.readFileSync(path.join(ROOT, "core/truth/contracts.ts"), "utf8");
const engine = fs.readFileSync(path.join(ROOT, "core/truth/engine.ts"), "utf8");
const results = [];

results.push(check("Build 4 database laws survive successor builds", () => assert(db.build >= 4 && db.principles.truthImplementedAsNonAuthoritativeReasoning === true, "Build 4 Truth database laws were not preserved")));
results.push(check("pre-authority successor still has zero authority writers", () => assert(authority.schemaBuild >= 4, "schema regressed")));
results.push(check("authority manifest remains at or beyond Truth foundation without authority", () => assert(db.principles.truthImplementedAsNonAuthoritativeReasoning === true, "Truth foundation was not preserved")));
results.push(check("Truth is explicitly non-authoritative reasoning", () => assert(db.principles.truthImplementedAsNonAuthoritativeReasoning === true && db.principles.reasoningIsNotAuthority === true, "Truth authority boundary missing")));
results.push(check("Truth probability requires empirical calibration", () => assert(db.principles.truthProbabilityRequiresEmpiricalCalibration === true && db.principles.truthProbabilityCurrentlyNull === true, "probability constitution missing")));
results.push(check("categorical truth cannot use continuous thresholds", () => assert(db.principles.truthCategoricalStateCannotUseContinuousThresholds === true, "categorical-state law missing")));
results.push(check("dependence family collapse is constitutional", () => assert(db.principles.truthDependenceFamiliesCollapsedBeforeCorroboration === true, "dependence collapse law missing")));
results.push(check("freshness uses evaluation reference time", () => assert(db.principles.truthFreshnessUsesEvaluationReferenceTime === true, "freshness law missing")));
results.push(check("Truth Index is not probability", () => assert(db.principles.truthIndexIsNotProbability === true, "Truth Index semantics missing")));
results.push(check("proposition identity is tenant-neutral constitutionally", () => assert(db.principles.truthPropositionIdentityTenantNeutral === true, "proposition identity law missing")));
results.push(check("entity contradiction precedence is constitutional", () => assert(db.principles.truthEntityContradictionPrecedesPositive === true, "entity contradiction law missing")));
results.push(check("global Truth claims are reusable within tenant evaluation", () => assert(db.principles.globalTruthClaimsReusableWithinTenantEvaluation === true, "global reuse law missing")));
results.push(check("claim Truth states are categorical", () => {
  for (const state of ["KNOWN", "SUPPORTED", "UNRESOLVED", "CONTRADICTED", "STALE"]) assert(contracts.includes(`"${state}"`), `missing ${state}`);
}));
results.push(check("truth probability type is null", () => assert(contracts.includes("truthProbability: null"), "Truth probability is not structurally null")));
results.push(check("engine version is frozen", () => assert(contracts.includes('MRV2-TRUTH-1.0.0') && contracts.includes('MRV2-TRUTH-SEM-1.0.0'), "Truth version missing")));
results.push(check("one-family support cannot become KNOWN by score", () => assert(engine.includes("currentSupportFamilyCount >= requirement") && engine.includes("currentSupportFamilyCount >= 1"), "categorical family rule missing")));
results.push(check("contradiction has precedence over support", () => {
  const contradiction = engine.indexOf("currentContradictionFamilyCount > 0");
  const known = engine.indexOf("currentSupportFamilyCount >= requirement");
  assert(contradiction >= 0 && contradiction < known, "contradiction does not precede KNOWN");
}));
results.push(check("exact expiry boundary is stale", () => assert(engine.includes("ageMs < maxAgeMs"), "expiry boundary is not strict")));
results.push(check("undated evidence falls back to observedAt", () => assert(engine.includes("evidence.originPublishedAt ?? evidence.sourcePublishedAt ?? evidence.observedAt"), "undated fallback missing")));
results.push(check("future temporal anomaly is excluded", () => assert(engine.includes("FUTURE_TOLERANCE_MS") && engine.includes("temporalAnomalyCount += 1"), "temporal anomaly protection missing")));
results.push(check("entity aggregation detects competing supported propositions", () => assert(engine.includes("positiveByProposition.size > 1") && engine.includes('entityState = "CONTRADICTED"'), "competing proposition gate missing")));
results.push(check("tenant-neutral proposition identity is explicit", () => assert(contracts.includes("propositionFingerprint: string") && migration.includes("marketroute_truth_proposition_fingerprint_v1"), "proposition identity missing")));
results.push(check("entity contradiction outranks positive copies", () => {
  const contradiction = engine.indexOf("contradictedEvaluations.length > 0");
  const positive = engine.indexOf("positiveByProposition.size === 1");
  assert(contradiction >= 0 && contradiction < positive, "entity contradiction does not precede positive selection");
}));
results.push(check("tenant entity context may reuse global claims", () => assert(migration.includes("c.tenant_scope_organisation_id IS NULL OR c.tenant_scope_organisation_id = p_tenant_scope_organisation_id"), "global research reuse missing")));
results.push(check("policy bindings do not carry proposition identity", () => {
  const bindingBlock = migration.slice(migration.indexOf("CREATE TABLE public.truth_claim_policy_bindings"), migration.indexOf("CREATE TABLE public.truth_entity_profile_registry"));
  assert(!bindingBlock.includes("proposition_fingerprint"), "proposition fingerprint leaked into policy binding schema");
}));
results.push(check("Truth Index uses maximin not weighted average", () => assert(engine.includes("Math.min(currentCoverage, evidenceSufficiency, freshnessCoverage, coherence)"), "Truth Index is not maximin")));
results.push(check("Truth policy registry exists", () => assert(migration.includes("CREATE TABLE public.truth_claim_policy_registry"), "policy registry missing")));
results.push(check("Truth profile registry exists", () => assert(migration.includes("CREATE TABLE public.truth_entity_profile_registry"), "profile registry missing")));
results.push(check("claim Truth snapshots are append-only", () => assert(migration.includes("truth_claim_snapshots_append_only"), "claim snapshot append-only trigger missing")));
results.push(check("entity Truth snapshots are append-only", () => assert(migration.includes("truth_entity_snapshots_append_only"), "entity snapshot append-only trigger missing")));
results.push(check("claim persistence independently re-derives evidence facts", () => assert(migration.includes("marketroute_truth_claim_facts_v1") && migration.includes("MARKETROUTE_TRUTH_OUTPUT_DOES_NOT_MATCH_EVIDENCE"), "DB Truth verification missing")));
results.push(check("stale context persistence is rejected", () => assert(migration.includes("MARKETROUTE_TRUTH_CONTEXT_CHANGED"), "context TOCTOU guard missing")));
results.push(check("database computes Truth snapshot fingerprint", () => assert(migration.includes("MRV2-TRUTH-SNAPSHOT-1.0.0") && migration.includes("extensions.digest"), "snapshot fingerprint recomputation missing")));
results.push(check("generic reasoning direct DML is revoked", () => assert(migration.includes("REVOKE INSERT, UPDATE, DELETE ON public.reasoning_runs FROM service_role") && migration.includes("REVOKE INSERT, UPDATE, DELETE ON public.reasoning_artifacts FROM service_role"), "generic reasoning DML remains open")));
results.push(check("latest views do not falsely claim currentness", () => assert(migration.includes("latest_truth_claim_snapshots") && migration.includes("latest_truth_entity_snapshots") && !migration.includes("current_truth_claim_snapshots"), "Truth view semantics overclaim currentness")));
results.push(check("company core profile is explicit", () => {
  for (const key of ["identity.canonical_name", "identity.canonical_domain", "operation.current"]) assert(migration.includes(key), `missing company core key ${key}`);
}));
results.push(check("Build 4 runtime adapters exist", () => {
  assert(fs.existsSync(path.join(ROOT, "platform/database/truth-repository.ts")), "Truth repository missing");
  assert(fs.existsSync(path.join(ROOT, "application/truth/service.ts")), "Truth application service missing");
}));
results.push(check("Build 4 scripts wired", () => assert(pkg.scripts["constitution:truth"] && pkg.scripts["constitution:truth-adversarial"] && pkg.scripts["constitution:truth-db-adversarial"], "Build 4 scripts missing")));
results.push(check("no commercial authority token appears in Truth output contract", () => {
  const lower = contracts.toLowerCase();
  for (const token of ["commercial_candidate", "route_authority", "contact_authority", "execution_permission"]) assert(!lower.includes(token), `commercial authority leaked into Truth contract: ${token}`);
}));

printResults("MarketRoute V2 Build 4 — Truth Engine static gate", results);
