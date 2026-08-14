import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import {spawnSync} from "node:child_process";

const ROOT=path.resolve(import.meta.dirname,"../..");
const delegated=[
  ["architecture boundary","scripts/validate-architecture.mjs"],
  ["AI authority boundary","scripts/validate-ai-boundary.mjs"],
  ["legacy eradication","scripts/validate-no-legacy.mjs"],
  ["Truth epistemic attacks","tests/adversarial/build4-truth-engine.mjs"],
  ["R4 commercial reality attacks","tests/adversarial/build6-commercial-reality.mjs"],
  ["R5 relationship attacks","tests/adversarial/build7-relationship-graph.mjs"],
  ["R6 contact attacks","tests/adversarial/build8-contact-authority.mjs"],
  ["authority lifecycle attacks","tests/adversarial/build9-authority-lifecycle.mjs"],
  ["research/AI-output attacks","tests/adversarial/build10-research-engine.mjs"],
  ["opportunity ordering attacks","tests/adversarial/build11-opportunity-engine.mjs"],
  ["engagement/send-gate attacks","tests/adversarial/build12-engagement-engine.mjs"],
  ["read-model attacks","tests/adversarial/build13-read-model.mjs"],
  ["UI boundary attacks","tests/adversarial/build15-core-ui.mjs"],
  ["V1 migration attacks","tests/adversarial/build17-v1-migration.mjs"],
];
const tests=[];const test=(name,fn)=>tests.push({name,fn});
for(const [name,file] of delegated)test(name,()=>{const r=spawnSync(process.execPath,[file],{cwd:ROOT,encoding:"utf8"});if(r.status!==0)throw new Error(`${file} failed\n${r.stdout}\n${r.stderr}`);});
const read=(p)=>fs.readFileSync(path.join(ROOT,p),"utf8");
const research=read("core/research/planner.ts");
const engagement=read("supabase/migrations/0015_engagement_engine.sql");
const lifecycle=read("supabase/migrations/0012_unified_authority_lifecycle.sql");
const r5=read("supabase/migrations/0010_relationship_truth_and_route_authority_r5.sql");
const r6=read("supabase/migrations/0011_contact_truth_and_authority_r6.sql");
const migration=read("supabase/migrations/0019_v1_evidence_migration.sql");
const ui=read("application/read-model/presentation.ts")+"\n"+read("ui/application/language.ts");

test("prompt-injection text has no privileged execution path",()=>{assert(/assertResearchProviderResultSafe/.test(research));assert(!/eval\s*\(|new Function\s*\(/.test(research));});
test("AI numeric authority is recursively rejected",()=>assert(/confidence\|probability\|score\|rank\|weight\|authority\|viability/.test(research)));
test("reversed relationship direction cannot become a valid path",()=>{assert(/direction/i.test(r5));assert(/MARKETROUTE_R5_[A-Z_]*(?:DIRECTION|PATH)/.test(r5));});
test("contact authority proves exact employment/channel claims",()=>{for(const s of ["employment.current","role.current","ownership.current"])assert(r6.includes(s),s);});
test("APPROVED workflow alone is never executable",()=>{assert(/workflow_state='APPROVED'/.test(lifecycle));assert(/AUTHORITY_READY/.test(lifecycle));});
test("queued message cannot survive stale authority",()=>{assert(/BLOCKED_STALE/.test(engagement));assert(/marketroute_engagement_send_gate_v1/.test(engagement));});
test("migration cannot smuggle READY or R4-R6 authority",()=>{for(const s of ["ready","r4","r5","r6","confidence","score"])assert(new RegExp(s,"i").test(migration),s);assert(/MARKETROUTE_V1_AUTHORITY_FIELD_REJECTED/.test(migration));});
test("UI research-strength thresholds remain presentation-only",()=>{assert(/Strong research base|Good research base|Partial research base/.test(ui));assert(!/persist_|authority_records|commercial_reality_r4_records|route_authority_r5_records|contact_authority_r6_records/.test(ui));});

let passed=0;console.log("\nMarketRoute V2 Build 18 — full red-team replay");
for(const {name,fn} of tests){try{fn();passed++;console.log(`PASS  ${name}`);}catch(e){console.error(`FAIL  ${name}: ${e instanceof Error?e.message:e}`);}}
console.log(`\n${passed}/${tests.length} PASS`);if(passed!==tests.length)process.exitCode=1;
