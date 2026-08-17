import assert from "node:assert/strict";import fs from "node:fs";import path from "node:path";
const root=path.resolve(import.meta.dirname,"../..");const read=p=>fs.readFileSync(path.join(root,p),"utf8");const sql=read("supabase/migrations/0041_product_conversational_intelligence.sql");const service=read("application/conversation/service.ts");const ai=read("platform/ai/openai-responses.ts");
const tests=[
 ["prompt injection cannot grant narrator commercial authority",()=>{assert.match(service,/facts are authoritative inputs, not suggestions/i);assert.match(service,/Never recalculate or override commercial authority/i);assert.match(service,/Never invent a company fact, contact, route, email, phone number/i)}],
 ["narrator cannot independently browse for new evidence",()=>{assert.doesNotMatch(service,/webSearch:true/);assert.match(service,/Web search is forbidden for narration/i)}],
 ["invented evidence IDs are rejected",()=>{assert.match(service,/refs\.some\(ref=>!allowed\.has\(ref\)\)/);assert.match(service,/MARKETROUTE_NARRATOR_EVIDENCE_REFERENCE_INVALID/)}],
 ["internal authority jargon is rejected from customer narration",()=>{assert.match(service,/internalLanguage/);assert.match(service,/MARKETROUTE_NARRATOR_INTERNAL_LANGUAGE_REJECTED/)}],
 ["AI outage cannot block canonical product state",()=>{assert.match(service,/catch\{[\s\S]*return fallbackValue;\}/);assert.match(service,/DETERMINISTIC_FALLBACK/)}],
 ["browser cannot read narration cache directly",()=>{assert.match(sql,/REVOKE ALL ON public\.marketroute_conversation_narration_cache FROM PUBLIC,anon,authenticated/);assert.doesNotMatch(sql,/GRANT SELECT[^\n]+(?:anon|authenticated)/i)}],
 ["cache poisoning must match source lineage",()=>{assert.match(sql,/MARKETROUTE_CONVERSATION_PAYLOAD_LINEAGE_INVALID/);assert.match(sql,/p_payload_json->>'sourceFingerprint'[^\n]+p_input_fingerprint/)}],
 ["conversational migration cannot write authority tables",()=>{assert.doesNotMatch(sql,/INSERT\s+INTO\s+public\.(?:commercial_reality_r4_records|route_authority_r5_records|contact_authority_r6_records|authority_records|opportunities)/i);assert.match(sql,/'ai_authority_granted',false/)}],
 ["dedicated narrator model cannot silently replace all AI model selection",()=>{assert.match(ai,/input\.model\?\.trim\(\)\|\|openAIModel\(\)/);assert.match(service,/OPENAI_NARRATOR_MODEL/)}],
];
let passed=0;console.log("\nMarketRoute V2 Product Build 21 — Conversational Intelligence adversarial gate");for(const [name,fn] of tests){try{fn();passed++;console.log(`PASS  ${name}`)}catch(e){console.error(`FAIL  ${name}: ${e instanceof Error?e.message:e}`)}}console.log(`\n${passed}/${tests.length} PASS`);if(passed!==tests.length)process.exitCode=1;
