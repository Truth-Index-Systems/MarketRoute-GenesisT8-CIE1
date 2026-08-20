#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const repoRoot = process.cwd();
const outputDir = path.resolve(repoRoot, process.env.MARKETROUTE_AWS_DATABASE_DIR ?? 'database/aws');
const replayManifestPath = path.join(outputDir, 'build3_final_object_replay_manifest.json');
const finalDispositionManifestPath = path.join(outputDir, '0001_marketroute_aws_final_disposition_manifest.json');
const referenceSchemaPath = path.resolve(
  repoRoot,
  process.env.MARKETROUTE_FINAL_OBJECT_REFERENCE_SCHEMA ?? 'database/aws/build3_final_object_reference_schema.sql',
);
const resolvedManifestPath = path.join(outputDir, 'build3_final_object_resolution_manifest.json');

function sha256(text) {
  return crypto.createHash('sha256').update(text).digest('hex');
}

function countMatches(text, pattern) {
  return [...text.matchAll(pattern)].length;
}

if (!fs.existsSync(replayManifestPath) || !fs.existsSync(finalDispositionManifestPath)) {
  throw new Error('Final-object replay manifest and final disposition manifest are required.');
}
if (!fs.existsSync(referenceSchemaPath)) {
  throw new Error(`Reference schema dump not found: ${referenceSchemaPath}`);
}

const replayManifest = JSON.parse(fs.readFileSync(replayManifestPath, 'utf8'));
const finalDispositionManifest = JSON.parse(fs.readFileSync(finalDispositionManifestPath, 'utf8'));
const schema = fs.readFileSync(referenceSchemaPath, 'utf8');

if (replayManifest.build !== 'AWS-V0-BUILD-3' || replayManifest.mode !== 'final-object-reference-replay') {
  throw new Error('Unexpected final-object replay manifest.');
}
if (replayManifest.status !== 'READY_FOR_EPHEMERAL_POSTGRES_REPLAY') {
  throw new Error('Replay manifest gate is not ready.');
}
if (finalDispositionManifest.status !== 'READY_FOR_FINAL_OBJECT_RESOLUTION') {
  throw new Error('Final disposition gate is not ready for final-object resolution.');
}
if (replayManifest.expected_aws_transforms !== 35) {
  throw new Error(`Expected 35 AWS transforms, got ${replayManifest.expected_aws_transforms}.`);
}
if (replayManifest.expected_canonical_configuration_statements !== 19) {
  throw new Error('Canonical configuration statement count drifted.');
}

const forbiddenDataPatterns = [
  /^\s*COPY\s+.+\s+FROM\s+stdin\s*;/gim,
  /^\s*INSERT\s+INTO\b/gim,
  /^\s*UPDATE\s+.+\s+SET\b/gim,
  /^\s*DELETE\s+FROM\b/gim,
];
for (const pattern of forbiddenDataPatterns) {
  if (pattern.test(schema)) throw new Error(`Schema-only dump contains data mutation matching ${pattern}.`);
}

if (/^\s*CREATE\s+SCHEMA\s+auth\b/gim.test(schema)) {
  throw new Error('Ephemeral auth compatibility schema leaked into reference dump.');
}
if (/^\s*CREATE\s+TABLE\s+auth\.users\b/gim.test(schema)) {
  throw new Error('Ephemeral auth.users compatibility table leaked into reference dump.');
}

const requiredObjects = [
  ['table', /CREATE TABLE public\.organisations\b/i],
  ['table', /CREATE TABLE public\.companies\b/i],
  ['table', /CREATE TABLE public\.claims\b/i],
  ['table', /CREATE TABLE public\.truth_claim_snapshots\b/i],
  ['table', /CREATE TABLE public\.commercial_reality_r4_records\b/i],
  ['table', /CREATE TABLE public\.route_authority_r5_records\b/i],
  ['table', /CREATE TABLE public\.contact_authority_r6_records\b/i],
  ['table', /CREATE TABLE public\.marketroute_plan_catalog\b/i],
  ['routine', /CREATE FUNCTION public\.marketroute_truth_policy_for_claim_v1\b/i],
  ['routine', /CREATE FUNCTION public\.marketroute_authority_envelope_v1\b/i],
  ['routine', /CREATE FUNCTION public\.marketroute_workspace_commercial_access_v1\b/i],
];
for (const [kind, pattern] of requiredObjects) {
  if (!pattern.test(schema)) throw new Error(`Required canonical ${kind} missing from PostgreSQL reference schema: ${pattern}`);
}

const objectCounts = {
  tables: countMatches(schema, /^CREATE TABLE public\./gim),
  routines: countMatches(schema, /^CREATE (?:OR REPLACE )?FUNCTION public\./gim),
  procedures: countMatches(schema, /^CREATE (?:OR REPLACE )?PROCEDURE public\./gim),
  views: countMatches(schema, /^CREATE (?:OR REPLACE )?VIEW public\./gim),
  materialized_views: countMatches(schema, /^CREATE MATERIALIZED VIEW public\./gim),
  triggers: countMatches(schema, /^CREATE TRIGGER\b/gim),
  indexes: countMatches(schema, /^CREATE (?:UNIQUE )?INDEX\b/gim),
};

