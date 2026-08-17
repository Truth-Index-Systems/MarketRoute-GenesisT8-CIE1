import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
const root=path.resolve(import.meta.dirname,"../..");
const read=p=>fs.readFileSync(path.join(root,p),"utf8");
const sql=read("supabase/migrations/0040_product_anonymous_discovery_pipeline.sql");
const service=read("application/discovery/service.ts");
const start=read("app/api/discovery/start/route.ts");
const status=read("app/api/discovery/status/route.ts");
const tests=[
  ["replaying a browser identity reuses rather than creates another run",()=>{assert.match(sql,/browser_key_hash text NOT NULL UNIQUE/);assert.match(sql,/SELECT \* INTO v_existing FROM public\.anonymous_discovery_runs WHERE browser_key_hash=p_browser_key_hash/);assert.match(sql,/IF FOUND THEN RETURN jsonb_build_object\('runId',v_existing\.id,'existing',true\)/)}],
  ["forging a browser token cannot reveal raw contact intelligence",()=>{assert.match(status,/anonymousDiscoveryServiceFromEnvironment\(\)\.status\(secret\)/);assert.doesNotMatch(status,/platform\/database|SUPABASE/);const fn=sql.slice(sql.indexOf("CREATE OR REPLACE FUNCTION public.marketroute_anonymous_discovery_status_v1"));const ret=fn.slice(fn.indexOf("RETURN jsonb_build_object"),fn.indexOf("END;\n$fn$;"));for(const forbidden of ["email","phone","linkedin","contact_name","contact_value","spentusd","reservedusd","lifetimebudgetusd"])assert.equal(ret.toLowerCase().includes(forbidden),false,forbidden)}],
  ["refreshing after midnight cannot reset free research money",()=>{assert.match(sql,/SELECT COALESCE\(sum\(amount_usd\),0\) INTO v_anon_spent[\s\S]*event_type='COMMIT'/);assert.doesNotMatch(sql,/v_anon_spent[\s\S]{0,250}date_trunc\('day'/)}],
  ["expired anonymous work cannot be newly planned or claimed",()=>{assert.match(sql,/a\.research_expires_at>now\(\)/);assert.match(sql,/a\.research_expires_at<=p_at/);assert.match(sql,/MARKETROUTE_ANONYMOUS_RESEARCH_WINDOW_CLOSED/)}],
  ["anonymous visitor cannot choose the research budget",()=>{assert.doesNotMatch(start,/form\.get\(["'](?:budget|cost|researchBudget)/i);assert.match(service,/MARKETROUTE_ANONYMOUS_RESEARCH_BUDGET_USD/)}],
  ["raw network address is not persisted",()=>{assert.equal(sql.toLowerCase().includes("ip_address"),false);assert.match(service,/anonymousIpHash/);assert.match(service,/createHmac\("sha256"/)}],
  ["anonymous workspace cannot masquerade as a normal customer workspace",()=>{assert.match(sql,/workspace_kind='CUSTOMER' AND created_by IS NOT NULL/);assert.match(sql,/workspace_kind='ANONYMOUS_DISCOVERY' AND created_by IS NULL/);assert.match(sql,/MARKETROUTE_ACTIVATION_CREATOR_SCOPE_INVALID/)}],
  ["anonymous flow cannot introduce commercial authority",()=>{const forbidden=/INSERT\s+INTO\s+public\.(commercial_reality_r4_records|route_authority_r5_records|contact_authority_r6_records|opportunity_authority_records)/i;assert.equal(forbidden.test(sql),false);assert.match(sql,/'new_authority_writer',false/)}],
];
let passed=0;console.log("\nMarketRoute V2 Product Build 20 — Anonymous Discovery adversarial gate");
for(const [name,fn] of tests){try{fn();passed++;console.log(`PASS  ${name}`)}catch(e){console.error(`FAIL  ${name}: ${e instanceof Error?e.message:e}`)}}
console.log(`\n${passed}/${tests.length} PASS`);if(passed!==tests.length)process.exitCode=1;
