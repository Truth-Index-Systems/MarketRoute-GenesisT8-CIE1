import fs from "node:fs";
import path from "node:path";
import { ROOT, assert, check, printResults } from "../../scripts/lib/constitution.mjs";

const sql = fs.readdirSync(path.join(ROOT, "supabase/migrations"))
  .filter((n) => /^000[1-5]_.*\.sql$/.test(n))
  .sort()
  .map((n) => fs.readFileSync(path.join(ROOT, "supabase/migrations", n), "utf8"))
  .join("\n");
const lower = sql.toLowerCase();

const results = [
  check("attack: UI user cannot INSERT authority", () => assert(/revoke all on public\.authority_records from anon, authenticated, service_role/i.test(sql), "authority table not locked")),
  check("attack: service role cannot INSERT authority directly", () => assert(!/grant\s+[^;]*insert[^;]*on\s+public\.authority_records\s+to\s+service_role/i.test(sql), "service role INSERT authority grant exists")),
  check("attack: arbitrary writer context still needs registry entry", () => assert(/authority_writer_registry[\s\S]*r\.enabled\s*=\s*true/i.test(sql), "registry not enforced")),
  check("attack: writer cannot claim a different authority stage", () => assert(/r\.authority_stage\s*=\s*NEW\.authority_stage/i.test(sql), "stage mismatch not rejected")),
  check("attack: writer cannot claim a different writer version", () => assert(/r\.writer_version\s*=\s*NEW\.writer_version/i.test(sql), "version mismatch not rejected")),
  check("attack: authority cannot be immortal", () => assert(/valid_until\s+timestamptz\s+not\s+null/i.test(sql), "immortal authority possible")),
  check("attack: opportunity workflow cannot embed commercial score", () => {
    const opp = lower.match(/create table public\.opportunities\s*\(([\s\S]*?)\n\);/)?.[1] ?? "";
    assert(!/(score|confidence|viable|authority)/.test(opp), "authority/scoring field leaked into workflow");
  }),
  check("attack: evidence cannot masquerade as probability", () => {
    const evidence = lower.match(/create table public\.evidence_items\s*\(([\s\S]*?)\n\);/)?.[1] ?? "";
    assert(!/(probability|confidence|truth_state)/.test(evidence), "derived belief field stored on raw evidence");
  }),
  check("attack: reasoning result cannot automatically be authority", () => {
    const artifacts = lower.match(/create table public\.reasoning_artifacts\s*\(([\s\S]*?)\n\);/)?.[1] ?? "";
    assert(!/(authority_stage|decision_code|valid_until)/.test(artifacts), "authority semantics leaked into reasoning artifact");
  }),
  check("attack: claim edits cannot erase history", () => assert(/claims_append_only[\s\S]*before update or delete on public\.claims/i.test(sql), "claims mutable")),
  check("attack: evidence edits cannot erase history", () => assert(/evidence_items_append_only[\s\S]*before update or delete on public\.evidence_items/i.test(sql), "evidence mutable")),
  check("attack: human review history cannot be rewritten", () => assert(/opportunity_human_reviews_append_only[\s\S]*before update or delete/i.test(sql), "human review mutable")),
  check("attack: authenticated client cannot change opportunity workflow", () => assert(!/grant\s+[^;]*update[^;]*on\s+public\.opportunities\s+to\s+authenticated/i.test(sql), "client workflow update grant found")),
  check("attack: backend cannot bypass future workflow RPC with direct UPDATE", () => assert(/revoke all on public\.opportunities from[^;]*service_role/i.test(lower), "service role workflow mutation not revoked")),
  check("attack: campaign cannot cross organisation boundary", () => assert(/campaigns_seller_business_scope_fk[\s\S]*foreign key \(organisation_id, seller_business_id\)/i.test(sql), "seller/campaign tenant FK missing")),
  check("attack: opportunity cannot reference campaign from another organisation", () => assert(/opportunities_campaign_scope_fk[\s\S]*foreign key \(organisation_id, campaign_id\)/i.test(sql), "opportunity/campaign tenant FK missing")),
  check("attack: reasoning run cannot cross campaign tenant boundary", () => assert(/reasoning_runs_campaign_scope_fk[\s\S]*foreign key \(organisation_id, campaign_id\)/i.test(sql), "reasoning tenant FK missing")),
  check("attack: authority cannot cite a reasoning run from another tenant/input", () => assert(/MARKETROUTE_AUTHORITY_REASONING_LINEAGE_MISMATCH/i.test(sql), "reasoning lineage mismatch guard absent")),
  check("attack: global claims cannot consume tenant-private evidence", () => assert(/MARKETROUTE_GLOBAL_CLAIM_CANNOT_USE_PRIVATE_EVIDENCE/i.test(sql), "global/private evidence guard absent")),
  check("attack: tenant claim cannot consume another tenant's evidence", () => assert(/MARKETROUTE_CLAIM_EVIDENCE_TENANT_MISMATCH/i.test(sql), "tenant evidence mismatch guard absent")),
  check("attack: claim supersession cannot jump subject or tenant scope", () => assert(/MARKETROUTE_CLAIM_SUPERSESSION_SCOPE_MISMATCH/i.test(sql), "claim supersession scope guard absent")),
  check("attack: no V1 table or RPC names exist in Build 2 migrations", () => assert(!/(salespilot|commercial_routes|contact_discovery_sessions|review_salespilot|genesis_g4|genesis_g5)/i.test(sql), "legacy runtime noun found")),
];

printResults("MarketRoute V2 Build 2 — adversarial database boundaries", results);