if (objectCounts.tables < 50) throw new Error(`Reference schema table count unexpectedly low: ${objectCounts.tables}.`);
if (objectCounts.routines < 150) throw new Error(`Reference schema routine count unexpectedly low: ${objectCounts.routines}.`);

const blockers = [];

const authUsersReferences = countMatches(schema, /\bauth\.users\b/gi);
const authUidReferences = countMatches(schema, /\bauth\.uid\s*\(/gi);
const authRoleReferences = countMatches(schema, /\bauth\.(?:role|jwt)\s*\(/gi);
const requestJwtReferences = countMatches(schema, /current_setting\s*\(\s*['"]request\.jwt\./gi);
const rlsEnableStatements = countMatches(schema, /ALTER TABLE ONLY public\.[^\n]+\s+ENABLE ROW LEVEL SECURITY;/gi)
  + countMatches(schema, /ALTER TABLE public\.[^\n]+\s+ENABLE ROW LEVEL SECURITY;/gi);

if (authUsersReferences > 0) {
  blockers.push({
    code: 'AWS_AUTH_USERS_REFERENCE_REWRITE_PENDING',
    count: authUsersReferences,
    required_transform: 'AUTH_USERS_FK_TO_INTERNAL_USER_UUID',
  });
}
if (authUidReferences > 0) {
  blockers.push({
    code: 'AWS_AUTH_UID_REFERENCE_REWRITE_PENDING',
    count: authUidReferences,
    required_transform: 'AUTH_UID_TO_EXPLICIT_UUID_PARAMETER',
  });
}
if (authRoleReferences > 0 || requestJwtReferences > 0) {
  blockers.push({
    code: 'AWS_BACKEND_SESSION_AUTH_REWRITE_PENDING',
    count: authRoleReferences + requestJwtReferences,
    auth_role_or_jwt_references: authRoleReferences,
    request_jwt_references: requestJwtReferences,
  });
}
if (rlsEnableStatements > 0) {
  blockers.push({
    code: 'AWS_RLS_EXECUTION_MODEL_REVIEW_REQUIRED',
    count: rlsEnableStatements,
    rationale: 'Reference schema retains legacy RLS enablement; final AWS baseline must make the server-side Data API execution model explicit.',
  });
}

const v1ReferenceNames = [
  'marketroute_v1_migration_batches',
  'marketroute_v1_migration_id_map',
  'marketroute_v1_migration_rejections',
  'marketroute_v1_migration_audit_events',
];
const v1References = [];
for (const name of v1ReferenceNames) {
  const count = countMatches(schema, new RegExp(`\\b${name}\\b`, 'gi'));
  if (count > 0) v1References.push({ name, count });
}
if (v1References.length) {
  blockers.push({
    code: 'V1_ETL_REFERENCE_REWRITE_PENDING',
    references: v1References,
    rationale: 'V1 ETL objects are excluded from AWS; surviving observability references must be removed or rewritten.',
  });
}

const supabaseRoleReferences = countMatches(schema, /\b(?:anon|authenticated|service_role)\b/gi);
if (supabaseRoleReferences > 0) {
  blockers.push({
    code: 'SUPABASE_ROLE_REFERENCE_REVIEW_PENDING',
    count: supabaseRoleReferences,
  });
}

const generatedAt = new Date().toISOString();
const resolvedManifest = {
  format_version: 1,
  build: 'AWS-V0-BUILD-3',
  mode: 'final-object-resolution',
  status: blockers.length === 0 ? 'FINAL_OBJECTS_RESOLVED' : 'FINAL_OBJECTS_RESOLVED_AWS_TRANSFORMS_PENDING',
  generated_at: generatedAt,
  doctrine: ['Fresh data', 'Final logic', 'Clean provenance'],
  source_reference_schema: {
    path: path.relative(repoRoot, referenceSchemaPath),
    sha256: sha256(schema),
    bytes: Buffer.byteLength(schema),
    schema_only: true,
    ephemeral_compatibility_schema_excluded: true,
  },
  reference_object_counts: objectCounts,
  required_aws_transform_count: replayManifest.expected_aws_transforms,
  canonical_configuration_statement_count: replayManifest.expected_canonical_configuration_statements,
  blockers,
  blocker_count: blockers.length,
  baseline_emission_allowed: false,
  aurora_execution_allowed: false,
};

fs.writeFileSync(resolvedManifestPath, `${JSON.stringify(resolvedManifest, null, 2)}\n`);

console.log(JSON.stringify({
  build: resolvedManifest.build,
  mode: resolvedManifest.mode,
  status: resolvedManifest.status,
  object_counts: resolvedManifest.reference_object_counts,
  blocker_count: resolvedManifest.blocker_count,
  blocker_codes: blockers.map((b) => b.code),
  reference_schema: resolvedManifest.source_reference_schema.path,
  manifest: path.relative(repoRoot, resolvedManifestPath),
}, null, 2));
