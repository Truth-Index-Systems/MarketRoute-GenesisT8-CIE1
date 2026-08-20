#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import {
  DATA_API_SQL_MAX_BYTES,
  EXPECTED_BASELINE_BYTES,
  EXPECTED_BASELINE_SHA256,
  EXPECTED_CANONICAL_MUTATIONS,
  EXPECTED_MAX_STATEMENT_BYTES,
  EXPECTED_STATEMENT_COUNT,
  inspectBaseline,
  readJson,
  sha256,
} from './build3-canonical-baseline-lib.mjs';

const repoRoot = process.cwd();
const baselinePath = path.resolve(repoRoot, process.env.MARKETROUTE_CANONICAL_BASELINE_PATH ?? 'database/aws/0001_marketroute_aws_canonical_baseline.sql');
const manifestPath = path.resolve(repoRoot, process.env.MARKETROUTE_CANONICAL_BASELINE_MANIFEST_PATH ?? 'database/aws/0001_marketroute_aws_canonical_baseline_manifest.json');

if (!fs.existsSync(baselinePath) || !fs.existsSync(manifestPath)) throw new Error('Canonical baseline and promotion manifest are required.');
const raw = fs.readFileSync(baselinePath, 'utf8');
const manifest = readJson(manifestPath);
const inspection = inspectBaseline(raw);

if (manifest.build !== 'AWS-V0-BUILD-3' || manifest.mode !== 'canonical-baseline-promotion') throw new Error('Unexpected canonical promotion manifest.');
if (manifest.status !== 'CANONICAL_BASELINE_PROMOTED_PENDING_MANUAL_AURORA_APPLICATION') throw new Error('Canonical baseline is not in promoted state.');
if (inspection.raw_sha256 !== EXPECTED_BASELINE_SHA256 || inspection.raw_sha256 !== manifest.canonical_baseline?.sha256) throw new Error('Canonical baseline SHA-256 drifted.');
if (inspection.raw_bytes !== EXPECTED_BASELINE_BYTES || inspection.raw_bytes !== manifest.canonical_baseline?.bytes) throw new Error('Canonical baseline byte size drifted.');
if (inspection.statement_count !== EXPECTED_STATEMENT_COUNT || inspection.statement_count !== manifest.data_api_application_contract?.canonical_statement_count) throw new Error('Canonical statement count drifted.');
if (inspection.max_statement_bytes !== EXPECTED_MAX_STATEMENT_BYTES || inspection.max_statement_bytes !== manifest.data_api_application_contract?.canonical_max_statement_bytes) throw new Error('Canonical maximum statement size drifted.');
if (inspection.max_statement_bytes > DATA_API_SQL_MAX_BYTES) throw new Error('Canonical SQL exceeds RDS Data API ExecuteStatement limit.');
if (inspection.mutation_count !== EXPECTED_CANONICAL_MUTATIONS || inspection.mutation_count !== manifest.canonical_baseline?.reviewed_top_level_data_mutation_count) throw new Error('Reviewed canonical mutation count drifted.');

const allowedMutationRelations = new Set([
  'truth_claim_policy_registry',
  'truth_claim_policy_bindings',
  'truth_entity_profile_registry',
  'authority_writer_registry',
  'commercial_reality_boundary_constitutions',
  'commercial_relationship_type_registry',
  'genesis_growth_industries',
  'genesis_growth_settings',
  'marketroute_plan_catalog',
]);
for (const mutation of inspection.mutations) {
  if (!mutation.relation || !allowedMutationRelations.has(mutation.relation)) {
    throw new Error(`Unreviewed canonical data mutation target: ${mutation.relation ?? 'UNKNOWN'} at statement ${mutation.index}.`);
  }
}

const blockerChecks = [
  ['auth.users', /\bauth\.users\b/i],
  ['auth.uid', /\bauth\.uid\s*\(/i],
  ['auth.role-or-jwt', /\bauth\.(?:role|jwt)\s*\(/i],
  ['request.jwt', /current_setting\s*\(\s*['"]request\.jwt\./i],
  ['legacy RLS enablement', /ENABLE\s+ROW\s+LEVEL\s+SECURITY/i],
  ['V1 ETL', /\bmarketroute_v1_migration_(?:batches|id_map|rejections|audit_events)\b/i],
  ['Supabase auth schema', /CREATE\s+SCHEMA\s+auth\b/i],
];
for (const [label, pattern] of blockerChecks) {
  if (pattern.test(raw)) throw new Error(`Canonical baseline contains prohibited ${label} dependency.`);
}
if (!/CREATE TABLE public\.marketroute_users\b/i.test(raw)) throw new Error('Internal MarketRoute user anchor missing.');
if ((raw.match(/REFERENCES public\.marketroute_users\(id\)/gi) ?? []).length !== 13) throw new Error('Internal user FK count drifted from 13.');
if ((raw.match(/p_actor_user_id uuid/gi) ?? []).length < 13) throw new Error('Explicit actor UUID contract is incomplete.');
if (manifest.postgresql16_validation?.blocker_count !== 0) throw new Error('Promotion manifest does not certify zero blockers.');
if (manifest.safety?.automatic_aurora_execution_allowed !== false || manifest.safety?.manual_aurora_application_gate_ready !== true) throw new Error('Promotion execution boundary drifted.');
if (manifest.safety?.prohibited_historical_data_import !== true) throw new Error('Historical-data prohibition missing.');
if (manifest.data_api_application_contract?.execute_statement_sql_max_bytes !== DATA_API_SQL_MAX_BYTES) throw new Error('Pinned Data API SQL limit drifted.');

console.log(JSON.stringify({
  build: manifest.build,
  mode: 'canonical-baseline-promotion-verification',
  status: 'PASS',
  sha256: inspection.raw_sha256,
  bytes: inspection.raw_bytes,
  statements: inspection.statement_count,
  max_statement_bytes: inspection.max_statement_bytes,
  reviewed_canonical_mutations: inspection.mutation_count,
  data_api_sql_limit_bytes: DATA_API_SQL_MAX_BYTES,
  postgresql16_blockers: manifest.postgresql16_validation.blocker_count,
  automatic_aurora_execution_allowed: false,
  manual_aurora_application_gate_ready: true,
}, null, 2));
