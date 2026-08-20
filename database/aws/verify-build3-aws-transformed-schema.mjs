#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const repoRoot = process.cwd();
const outputDir = path.resolve(repoRoot, process.env.MARKETROUTE_AWS_DATABASE_DIR ?? 'database/aws');
const transformManifestPath = path.join(outputDir, 'build3_aws_final_transform_manifest.json');
const schemaPath = path.resolve(
  repoRoot,
  process.env.MARKETROUTE_AWS_TRANSFORMED_SCHEMA ?? 'database/aws/build3_aws_transformed_reference_schema.sql',
);
const outputManifestPath = path.join(outputDir, 'build3_aws_transformed_schema_manifest.json');

const ACTOR_FUNCTIONS = new Set([
  'marketroute_claim_anonymous_discovery_v1',
  'marketroute_create_organisation',
  'marketroute_create_workspace_with_seller_v1',
  'marketroute_is_org_admin',
  'marketroute_is_org_member',
  'marketroute_manage_campaign_v1',
  'marketroute_submit_campaign_v2',
  'marketroute_submit_campaign_v3',
  'marketroute_submit_replacement_campaign_v1',
  'marketroute_submit_workspace_activation_v1',
  'marketroute_submit_workspace_activation_v2',
  'marketroute_workspace_activation_status_v1',
  'marketroute_workspace_activation_status_v2',
]);

