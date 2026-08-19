import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const ROOT=path.resolve(import.meta.dirname,"../..");
const release=JSON.parse(fs.readFileSync(path.join(ROOT,"constitution/release-certification.json"),"utf8"));
const manifest=JSON.parse(fs.readFileSync(path.join(ROOT,"constitution/authority-manifest.json"),"utf8"));
const requiredFiles=[
  "supabase/migrations/0019_v1_evidence_migration.sql",
  "NO-SUPABASE-MIGRATION-BUILD18.txt",
  "scripts/certification/live-lineage-trace.mjs",
  "MARKETROUTE-V2-BUILD18-RED-TEAM-CERTIFICATION.md"
];
const checks=[];const check=(name,fn)=>checks.push({name,fn});
check("release candidate is Build 18",()=>assert.equal(release.build,18));
check("source certification passed",()=>assert.equal(release.sourceCertification,"PASS"));
check("authority writer count remains three",()=>assert.equal(manifest.authorityWriters.length,3));
check("Build 17 remains schema owner",()=>assert.equal(manifest.schemaBuild,17));
check("post-freeze operational migrations are explicitly declared",()=>{assert.equal(release.databaseMigrationRequired,true);assert.equal(release.latestOperationalMigration,64);assert(Array.isArray(release.operationalMigrations)&&release.operationalMigrations.length>=2);assert(release.operationalMigrations.every(m=>m.authorityWriter===false));});
for(const file of requiredFiles)check(`required cutover artifact exists: ${file}`,()=>assert(fs.existsSync(path.join(ROOT,file)),file));
check("live trace remains mandatory before production cutover",()=>assert.equal(manifest.rules.productionCutoverRequiresLiveLineageTrace,true));

let passed=0;console.log("\nMarketRoute V2 Build 18 — production cutover preflight");
for(const {name,fn} of checks){try{fn();passed++;console.log(`PASS  ${name}`);}catch(e){console.error(`FAIL  ${name}: ${e instanceof Error?e.message:e}`);}}
console.log(`\n${passed}/${checks.length} PASS`);
console.log("\nNEXT  Run `npm run certification:live-lineage` with MARKETROUTE_CERT_ORGANISATION_ID, MARKETROUTE_CERT_CAMPAIGN_ID and MARKETROUTE_CERT_COMPANY_ID against the migrated V2 production candidate.");
if(passed!==checks.length)process.exitCode=1;
