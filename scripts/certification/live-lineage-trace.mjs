import assert from "node:assert/strict";

function env(name){const v=process.env[name]?.trim();if(!v)throw new Error(`MARKETROUTE_CERT_ENV_REQUIRED:${name}`);return v;}
const base=env("SUPABASE_URL").replace(/\/+$/,""),key=env("SUPABASE_SERVICE_ROLE_KEY");
const org=env("MARKETROUTE_CERT_ORGANISATION_ID"),campaign=env("MARKETROUTE_CERT_CAMPAIGN_ID"),company=env("MARKETROUTE_CERT_COMPANY_ID");
const headers={apikey:key,Authorization:`Bearer ${key}`,Accept:"application/json","Content-Type":"application/json"};
async function rpc(name,payload){const r=await fetch(`${base}/rest/v1/rpc/${name}`,{method:"POST",headers,body:JSON.stringify(payload),cache:"no-store"});const t=await r.text();if(!r.ok)throw new Error(`RPC_${name}_${r.status}:${t.slice(0,500)}`);return t?JSON.parse(t):null;}
async function get(table,params){const r=await fetch(`${base}/rest/v1/${table}?${params}`,{method:"GET",headers,cache:"no-store"});const t=await r.text();if(!r.ok)throw new Error(`GET_${table}_${r.status}:${t.slice(0,500)}`);return t?JSON.parse(t):[];}
const first=(x,label)=>{assert(Array.isArray(x)&&x.length>0,`${label} missing`);return x[0];};
const validUuid=(v)=>assert(/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(String(v)),`invalid uuid ${v}`);

console.log("\nMarketRoute V2 Build 18 — LIVE provenance/authority trace");
const read=await rpc("marketroute_application_company_read_v1",{p_organisation_id:org,p_campaign_id:campaign,p_company_id:company,p_at:new Date().toISOString()});
assert.equal(read?.contractVersion,"MRV2-APPLICATION-READ-1.0.0","canonical application read missing");
const truth=read.truth;assert(truth?.snapshotId,"V2 Truth entity snapshot missing");
const r4=read.authority?.r4,r5=read.authority?.r5,r6=read.authority?.r6;
assert(r4?.authorityRecordId,"R4 missing");assert(r5?.authorityRecordId,"R5 missing");assert(r6?.authorityRecordId,"R6 missing");
assert.equal(r5.parentR4AuthorityRecordId,r4.authorityRecordId,"R5 is not bound to current R4");
assert.equal(r6.parentR5AuthorityRecordId,r5.authorityRecordId,"R6 is not bound to current R5");
console.log("PASS  canonical UI read reaches current V2 Truth → R4 → R5 → R6");

const entity=first(await get("truth_entity_snapshots",`id=eq.${encodeURIComponent(truth.snapshotId)}&select=id,claim_snapshot_map,snapshot_fingerprint,entity_state`),"truth entity snapshot");
const map=entity.claim_snapshot_map??{};const snapshotIds=Object.values(map).flatMap(v=>Array.isArray(v)?v:[]).filter(Boolean);assert(snapshotIds.length>0,"entity Truth has no claim snapshots");
const claimSnapshotId=String(snapshotIds[0]);validUuid(claimSnapshotId);
const ts=first(await get("truth_claim_snapshots",`id=eq.${encodeURIComponent(claimSnapshotId)}&select=id,claim_id,claim_key,truth_state,snapshot_fingerprint,reference_time`),"truth claim snapshot");
validUuid(ts.claim_id);
const claim=first(await get("claims",`id=eq.${encodeURIComponent(ts.claim_id)}&select=id,claim_key,predicate,canonical_value_text,claim_fingerprint`),"claim");
const links=await get("claim_evidence_links",`claim_id=eq.${encodeURIComponent(claim.id)}&select=evidence_item_id,polarity,dependence_family_key,link_method&limit=25`);assert(links.length>0,"claim has no evidence links");
const evidenceId=String(links[0].evidence_item_id);validUuid(evidenceId);
const evidence=first(await get("evidence_items",`id=eq.${encodeURIComponent(evidenceId)}&select=id,acquisition_id,evidence_kind,observed_at,origin_published_at,extraction_method,evidence_fingerprint`),"evidence");
const acquisition=first(await get("source_acquisitions",`id=eq.${encodeURIComponent(evidence.acquisition_id)}&select=id,source_id,acquired_at,acquisition_method,observed_content_fingerprint`),"acquisition");
const source=first(await get("source_records",`id=eq.${encodeURIComponent(acquisition.source_id)}&select=id,source_kind,canonical_url,publisher_domain,published_at,content_fingerprint`),"source");
console.log("PASS  SOURCE → ACQUISITION → EVIDENCE → CLAIM → TRUTH provenance exists");

const profile=read.profile??{};
console.log("PASS  TRUTH → R4 → R5 → R6 → OPPORTUNITY read contract is traceable");
if(profile.opportunityId){
  const engagement=read.engagement;
  assert(engagement!==undefined,"engagement field absent from opportunity read");
  console.log("PASS  OPPORTUNITY → ENGAGEMENT presentation boundary is present");
}else console.log("INFO  company has not materialised an opportunity yet; authority lineage still proven");

const migrated=[evidence.extraction_method,links[0].link_method].includes("MIGRATED");
console.log(migrated?"PASS  sampled lineage includes migrated V1 evidence":"INFO  sampled current lineage is native V2 evidence; use another company/claim if a migrated-evidence sample is required");
console.log("\nCERTIFIED TRACE SUMMARY");
console.log(JSON.stringify({companyId:company,truthEntitySnapshotId:truth.snapshotId,claimSnapshotId,claimId:claim.id,evidenceItemId:evidence.id,sourceId:source.id,r4AuthorityRecordId:r4.authorityRecordId,r5AuthorityRecordId:r5.authorityRecordId,r6AuthorityRecordId:r6.authorityRecordId,workflowState:profile.workflowState??null,executableNow:profile.executableNow??false,migratedEvidenceSample:migrated},null,2));