function sha256(text) {
  return crypto.createHash('sha256').update(text).digest('hex');
}
function countMatches(text, pattern) {
  return [...text.matchAll(pattern)].length;
}
function splitTopLevelSql(sql) {
  const statements = [];
  let start = 0;
  let i = 0;
  let mode = 'normal';
  let dollarTag = null;
  while (i < sql.length) {
    const ch = sql[i];
    const next = sql[i + 1];
    if (mode === 'line-comment') { if (ch === '\n') mode = 'normal'; i += 1; continue; }
    if (mode === 'block-comment') { if (ch === '*' && next === '/') { mode = 'normal'; i += 2; } else i += 1; continue; }
    if (mode === 'single') { if (ch === "'" && next === "'") i += 2; else if (ch === "'") { mode = 'normal'; i += 1; } else i += 1; continue; }
    if (mode === 'double') { if (ch === '"' && next === '"') i += 2; else if (ch === '"') { mode = 'normal'; i += 1; } else i += 1; continue; }
    if (mode === 'dollar') { if (sql.startsWith(dollarTag, i)) { i += dollarTag.length; mode = 'normal'; dollarTag = null; } else i += 1; continue; }
    if (ch === '-' && next === '-') { mode = 'line-comment'; i += 2; continue; }
    if (ch === '/' && next === '*') { mode = 'block-comment'; i += 2; continue; }
    if (ch === "'") { mode = 'single'; i += 1; continue; }
    if (ch === '"') { mode = 'double'; i += 1; continue; }
    if (ch === '$') {
      const match = sql.slice(i).match(/^\$[A-Za-z_][A-Za-z0-9_]*\$|^\$\$/);
      if (match) { dollarTag = match[0]; mode = 'dollar'; i += dollarTag.length; continue; }
    }
    if (ch === ';') {
      const text = sql.slice(start, i + 1).trim();
      if (text) statements.push(text);
      start = i + 1;
    }
    i += 1;
  }
  const tail = sql.slice(start).trim();
  if (tail) statements.push(tail);
  return statements;
}
function stripLeadingNoise(sql) {
  let value = sql.trimStart();
  for (;;) {
    const before = value;
    value = value.replace(/^--[^\n]*(?:\n|$)/, '').trimStart();
    value = value.replace(/^\/\*[\s\S]*?\*\//, '').trimStart();
    value = value.replace(/^\\(?:restrict|unrestrict)\b[^\n]*(?:\n|$)/i, '').trimStart();
    if (value === before) return value;
  }
}
function functionInfo(statement) {
  const clean = stripLeadingNoise(statement);
  const match = clean.match(/^CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+public\.([A-Za-z0-9_]+)\s*\(([\s\S]*?)\)\s+RETURNS\b/i);
  return match ? { name: match[1], args: match[2], clean } : null;
}
function topLevelMutation(statement) {
  const clean = stripLeadingNoise(statement);
  if (/^INSERT\s+INTO\b/i.test(clean)) return 'INSERT';
  if (/^UPDATE\b/i.test(clean)) return 'UPDATE';
  if (/^DELETE\s+FROM\b/i.test(clean)) return 'DELETE';
  if (/^COPY\b[\s\S]*\bFROM\s+stdin\b/i.test(clean)) return 'COPY_FROM_STDIN';
  if (/^MERGE\s+INTO\b/i.test(clean)) return 'MERGE';
  return null;
}

if (!fs.existsSync(transformManifestPath)) throw new Error('AWS final transform manifest is required.');
if (!fs.existsSync(schemaPath)) throw new Error(`AWS transformed schema dump not found: ${schemaPath}`);
const transform = JSON.parse(fs.readFileSync(transformManifestPath, 'utf8'));
const schema = fs.readFileSync(schemaPath, 'utf8');

if (transform.build !== 'AWS-V0-BUILD-3' || transform.mode !== 'aws-final-transformation') throw new Error('Unexpected AWS transform manifest.');
if (transform.status !== 'READY_FOR_SECOND_EPHEMERAL_POSTGRES_VALIDATION') throw new Error('AWS transform candidate is not ready for second PostgreSQL validation.');
if (transform.aurora_execution_allowed !== false || transform.baseline_emission_allowed !== false) throw new Error('AWS transform manifest opened deployment prematurely.');

const statements = splitTopLevelSql(schema);
const mutations = statements.map(topLevelMutation).filter(Boolean);
if (mutations.length !== 0) throw new Error(`Transformed schema-only dump contains ${mutations.length} top-level data mutation(s).`);

const blockers = [];
function pushBlocker(code, count, detail = undefined) {
  if (count > 0) blockers.push({ code, count, ...(detail ?? {}) });
}
pushBlocker('AWS_AUTH_USERS_REFERENCE_REMAINING', countMatches(schema, /\bauth\.users\b/gi));
pushBlocker('AWS_AUTH_UID_REFERENCE_REMAINING', countMatches(schema, /\bauth\.uid\s*\(/gi));
pushBlocker('AWS_BACKEND_SESSION_AUTH_REFERENCE_REMAINING',
  countMatches(schema, /\bauth\.(?:role|jwt)\s*\(/gi) + countMatches(schema, /current_setting\s*\(\s*['"]request\.jwt\./gi));
pushBlocker('AWS_RLS_ENABLEMENT_REMAINING', countMatches(schema, /ALTER TABLE(?: ONLY)? public\.[^\n]+\s+ENABLE ROW LEVEL SECURITY;/gi));
pushBlocker('AWS_RLS_POLICY_REMAINING', countMatches(schema, /^\s*CREATE\s+POLICY\b/gim) + countMatches(schema, /^\s*ALTER\s+POLICY\b/gim));
pushBlocker('V1_ETL_REFERENCE_REMAINING', countMatches(schema, /\bmarketroute_v1_migration_(?:batches|id_map|rejections|audit_events)\b/gi));
pushBlocker('SUPABASE_ROLE_GRANT_REFERENCE_REMAINING', countMatches(schema, /\b(?:GRANT|REVOKE)\b[^;]*(?:\banon\b|\bauthenticated\b|\bservice_role\b)/gi));
pushBlocker('SUPABASE_AUTH_SCHEMA_REMAINING', countMatches(schema, /^\s*CREATE\s+SCHEMA\s+auth\b/gim) + countMatches(schema, /^\s*CREATE\s+TABLE\s+auth\./gim));

const requiredObjects = [
  ['table', /CREATE TABLE public\.marketroute_users\b/i],
  ['table', /CREATE TABLE public\.organisations\b/i],
  ['table', /CREATE TABLE public\.companies\b/i],
  ['table', /CREATE TABLE public\.claims\b/i],
  ['table', /CREATE TABLE public\.truth_claim_snapshots\b/i],
  ['table', /CREATE TABLE public\.commercial_reality_r4_records\b/i],
  ['table', /CREATE TABLE public\.route_authority_r5_records\b/i],
  ['table', /CREATE TABLE public\.contact_authority_r6_records\b/i],
  ['routine', /CREATE FUNCTION public\.marketroute_truth_policy_for_claim_v1\b/i],
  ['routine', /CREATE FUNCTION public\.marketroute_authority_envelope_v1\b/i],
];
for (const [kind, pattern] of requiredObjects) {
  if (!pattern.test(schema)) throw new Error(`Required AWS canonical ${kind} missing: ${pattern}`);
}

const internalUserFks = countMatches(schema, /REFERENCES\s+public\.marketroute_users\s*\(\s*id\s*\)/gi);
if (internalUserFks !== 13) throw new Error(`Expected 13 internal-user FKs, got ${internalUserFks}.`);

const functionStatements = new Map();
const actorFunctions = [];
for (const statement of statements) {
  const info = functionInfo(statement);
  if (!info) continue;
  functionStatements.set(info.name, statement);
  if (!ACTOR_FUNCTIONS.has(info.name)) continue;
  if (!/\bp_actor_user_id\s+uuid\b/i.test(info.args)) throw new Error(`${info.name} is missing explicit p_actor_user_id uuid.`);
  actorFunctions.push(info.name);
}
if (new Set(actorFunctions).size !== ACTOR_FUNCTIONS.size) {
  const found = new Set(actorFunctions);
  const missing = [...ACTOR_FUNCTIONS].filter((name) => !found.has(name));
  throw new Error(`Actor-aware function set incomplete: ${missing.join(', ')}.`);
}

for (const name of ['marketroute_manage_campaign_v1', 'marketroute_submit_campaign_v3', 'marketroute_submit_workspace_activation_v2']) {
  const body = functionStatements.get(name) ?? '';
  if (!/public\.marketroute_is_org_admin\s*\(\s*p_organisation_id\s*,\s*p_actor_user_id\s*\)/i.test(body)) {
    throw new Error(`${name} does not propagate the explicit actor to org-admin authorization.`);
  }
}
for (const name of ['marketroute_workspace_activation_status_v1', 'marketroute_workspace_activation_status_v2']) {
  const body = functionStatements.get(name) ?? '';
  if (!/public\.marketroute_is_org_member\s*\(\s*p_organisation_id\s*,\s*p_actor_user_id\s*\)/i.test(body)) {
    throw new Error(`${name} does not propagate the explicit actor to org-member authorization.`);
  }
}
for (const name of ['marketroute_submit_campaign_v2', 'marketroute_submit_replacement_campaign_v1']) {
  const body = functionStatements.get(name) ?? '';
  if (!/public\.marketroute_submit_campaign_v3\s*\(\s*\$1\s*,\s*\$2\s*,\s*\$3\s*,\s*\$4\s*,\s*\$5\s*,\s*\$6\s*,\s*\$7\s*,\s*\$8\s*\)/i.test(body)) {
    throw new Error(`${name} does not forward the explicit actor to campaign v3.`);
  }
}
const activationV1 = functionStatements.get('marketroute_submit_workspace_activation_v1') ?? '';
if (!/public\.marketroute_submit_workspace_activation_v2\s*\([\s\S]*p_actor_user_id[\s\S]*\)/i.test(activationV1)) {
  throw new Error('marketroute_submit_workspace_activation_v1 does not forward the explicit actor to v2.');
}
if (!functionStatements.has('marketroute_require_service_role')) throw new Error('Trusted-backend compatibility guard function is missing.');

const founderSnapshot = functionStatements.get('marketroute_founder_dashboard_snapshot_v1') ?? '';
for (const key of ['migrationBatches', 'migratedRecords', 'migrationRejections']) {
  if (!founderSnapshot.includes(`'${key}'`)) throw new Error(`Founder observability JSON key ${key} was not preserved.`);
}

const objectCounts = {
  tables: countMatches(schema, /^CREATE TABLE public\./gim),
  routines: countMatches(schema, /^CREATE (?:OR REPLACE )?FUNCTION public\./gim),
  procedures: countMatches(schema, /^CREATE (?:OR REPLACE )?PROCEDURE public\./gim),
  views: countMatches(schema, /^CREATE (?:OR REPLACE )?VIEW public\./gim),
  triggers: countMatches(schema, /^CREATE TRIGGER\b/gim),
  indexes: countMatches(schema, /^CREATE (?:UNIQUE )?INDEX\b/gim),
};
if (objectCounts.tables !== 77) throw new Error(`Expected 77 AWS tables including marketroute_users, got ${objectCounts.tables}.`);
if (objectCounts.routines !== 206) throw new Error(`Expected 206 routines after signature transforms, got ${objectCounts.routines}.`);
if (objectCounts.views !== 5) throw new Error(`Expected 5 views, got ${objectCounts.views}.`);
if (objectCounts.triggers !== 64) throw new Error(`Expected 64 triggers, got ${objectCounts.triggers}.`);
if (objectCounts.indexes !== 88) throw new Error(`Expected 88 explicit indexes including marketroute_users_status_idx, got ${objectCounts.indexes}.`);

if (blockers.length) throw new Error(`AWS transformed schema still has blocker(s): ${JSON.stringify(blockers)}`);

const manifest = {
  format_version: 1,
  build: 'AWS-V0-BUILD-3',
  mode: 'aws-transformed-schema-validation',
  status: 'AWS_FINAL_OBJECTS_TRANSFORMED',
  generated_at: new Date().toISOString(),
  source_transform_manifest_sha256: sha256(fs.readFileSync(transformManifestPath, 'utf8')),
  schema: {
    path: path.relative(repoRoot, schemaPath),
    sha256: sha256(schema),
    bytes: Buffer.byteLength(schema),
    schema_only: true,
    top_level_statement_count: statements.length,
    top_level_data_mutation_count: 0,
  },
  object_counts: objectCounts,
  identity: {
    internal_user_relation: 'public.marketroute_users',
    internal_user_fk_count: internalUserFks,
    explicit_actor_function_count: ACTOR_FUNCTIONS.size,
    actor_contract: 'EXPLICIT_INTERNAL_USER_UUID',
    trusted_backend_contract: 'SERVER_SIDE_DATA_API_ONLY',
  },
  blocker_count: 0,
  blockers: [],
  canonical_baseline_candidate_validated_in_postgresql16: true,
  baseline_emission_allowed: false,
  aurora_execution_allowed: false,
};
fs.writeFileSync(outputManifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
console.log(JSON.stringify({
  build: manifest.build,
  mode: manifest.mode,
  status: manifest.status,
  object_counts: manifest.object_counts,
  internal_user_fk_count: manifest.identity.internal_user_fk_count,
  explicit_actor_function_count: manifest.identity.explicit_actor_function_count,
  blocker_count: manifest.blocker_count,
  manifest: path.relative(repoRoot, outputManifestPath),
  aurora_execution_allowed: manifest.aurora_execution_allowed,
}, null, 2));
