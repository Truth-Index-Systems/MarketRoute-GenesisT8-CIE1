#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const repoRoot = process.cwd();
const migrationsDir = path.resolve(repoRoot, process.env.MARKETROUTE_MIGRATIONS_DIR ?? 'supabase/migrations');
const outputDir = path.resolve(repoRoot, process.env.MARKETROUTE_AWS_DATABASE_DIR ?? 'database/aws');

const schemaAuditPath = path.join(outputDir, 'build3_schema_audit.json');
const finalDispositionAuditPath = path.join(outputDir, 'build3_final_disposition_audit.json');
const finalDispositionManifestPath = path.join(outputDir, '0001_marketroute_aws_final_disposition_manifest.json');
const replayPath = path.join(outputDir, 'build3_final_object_replay.sql');
const replayManifestPath = path.join(outputDir, 'build3_final_object_replay_manifest.json');

const EXCLUDED_MIGRATIONS = new Set(['0019_v1_evidence_migration.sql']);

function sha256(text) {
  return crypto.createHash('sha256').update(text).digest('hex');
}

function splitSql(sql) {
  const statements = [];
  let start = 0;
  let i = 0;
  let mode = 'normal';
  let dollarTag = null;

  while (i < sql.length) {
    const ch = sql[i];
    const next = sql[i + 1];

    if (mode === 'line-comment') {
      if (ch === '\n') mode = 'normal';
      i += 1;
      continue;
    }
    if (mode === 'block-comment') {
      if (ch === '*' && next === '/') {
        mode = 'normal';
        i += 2;
      } else i += 1;
      continue;
    }
    if (mode === 'single') {
      if (ch === "'" && next === "'") i += 2;
      else if (ch === "'") {
        mode = 'normal';
        i += 1;
      } else i += 1;
      continue;
    }
    if (mode === 'double') {
      if (ch === '"' && next === '"') i += 2;
      else if (ch === '"') {
        mode = 'normal';
        i += 1;
      } else i += 1;
      continue;
    }
    if (mode === 'dollar') {
      if (sql.startsWith(dollarTag, i)) {
        i += dollarTag.length;
        mode = 'normal';
        dollarTag = null;
      } else i += 1;
      continue;
    }

    if (ch === '-' && next === '-') {
      mode = 'line-comment';
      i += 2;
      continue;
    }
    if (ch === '/' && next === '*') {
      mode = 'block-comment';
      i += 2;
      continue;
    }
    if (ch === "'") {
      mode = 'single';
      i += 1;
      continue;
    }
    if (ch === '"') {
      mode = 'double';
      i += 1;
      continue;
    }
    if (ch === '$') {
      const match = sql.slice(i).match(/^\$[A-Za-z_][A-Za-z0-9_]*\$|^\$\$/);
      if (match) {
        dollarTag = match[0];
        mode = 'dollar';
        i += dollarTag.length;
        continue;
      }
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

function stripLeadingComments(sql) {
  let value = sql.trimStart();
  for (;;) {
    const before = value;
    value = value.replace(/^--[^\n]*(?:\n|$)/, '').trimStart();
    value = value.replace(/^\/\*[\s\S]*?\*\//, '').trimStart();
    if (value === before) return value;
  }
}

function normalizeSql(sql) {
  return stripLeadingComments(sql).replace(/\s+/g, ' ').trim();
}

function classify(statement) {
  const upper = normalizeSql(statement).toUpperCase();
  if (/^(BEGIN|COMMIT|ROLLBACK)\b/.test(upper)) return 'transaction';
  if (/^GRANT\b|^REVOKE\b/.test(upper)) return 'grant';
  if (/^NOTIFY\b/.test(upper)) return 'notify';
  if (/^CREATE\s+POLICY\b/.test(upper)) return 'policy';
  if (/^CREATE\s+(OR\s+REPLACE\s+)?(?:FUNCTION|PROCEDURE)\b/.test(upper)) return 'routine';
  if (/^CREATE\s+(OR\s+REPLACE\s+)?VIEW\b/.test(upper)) return 'view';
  if (/^CREATE\s+(?:OR\s+REPLACE\s+)?(?:CONSTRAINT\s+)?TRIGGER\b/.test(upper)) return 'trigger';
  if (/^CREATE\s+(?:UNIQUE\s+)?INDEX\b/.test(upper)) return 'index';
  if (/^CREATE\s+TABLE\b/.test(upper)) return 'table';
  if (/^(INSERT|UPDATE|DELETE|TRUNCATE|COPY|MERGE)\b/.test(upper)) return 'data-mutation';
  if (/^WITH\b/.test(upper) && /\b(?:INSERT|UPDATE|DELETE|MERGE)\b/.test(upper)) return 'data-mutation-cte';
  if (/^DO\b/.test(upper)) return 'do-block';
  if (/^ALTER\b/.test(upper)) return 'alter';
  if (/^DROP\b/.test(upper)) return 'drop';
  return 'other';
}

function key(file, statementIndex) {
  return `${file}:${statementIndex}`;
}

function ensureTerminated(statement) {
  const trimmed = statement.trim();
  return trimmed.endsWith(';') ? trimmed : `${trimmed};`;
}

if (!fs.existsSync(schemaAuditPath) || !fs.existsSync(finalDispositionAuditPath) || !fs.existsSync(finalDispositionManifestPath)) {
  throw new Error('Run Build 3 hardened audit, dispositions, and final disposition closure before final-object resolution.');
}

const schemaAudit = JSON.parse(fs.readFileSync(schemaAuditPath, 'utf8'));
const finalDispositionAudit = JSON.parse(fs.readFileSync(finalDispositionAuditPath, 'utf8'));
const finalDispositionManifest = JSON.parse(fs.readFileSync(finalDispositionManifestPath, 'utf8'));

if (schemaAudit.build !== 'AWS-V0-BUILD-3' || schemaAudit.format_version !== 2 || schemaAudit.mode !== 'hardened-audit') {
  throw new Error('Hardened Build 3 schema audit v2 required.');
}
if (finalDispositionAudit.build !== 'AWS-V0-BUILD-3' || finalDispositionAudit.mode !== 'final-disposition-closure') {
  throw new Error('Final Build 3 disposition closure required.');
}
if (finalDispositionAudit.unresolved_count !== 0 || finalDispositionManifest.status !== 'READY_FOR_FINAL_OBJECT_RESOLUTION') {
  throw new Error('Final disposition gate has not cleared.');
}
if (finalDispositionAudit.required_transforms !== 35) {
  throw new Error(`Expected frozen AWS transform count 35, got ${finalDispositionAudit.required_transforms}.`);
}

const migrations = [...schemaAudit.migrations].map((m) => m.file);
if (migrations.length !== schemaAudit.migration_count) throw new Error('Migration inventory mismatch.');

const decisionsByStatement = new Map();
for (const decision of finalDispositionAudit.decisions) {
  const k = key(decision.file, decision.statement_index);
  const list = decisionsByStatement.get(k) ?? [];
  list.push(decision);
  decisionsByStatement.set(k, list);
}

const resolvedSchemaExclusions = new Set(
  (schemaAudit.resolved_exclusions ?? [])
    .filter((finding) => Number.isInteger(finding.statement_index))
    .map((finding) => key(finding.file, finding.statement_index)),
);

const compatibilityPrelude = `
-- ============================================================
-- EPHEMERAL COMPILER COMPATIBILITY SHIM — NEVER CANONICAL.
-- Exists only so the historical Supabase-era schema can be
-- replayed in disposable PostgreSQL 16 to resolve final DDL.
-- ============================================================
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
DO $mr_roles$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role NOLOGIN; END IF;
END;
$mr_roles$;
CREATE SCHEMA IF NOT EXISTS auth;
CREATE TABLE IF NOT EXISTS auth.users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid()
);
CREATE OR REPLACE FUNCTION auth.uid()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$ SELECT NULL::uuid $$;
CREATE OR REPLACE FUNCTION auth.role()
RETURNS text
LANGUAGE sql
STABLE
AS $$ SELECT 'service_role'::text $$;
CREATE OR REPLACE FUNCTION auth.jwt()
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$ SELECT '{}'::jsonb $$;
`;

const output = [
  '-- AWS-V0 Build 3 final-object reference replay',
  '-- Generated from reviewed historical migrations.',
  '-- DO NOT APPLY TO AURORA OR ANY PERSISTENT DATABASE.',
  '-- This file is an ephemeral PostgreSQL 16 compiler input only.',
  '',
  compatibilityPrelude.trim(),
  '',
];

const statementManifest = [];
const counters = {
  source_statements: 0,
  included_statements: 0,
  excluded_statements: 0,
  canonical_configuration_statements: 0,
  transform_source_statements: 0,
  passthrough_statements: 0,
  transaction_controls_removed: 0,
  schema_infrastructure_exclusions: 0,
  historical_exclusions: 0,
  excluded_migration_statements: 0,
};

for (const file of migrations) {
  const fullPath = path.join(migrationsDir, file);
  if (!fs.existsSync(fullPath)) throw new Error(`Migration not found: ${file}`);
  const source = fs.readFileSync(fullPath, 'utf8');
  const statements = splitSql(source);
  const excludedMigration = EXCLUDED_MIGRATIONS.has(file);

  if (excludedMigration) {
    counters.source_statements += statements.length;
    counters.excluded_statements += statements.length;
    counters.excluded_migration_statements += statements.length;
    statementManifest.push(...statements.map((statement, index) => ({
      file,
      statement_index: index + 1,
      sha256: sha256(statement),
      action: 'EXCLUDE_V1_ETL',
      kind: classify(statement),
    })));
    continue;
  }

  output.push(`-- ===== ${file} =====`);

  statements.forEach((statement, index) => {
    const statementIndex = index + 1;
    const k = key(file, statementIndex);
    const kind = classify(statement);
    const decisions = decisionsByStatement.get(k) ?? [];
    counters.source_statements += 1;

    let action = 'INCLUDE_PASSTHROUGH';
    let rationale = 'No exclusion or transform decision applies to this statement.';
    let include = true;

    if (kind === 'transaction') {
      include = false;
      action = 'EXCLUDE_TRANSACTION_CONTROL';
      rationale = 'Ephemeral replay executes statements under psql fail-fast control without historical transaction wrappers.';
      counters.transaction_controls_removed += 1;
    } else if (decisions.length) {
      const hasCanonical = decisions.some((d) => d.disposition === 'KEEP_CANONICAL_CONFIGURATION');
      const hasTransform = decisions.some((d) => d.transform_required === true || String(d.disposition).startsWith('REWRITE_'));
      const allExcluded = decisions.every((d) => String(d.disposition).startsWith('EXCLUDE_'));

      if (hasCanonical && (hasTransform || allExcluded)) {
        throw new Error(`Conflicting final disposition for ${k}.`);
      }

      if (hasCanonical) {
        include = true;
        action = 'INCLUDE_CANONICAL_CONFIGURATION';
        rationale = 'Reviewed canonical configuration/evolution must survive flattening.';
        counters.canonical_configuration_statements += 1;
      } else if (hasTransform) {
        include = true;
        action = 'INCLUDE_LEGACY_TRANSFORM_SOURCE';
        rationale = 'Legacy SQL is retained only in the disposable reference replay so PostgreSQL can resolve final DDL before AWS rewrites are applied.';
        counters.transform_source_statements += 1;
      } else if (allExcluded) {
        include = false;
        action = 'EXCLUDE_FINAL_DISPOSITION';
        rationale = decisions.map((d) => d.rationale).filter(Boolean).join(' | ') || 'Reviewed final exclusion.';
        counters.historical_exclusions += 1;
      }
    }

    if (include && resolvedSchemaExclusions.has(k) && decisions.length === 0) {
      include = false;
      action = 'EXCLUDE_SCHEMA_INFRASTRUCTURE';
      rationale = 'Hardened audit resolved this statement as excluded Supabase/PostgREST infrastructure.';
      counters.schema_infrastructure_exclusions += 1;
    }

    if (include) {
      counters.included_statements += 1;
      if (action === 'INCLUDE_PASSTHROUGH') counters.passthrough_statements += 1;
      output.push(`-- source ${file}:${statementIndex} ${action}`);
      output.push(ensureTerminated(statement));
      output.push('');
    } else {
      counters.excluded_statements += 1;
    }

    statementManifest.push({
      file,
      statement_index: statementIndex,
      sha256: sha256(statement),
      kind,
      action,
      included: include,
      decision_dispositions: decisions.map((d) => d.disposition),
      rationale,
    });
  });

  output.push('');
}

if (counters.canonical_configuration_statements !== 19) {
  throw new Error(`Expected 19 canonical configuration statements, got ${counters.canonical_configuration_statements}.`);
}
if (counters.transform_source_statements !== 35) {
  throw new Error(`Expected 35 AWS transform source statements, got ${counters.transform_source_statements}.`);
}

const replaySql = `${output.join('\n').trim()}\n`;
const generatedAt = new Date().toISOString();

const manifest = {
  format_version: 1,
  build: 'AWS-V0-BUILD-3',
  mode: 'final-object-reference-replay',
  status: 'READY_FOR_EPHEMERAL_POSTGRES_REPLAY',
  generated_at: generatedAt,
  doctrine: ['Fresh data', 'Final logic', 'Clean provenance'],
  persistent_database_execution_allowed: false,
  aurora_execution_allowed: false,
  ephemeral_postgresql_major: 16,
  compatibility_shim: {
    ephemeral_only: true,
    creates_auth_schema: true,
    creates_supabase_roles: ['anon', 'authenticated', 'service_role'],
    must_not_appear_in_canonical_baseline: true,
    sha256: sha256(compatibilityPrelude),
  },
  excluded_migrations: [...EXCLUDED_MIGRATIONS],
  expected_aws_transforms: 35,
  expected_canonical_configuration_statements: 19,
  counters,
  replay_sql: {
    path: path.relative(repoRoot, replayPath),
    sha256: sha256(replaySql),
    bytes: Buffer.byteLength(replaySql),
  },
  statements: statementManifest,
};

fs.writeFileSync(replayPath, replaySql);
fs.writeFileSync(replayManifestPath, `${JSON.stringify(manifest, null, 2)}\n`);

console.log(JSON.stringify({
  build: manifest.build,
  mode: manifest.mode,
  status: manifest.status,
  source_statements: counters.source_statements,
  included_statements: counters.included_statements,
  excluded_statements: counters.excluded_statements,
  canonical_configuration_statements: counters.canonical_configuration_statements,
  transform_source_statements: counters.transform_source_statements,
  excluded_migration_statements: counters.excluded_migration_statements,
  replay: manifest.replay_sql.path,
  manifest: path.relative(repoRoot, replayManifestPath),
}, null, 2));
