import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const ROOT=path.resolve(import.meta.dirname,"..");
const read=(p)=>fs.readFileSync(path.join(ROOT,p),"utf8");
const json=(p)=>JSON.parse(read(p));
const walk=(dir)=>{
  const out=[];
  for(const entry of fs.readdirSync(path.join(ROOT,dir),{withFileTypes:true})){
    const rel=path.join(dir,entry.name);
    if(entry.isDirectory()) out.push(...walk(rel)); else out.push(rel.replaceAll("\\","/"));
  }
  return out;
};
const checks=[];
const check=(name,fn)=>checks.push({name,fn});
const manifest=json("constitution/authority-manifest.json");
const release=json("constitution/release-certification.json");
const pkg=json("package.json");
const db=json("constitution/database-boundary.json");
const authorityKeys=manifest.authorityWriters.map(x=>x.writerKey).sort();
const expected=["marketroute.r4.commercial-reality","marketroute.r5.relationship-graph","marketroute.r6.contact-truth"].sort();
const migrations=walk("supabase/migrations").filter(f=>/\/\d{4}_.*\.sql$/.test("/"+f));
const appUi=[...walk("app"),...walk("ui")].filter(f=>/\.(ts|tsx)$/.test(f));
const browserSource=appUi.map(f=>read(f)).join("\n");
const allRuntime=[...walk("core"),...walk("application"),...walk("platform"),...appUi].filter(f=>/\.(ts|tsx|mjs|js)$/.test(f));
const runtimeText=allRuntime.map(f=>`\n/* ${f} */\n${read(f)}`).join("\n");
const engagementSql=read("supabase/migrations/0015_engagement_engine.sql");
const migrationSql=read("supabase/migrations/0019_v1_evidence_migration.sql");
const readSql=read("supabase/migrations/0016_canonical_application_read_model.sql");

