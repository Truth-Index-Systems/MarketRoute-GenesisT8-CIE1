import fs from "node:fs";
import path from "node:path";
import { ROOT, assert, check, printResults } from "./lib/constitution.mjs";
const s = fs.readFileSync(path.join(ROOT,"supabase/migrations/0019_v1_evidence_migration.sql"),"utf8");
const x=[];
const forbiddenWriteTables=[
  "authority_records","authority_events","commercial_reality_r4_records","route_authority_r5_records","contact_authority_r6_records",
  "truth_claim_snapshots","truth_entity_snapshots","opportunities","opportunity_workflow_events","opportunity_human_reviews",
  "engagement_strategies","engagement_messages","engagement_message_approvals","engagement_delivery_jobs"
];
x.push(check("Build 17 creates no authority writer",()=>assert(!/INSERT\s+INTO\s+public\.authority_writer_registry/i.test(s),"authority writer")));
x.push(check("Build 17 never writes authority truth workflow or engagement tables",()=>{for(const table of forbiddenWriteTables){const r=new RegExp(`\\b(INSERT\\s+INTO|UPDATE|DELETE\\s+FROM)\\s+public\\.${table}\\b`,`i`);assert(!r.test(s),table)}}));
x.push(check("Build 17 has no V1 database connection primitive",()=>assert(!/postgres_fdw|dblink|http_post|http_get|create\s+server|foreign\s+table/i.test(s),"live V1 bridge")));
x.push(check("service role is required by public import RPCs",()=>{for(const name of ["begin_v1_migration","import_v1_company","import_v1_person","import_v1_access_point","import_v1_seller_business","import_v1_seller_source","import_v1_campaign","import_v1_campaign_scope","import_v1_evidence","import_v1_historical_research","reject_v1_migration_record","complete_v1_migration","v1_migration_report"]){const i=s.indexOf(`marketroute_${name}_v1`);assert(i>=0,name);const c=s.slice(i,i+1800);assert(c.includes("marketroute_require_service_role()"),`${name}: service role`)}}));
x.push(check("authenticated and anon cannot execute migration RPCs",()=>assert((s.match(/FROM PUBLIC,anon,authenticated/g)??[]).length>=13,"revokes")));
x.push(check("only factual core entity tables are directly inserted",()=>{for(const table of ["companies","people","seller_businesses","campaigns","organisation_company_scopes"]){assert(new RegExp(`INSERT\\s+INTO\\s+public\\.${table}`,"i").test(s),table)}}));
x.push(check("evidence writes reuse canonical Build 3 RPC",()=>assert(s.includes("marketroute_ingest_evidence_v1")&&s.includes("marketroute_record_claim_evidence_v1"),"evidence RPC")));
x.push(check("seller source material reuses canonical Build 5 RPC",()=>assert(s.includes("marketroute_record_seller_genome_source_v1"),"seller source RPC")));
x.push(check("contact channels create nodes but no relationship edges",()=>assert(s.includes("marketroute_ensure_graph_node_v1")&&!s.includes("marketroute_ensure_commercial_relationship_v1("),"no relationship import")));
x.push(check("no old authority data is stored in rejection payloads",()=>assert(!/marketroute_v1_migration_rejections[\s\S]{0,600}payload_json/i.test(s),"raw rejection payload")));
x.push(check("release declares zero authority truth workflow import",()=>assert(s.includes("'authority_import_forbidden',true")&&s.includes("'truth_import_forbidden',true")&&s.includes("'workflow_import_forbidden',true"),"release metadata")));
x.push(check("migration tables use RLS and service-only reads",()=>assert((s.match(/ENABLE ROW LEVEL SECURITY/g)??[]).length>=4&&(s.match(/TO service_role/g)??[]).length>=17,"privileges")));
printResults("MarketRoute V2 Build 17 — SQL safety",x);
