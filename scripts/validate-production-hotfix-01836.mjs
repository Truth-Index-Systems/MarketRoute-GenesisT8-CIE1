import fs from "node:fs";
import assert from "node:assert/strict";

const migration=fs.readFileSync(new URL("../supabase/migrations/0026_route_relationship_claim_fingerprint_version_hotfix.sql",import.meta.url),"utf8");
const build7=fs.readFileSync(new URL("../supabase/migrations/0010_relationship_truth_and_route_authority_r5.sql",import.meta.url),"utf8");
const checks=[];
function check(name,fn){try{fn();checks.push([name,true]);}catch(e){checks.push([name,false,e?.message??String(e)]);}}
check("replaces only relationship ensure RPC",()=>{assert.match(migration,/CREATE OR REPLACE FUNCTION public\.marketroute_ensure_commercial_relationship_v1/);assert.doesNotMatch(migration,/CREATE TABLE|ALTER TABLE|DROP TABLE/i);});
check("relationship claim supplies fingerprint_version",()=>assert.match(migration,/claim_fingerprint,fingerprint_version\)\s*VALUES[\s\S]*'MRV2-CLAIM-FP-1\.0\.0'/));
check("canonical Build7 source also repaired",()=>assert.match(build7,/claim_fingerprint,fingerprint_version\)\s*VALUES[\s\S]*'MRV2-CLAIM-FP-1\.0\.0'/));
check("no constraint weakening",()=>assert.doesNotMatch(migration,/DROP CONSTRAINT|ALTER COLUMN\s+fingerprint_version\s+DROP NOT NULL/i));
check("service-role boundary preserved",()=>{assert.match(migration,/marketroute_require_service_role/);assert.match(migration,/GRANT EXECUTE[\s\S]*TO service_role/);});
check("relationship canonical versions unchanged",()=>{assert.match(migration,/MRV2-RELATIONSHIP-CANON-1\.0\.0/);assert.match(migration,/MRV2-RELATIONSHIP-1\.0\.0/);assert.match(migration,/MRV2-RELATIONSHIP-CLAIM-1\.0\.0/);});
check("no authority writes added",()=>assert.doesNotMatch(migration,/authority_records|commercial_reality_r4_records|contact_authority_r6_records/i));
check("transactional live hotfix",()=>{assert.match(migration,/BEGIN;/);assert.match(migration,/COMMIT;/);});
for(const [n,ok,msg] of checks) console.log(`${ok?"PASS":"FAIL"} ${n}${msg?`: ${msg}`:""}`);
if(checks.some(([,ok])=>!ok)) process.exit(1);
console.log(`\n${checks.length}/${checks.length} route hotfix checks passed.`);