check("Build 18 lineage remains the frozen 0.18 release family",()=>assert(/^0\.18\.[0-3]$/.test(pkg.version)));
check("release certification pins exact Build 17 source",()=>assert.equal(release.sourceBuildSha256,"c5dd0cc7950b1be8824c24b40f4c9b9c4bc5cb74d206e44bf823d0804fab4e5e"));
check("Build 18 certification remains schema-free and post-freeze operational migrations are isolated",()=>{assert.equal(release.databaseMigrationRequired,false);const max=Math.max(...migrations.map(f=>Number(path.basename(f).slice(0,4))));assert(max>=19&&max<=34);const authorityWrite=/INSERT\s+INTO\s+public\.(?:commercial_reality_r4_records|route_authority_r5_records|contact_authority_r6_records|authority_records)/i;if(max>=20){const activation=read("supabase/migrations/0020_production_activation_runtime.sql");assert(/production activation/i.test(activation));assert(/new_authority_writer[^\n]*false/i.test(activation));assert(!authorityWrite.test(activation));}if(max>=21){const founder=read("supabase/migrations/0021_founder_dashboard_observability.sql");assert(/founder dashboard|founder observability/i.test(founder));assert(/new_authority_writer[^\n]*false/i.test(founder));assert(!authorityWrite.test(founder));}if(max>=22){const growth=read("supabase/migrations/0022_genesis_database_growth.sql");assert(/DATABASE_GROWTH|database growth/i.test(growth));assert(/new_authority_writer[^\n]*false/i.test(growth));assert(!authorityWrite.test(growth));}if(max>=23){const hotfix=read("supabase/migrations/0023_production_runtime_ambiguity_cost_hotfix.sql");assert(/production hotfix 0\.18\.3\.[12]/i.test(hotfix));assert(!authorityWrite.test(hotfix));}if(max>=24){const truthHotfix=read("supabase/migrations/0024_truth_entity_snapshot_ambiguity_hotfix.sql");assert(/production hotfix 0\.18\.3\.3/i.test(truthHotfix));assert(/tes\.input_fingerprint\s*=\s*v_input_fingerprint/i.test(truthHotfix));assert(!authorityWrite.test(truthHotfix));}if(max>=25){const density=read("supabase/migrations/0025_growth_seed_to_density_policy.sql");assert(/seed-to-density|SEED_TO_DENSITY/i.test(density));assert(!authorityWrite.test(density));}if(max>=26){const relationship=read("supabase/migrations/0026_route_relationship_claim_fingerprint_version_hotfix.sql");assert(/fingerprint_version/i.test(relationship));assert(/MRV2-CLAIM-FP-1\.0\.0/.test(relationship));assert(!authorityWrite.test(relationship));}if(max>=27){const hardening=read("supabase/migrations/0027_production_activation_hardening.sql");assert(/production activation hardening 0\.18\.3\.7/i.test(hardening));assert(/new_authority_writer',false/i.test(hardening));assert(/marketroute_activation_bank_candidates_v1/.test(hardening));assert(!authorityWrite.test(hardening));}if(max>=28){const genomeHotfix=read("supabase/migrations/0028_seller_genome_json_operator_hotfix.sql");assert(/seller-genome JSON operator hotfix 0\.18\.3\.8/i.test(genomeHotfix));assert(/new_authority_writer',false/i.test(genomeHotfix));assert(/sqlstate_fixed','22P02'/i.test(genomeHotfix));assert(!authorityWrite.test(genomeHotfix));}if(max>=29){const domainHotfix=read("supabase/migrations/0029_activation_company_domain_hotfix.sql");assert(/activation company-domain hotfix 0\.18\.3\.9/i.test(domainHotfix));assert(/new_authority_writer',false/i.test(domainHotfix));assert(/valid_domain_regression','example\.com'/i.test(domainHotfix));assert(!authorityWrite.test(domainHotfix));}});
check("schema and presentation remain their owning builds",()=>{assert.equal(manifest.schemaBuild,17);assert.equal(manifest.presentationBuild,16);assert.equal(release.schemaBuild,17);assert.equal(release.presentationBuild,16);});
check("campaign lifecycle operational migration remains non-authoritative",()=>{const lifecycle=read("supabase/migrations/0030_campaign_lifecycle_controls.sql");assert(/campaign lifecycle controls 0\.18\.3\.10/i.test(lifecycle));assert(/new_authority_writer',false/i.test(lifecycle));assert(/p_confirmation_name\s+IS\s+DISTINCT\s+FROM\s+v_campaign\.name/i.test(lifecycle));assert(!/INSERT\s+INTO\s+public\.(?:commercial_reality_r4_records|route_authority_r5_records|contact_authority_r6_records|authority_records)/i.test(lifecycle));});
check("research-plan persistence hotfix remains non-authoritative",()=>{const hotfix=read("supabase/migrations/0031_research_plan_persistence_hotfix.sql");assert(/research-plan persistence hotfix 0\.18\.3\.11/i.test(hotfix));assert(/new_authority_writer',false/i.test(hotfix));assert(/AT TIME ZONE 'UTC'/i.test(hotfix));assert(/p\.plan_fingerprint\s*=\s*v_expected_fp/i.test(hotfix));assert(!/INSERT\s+INTO\s+public\.(?:commercial_reality_r4_records|route_authority_r5_records|contact_authority_r6_records|authority_records)/i.test(hotfix));});
check("R4 persistence hotfix replaces only the registered writer",()=>{const hotfix=read("supabase/migrations/0032_r4_persistence_ambiguity_hotfix.sql");assert(/R4 persistence ambiguity hotfix 0\.18\.3\.12/i.test(hotfix));assert(/new_authority_writer',false/i.test(hotfix));assert(/replaced_existing_authority_writer','marketroute\.r4\.commercial-reality'/i.test(hotfix));assert(/r\.input_fingerprint\s*=\s*v_input_fingerprint/i.test(hotfix));assert(!/INSERT INTO public\.authority_writer_registry/i.test(hotfix));});
check("R4 context snapshot-array hotfix preserves authority semantics",()=>{const hotfix=read("supabase/migrations/0033_r4_context_snapshot_array_hotfix.sql");assert(/R4 context snapshot-array hotfix 0\.18\.3\.13/i.test(hotfix));assert(/new_authority_writer',false/i.test(hotfix));assert(/authority_semantics_unchanged',true/i.test(hotfix));assert(/jsonb_agg\(e\.value ->> 'snapshotId'/i.test(hotfix));assert(!/INSERT INTO public\.authority_writer_registry/i.test(hotfix));});
check("R4 ISO timestamp hotfix restores TypeScript/database boundary parity",()=>{const hotfix=read("supabase/migrations/0034_r4_iso_timestamp_format_hotfix.sql");assert(/R4 ISO timestamp-format hotfix 0\.18\.3\.14/i.test(hotfix));assert(/new_authority_writer',false/i.test(hotfix));assert(/typescript_database_boundary_parity',true/i.test(hotfix));assert(/YYYY-MM-DD"T"HH24:MI:SS\.MS"Z"/.test(hotfix));assert(!/YYYY-MM-DD\\"T\\"HH24:MI:SS\.MS\\"Z"/.test(hotfix));assert(!/INSERT INTO public\.authority_writer_registry/i.test(hotfix));});
check("authority writer set is exactly R4 R5 R6",()=>{assert.equal(manifest.authorityWriters.length,3);assert.deepEqual(authorityKeys,expected);assert.equal(release.authorityWriterCount,3);});
check("every authority writer remains categorical and DB-recomputed",()=>manifest.authorityWriters.forEach(w=>{assert.equal(w.numericAuthority,false);assert.equal(w.databaseRecomputesDecision,true);assert.equal(w.databaseRecomputesFingerprint,true);assert.equal(w.timeBound,true);}));
check("Build 18 frozen status is explicit",()=>{assert.equal(manifest.status,"PRODUCTION_CANDIDATE_FROZEN");assert.equal(manifest.certificationBuild,18);assert.equal(release.freezeState,"SOURCE_FROZEN_PRODUCTION_CANDIDATE");});
check("live cutover cannot be falsely certified by source build",()=>{assert.equal(manifest.certificationStatus,"SOURCE_CERTIFIED_LIVE_CUTOVER_PENDING");assert.equal(release.liveCutoverState,"PENDING_REAL_V2_DATA_TRACE");});
check("browser presentation has no direct database/platform authority dependency",()=>{assert(!/(?:@\/|\.\.\/).*platform\/database/.test(browserSource));assert(!/SUPABASE_SERVICE_ROLE_KEY|process\.env/.test(browserSource));});
check("browser presentation contains no Supabase RPC authority reconstruction",()=>assert(!/\/rest\/v1\/rpc|marketroute_persist_(?:commercial_reality|route_authority|contact_authority)/i.test(browserSource)));
check("runtime contains no V1 compatibility adapter/import",()=>assert(!/(?:from|import\()\s*["'][^"']*(?:\/v1\/|legacy|compatibility-adapter)/i.test(runtimeText)));
check("migration remains offline factual-only bridge",()=>{assert(/MARKETROUTE_V1_AUTHORITY_FIELD_REJECTED/.test(migrationSql));assert(/MIGRATED/.test(migrationSql));assert(!/INSERT\s+INTO\s+public\.(?:authority_records|commercial_reality_r4_records|route_authority_r5_records|contact_authority_r6_records|opportunities|engagement_)/i.test(migrationSql));});
check("canonical application read remains service-role only",()=>{assert(/marketroute_application_company_read_v1/.test(readSql));assert(/REVOKE ALL ON FUNCTION public\.marketroute_application_company_read_v1[\s\S]*FROM PUBLIC,anon,authenticated/i.test(readSql));assert(/GRANT EXECUTE ON FUNCTION public\.marketroute_application_company_read_v1[\s\S]*TO service_role/i.test(readSql));});
check("send-time gate rechecks executable authority immediately before claim",()=>{assert(/marketroute_engagement_send_gate_v1/.test(engagementSql));assert(/marketroute_opportunity_executable_now_v1\(v_queue\.opportunity_id,p_at\)/.test(engagementSql));assert(/v_gate:=public\.marketroute_engagement_send_gate_v1\(v_job\.queue_item_id,p_at\)/.test(engagementSql));assert(/BLOCKED_STALE/.test(engagementSql));});
check("unknown delivery state remains reconciliation-only",()=>{assert(/RECONCILIATION_REQUIRED/.test(engagementSql));assert(/ABANDONED_RUNNING_DELIVERY_MAY_HAVE_SENT/.test(engagementSql));});
check("weighted commercial authority vocabulary remains constitutionally forbidden",()=>{for(const col of db.forbiddenCommercialAuthorityColumns) assert(typeof col==="string"&&col.length>0);assert.equal(manifest.rules.opportunityWeightedScoreForbidden,true);assert.equal(manifest.rules.researchProviderCannotGrantAuthority,true);});
check("Build 18 live lineage tracer and cutover preflight exist",()=>{for(const f of ["scripts/certification/live-lineage-trace.mjs","scripts/certification/production-cutover-preflight.mjs"])assert(fs.existsSync(path.join(ROOT,f)),f);});
check("Build 18 certification is part of constitutional check",()=>{assert(pkg.scripts["constitution:check"].includes("constitution:certification"));assert(pkg.scripts["constitution:check"].includes("constitution:certification-adversarial"));});
check("production cutover explicitly requires real migrated lineage",()=>{const joined=release.cutoverRequirements.join(" ");for(const term of ["real migrated company","V2 Truth","R4, R5 and R6","claim provenance","source and evidence"])assert(joined.includes(term),term);});

let passed=0;
console.log("\nMarketRoute V2 Build 18 — release certification static gate");
for(const {name,fn} of checks){try{fn();passed++;console.log(`PASS  ${name}`);}catch(e){console.error(`FAIL  ${name}: ${e instanceof Error?e.message:e}`);}}
console.log(`\n${passed}/${checks.length} PASS`);
if(passed!==checks.length) process.exitCode=1;
