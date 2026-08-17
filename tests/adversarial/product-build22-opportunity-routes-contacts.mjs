import assert from "node:assert/strict";import fs from "node:fs";import path from "node:path";
const root=path.resolve(import.meta.dirname,"../..");const read=p=>fs.readFileSync(path.join(root,p),"utf8");const sql=read("supabase/migrations/0042_product_opportunity_routes_contacts.sql");const presentation=read("application/opportunities/contact-route-presentation.ts");const card=read("ui/intelligence/contact-route-card.tsx");const page=read("app/app/opportunities/[campaignId]/[companyId]/page.tsx");const conversation=read("application/conversation/service.ts");
const tests=[
 ["one authorised channel cannot unlock an unverified sibling channel",()=>{assert.match(presentation,/statusKey=authorised\?"ready":"research"/);assert.match(presentation,/groupKey=.*statusKey/)}],
 ["structural route view cannot reveal unverified named-contact values",()=>{assert.match(page,/kind==="PERSON"\?"Named contact under verification"/);assert.match(page,/kind==="ACCESS_POINT"\?"Contact route under verification"/)}],
 ["phone absence is explicit rather than silently omitted",()=>{assert.match(card,/Phone not found yet/)}],
 ["contact values are never fabricated in presentation code",()=>{assert.match(presentation,/const value=text\(terminal\.canonicalValue\)/);assert.doesNotMatch(presentation,/guess|infer.*email|generate.*phone/i)}],
 ["unsafe schemes cannot become external links",()=>{assert.match(presentation,/url\.protocol==="http:"\|\|url\.protocol==="https:"/);assert.doesNotMatch(card,/dangerouslySetInnerHTML/)}],
 ["route projection cannot write authority tables",()=>{assert.doesNotMatch(sql,/INSERT\s+INTO\s+public\.(?:commercial_reality_r4_records|route_authority_r5_records|contact_authority_r6_records|authority_records|opportunities)/i);assert.match(sql,/'read_only_projection',true/)}],
 ["browser roles cannot call enriched route projection directly",()=>{assert.match(sql,/REVOKE ALL ON FUNCTION public\.marketroute_application_route_display_read_v1[\s\S]*anon,authenticated/)}],
 ["narrator is not given raw email or phone values",()=>{assert.doesNotMatch(conversation,/terminal\.canonicalValue/);assert.match(conversation,/terminal\.accessPointKind/)}],
 ["ready route ordering is not described as a commercial ranking",()=>{assert.doesNotMatch(card,/BEST ROUTE|best route|strongest route/i);assert.doesNotMatch(page,/best route/i)}],
 ["evidence links use server-projected truth snapshot IDs only",()=>{assert.match(sql,/contact_truth_snapshot_map/);assert.match(card,/encodeURIComponent\(snapshotId\)/)}],
];
let passed=0;console.log("\nMarketRoute V2 Product Build 22 — Opportunities, Routes & Contacts adversarial gate");for(const [name,fn] of tests){try{fn();passed++;console.log(`PASS  ${name}`)}catch(e){console.error(`FAIL  ${name}: ${e instanceof Error?e.message:e}`)}}console.log(`\n${passed}/${tests.length} PASS`);if(passed!==tests.length)process.exitCode=1;
