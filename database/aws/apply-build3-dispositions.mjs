#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';

const repoRoot = process.cwd();
const migrationsDir = path.resolve(repoRoot, process.env.MARKETROUTE_MIGRATIONS_DIR ?? 'supabase/migrations');
const outputDir = path.resolve(repoRoot, process.env.MARKETROUTE_AWS_DATABASE_DIR ?? 'database/aws');
const auditPath = path.join(outputDir, 'build3_schema_audit.json');
const sourceManifestPath = path.join(outputDir, '0001_marketroute_aws_schema_manifest.json');
const dispositionAuditPath = path.join(outputDir, 'build3_disposition_audit.json');
const dispositionManifestPath = path.join(outputDir, '0001_marketroute_aws_disposition_manifest.json');

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
  if (/^CREATE\s+POLICY\b/.test(upper)) return 'policy';
  if (/^CREATE\s+(OR\s+REPLACE\s+)?(FUNCTION|PROCEDURE)\b/.test(upper)) return 'routine';
  if (/^CREATE\s+TABLE\b/.test(upper)) return 'table';
  if (/^(INSERT|UPDATE|DELETE|TRUNCATE|COPY|MERGE)\b/.test(upper)) return 'data-mutation';
  if (/^WITH\b/.test(upper) && /\b(INSERT|UPDATE|DELETE|MERGE)\b/.test(upper)) return 'data-mutation-cte';
  if (/^DO\b/.test(upper)) return 'do-block';
  return 'other';
}

function extractOuterDollarBody(statement) {
  const sql = stripLeadingComments(statement);
  const first = sql.match(/\$[A-Za-z_][A-Za-z0-9_]*\$|\$\$/);
  if (!first || first.index == null) return null;
  const tag = first[0];
  const start = first.index + tag.length;
  const end = sql.indexOf(tag, start);
  if (end < 0) return null;
  return sql.slice(start, end);
}

function mutationKeywords(text) {
  const sanitized = text
    .replace(/--[^\n]*/g, ' ')
    .replace(/\/\*[\s\S]*?\*\//g, ' ')
    .replace(/'(?:''|[^'])*'/g, ' ')
    .replace(/"(?:""|[^"])*"/g, ' ');
  return [...new Set((sanitized.match(/\b(?:INSERT|UPDATE|DELETE|TRUNCATE|COPY|MERGE)\b/gi) ?? []).map((x) => x.toUpperCase()))].sort();
}

function mutationTarget(statement) {
  const sql = normalizeSql(statement);
  const patterns = [
    [/^INSERT\s+INTO\s+([^\s(;,]+)/i, 'INSERT'],
    [/^UPDATE\s+([^\s(;,]+)/i, 'UPDATE'],
    [/^DELETE\s+FROM\s+([^\s(;,]+)/i, 'DELETE'],
    [/^TRUNCATE(?:\s+TABLE)?\s+([^\s(;,]+)/i, 'TRUNCATE'],
    [/^COPY\s+([^\s(;,]+)/i, 'COPY'],
    [/^MERGE\s+INTO\s+([^\s(;,]+)/i, 'MERGE'],
  ];
  for (const [pattern, verb] of patterns) {
    const match = sql.match(pattern);
    if (match) return { verb, relation: match[1].replace(/;$/, '').toLowerCase() };
  }
  return { verb: null, relation: null };
}

function statementAt(file, statementIndex, cache) {
  if (!cache.has(file)) {
    const fullPath = path.join(migrationsDir, file);
    const source = fs.readFileSync(fullPath, 'utf8');
    cache.set(file, splitSql(source));
  }
  const statements = cache.get(file);
  const statement = statements[statementIndex - 1];
  if (!statement) throw new Error(`Statement ${statementIndex} not found in ${file}`);
  return statement;
}

function identityDisposition(finding, statement) {
  const sql = stripLeadingComments(statement);
  const kind = classify(statement);

  if (finding.code === 'SUPABASE_ROLE_REWRITE_REQUIRED' && kind === 'policy') {
    return {
      decision_resolved: true,
      disposition: 'EXCLUDE_SUPABASE_RLS_POLICY',
      transform_required: false,
      rationale: 'Supabase role-bound RLS policy is infrastructure-specific; AWS uses server-side Data API boundaries and explicit tenant/actor parameters.',
    };
  }

  if (finding.code === 'AWS_REQUEST_JWT_REWRITE_REQUIRED') {
    return {
      decision_resolved: true,
      disposition: 'REWRITE_TO_TRUSTED_BACKEND_EXECUTION_BOUNDARY',
      transform_required: true,
      transform: 'REMOVE_REQUEST_JWT_SESSION_DEPENDENCY',
      rationale: 'AWS backend authorization is established before Data API execution; PostgreSQL request.jwt session state is not canonical.',
    };
  }

  if (finding.code === 'AWS_IDENTITY_REWRITE_REQUIRED') {
    if (/\bauth\.users\b/i.test(sql)) {
      return {
        decision_resolved: true,
        disposition: 'REWRITE_AUTH_USERS_FK_TO_MARKETROUTE_USERS',
        transform_required: true,
        transform: 'AUTH_USERS_FK_TO_INTERNAL_USER_UUID',
        rationale: 'Canonical ownership remains UUID-based but references the internal MarketRoute user relation instead of Supabase auth.users.',
      };
    }
    if (/\bauth\.uid\s*\(/i.test(sql)) {
      return {
        decision_resolved: true,
        disposition: 'REWRITE_AUTH_UID_TO_EXPLICIT_ACTOR_USER_ID',
        transform_required: true,
        transform: 'AUTH_UID_TO_EXPLICIT_UUID_PARAMETER',
        rationale: 'Canonical database routines receive the internal actor UUID explicitly; Cognito-to-user mapping is deferred to Build 5.',
      };
    }
    if (/\bauth\.(?:role|jwt)\s*\(/i.test(sql)) {
      return {
        decision_resolved: true,
        disposition: 'REWRITE_TO_TRUSTED_BACKEND_EXECUTION_BOUNDARY',
        transform_required: true,
        transform: 'REMOVE_SUPABASE_ROLE_SESSION_DEPENDENCY',
        rationale: 'Trusted backend execution replaces Supabase auth role/session helpers.',
      };
    }
  }

  return null;
}

function mutationDisposition(finding, statement) {
  if (!['MIGRATION_TIME_DML_REVIEW', 'HIDDEN_DO_BLOCK_DML_REVIEW', 'CTE_DML_REVIEW'].includes(finding.code)) return null;

  const kind = classify(statement);
  if (finding.code === 'MIGRATION_TIME_DML_REVIEW') {
    const target = mutationTarget(statement);
    if (target.relation === 'public.marketroute_schema_releases' || target.relation === 'marketroute_schema_releases') {
      return {
        decision_resolved: true,
        disposition: 'EXCLUDE_HISTORICAL_SCHEMA_RELEASE_ROW',
        transform_required: false,
        mutation: target,
        rationale: 'Old schema release rows are migration bookkeeping; AWS V0 may later emit one AWS baseline release row only.',
      };
    }
    if (['UPDATE', 'DELETE', 'TRUNCATE', 'COPY'].includes(target.verb)) {
      return {
        decision_resolved: true,
        disposition: 'EXCLUDE_HISTORICAL_BACKFILL_OR_REPAIR',
        transform_required: false,
        mutation: target,
        rationale: 'Fresh AWS starts empty; migration-time repair/backfill rows are excluded while final DDL invariants are preserved.',
      };
    }
    return {
      decision_resolved: false,
      disposition: 'CANONICAL_SEED_REVIEW_REQUIRED',
      transform_required: false,
      mutation: target,
      rationale: 'Top-level INSERT/MERGE may represent canonical configuration rather than historical row repair and requires explicit review.',
    };
  }

  const body = kind === 'do-block' ? extractOuterDollarBody(statement) ?? statement : statement;
  const keywords = mutationKeywords(body);
  const ambiguous = keywords.some((k) => ['INSERT', 'MERGE', 'COPY'].includes(k));
  if (!ambiguous) {
    return {
      decision_resolved: true,
      disposition: 'EXCLUDE_HISTORICAL_BACKFILL_OR_REPAIR',
      transform_required: false,
      mutation_keywords: keywords,
      rationale: 'Hidden mutation only updates/deletes existing rows; there are no historical rows in the fresh AWS database.',
    };
  }
  return {
    decision_resolved: false,
    disposition: 'CANONICAL_SEED_REVIEW_REQUIRED',
    transform_required: false,
    mutation_keywords: keywords,
    rationale: 'Hidden INSERT/MERGE/COPY may create canonical configuration and remains fail-closed for explicit review.',
  };
}

if (!fs.existsSync(auditPath) || !fs.existsSync(sourceManifestPath)) {
  throw new Error('Run compile-canonical-baseline.mjs before applying Build 3 dispositions.');
}

const audit = JSON.parse(fs.readFileSync(auditPath, 'utf8'));
const sourceManifest = JSON.parse(fs.readFileSync(sourceManifestPath, 'utf8'));
if (audit.format_version !== 2 || audit.mode !== 'hardened-audit') throw new Error('Hardened Build 3 audit v2 required.');
if (sourceManifest.format_version !== 2) throw new Error('Build 3 schema manifest v2 required.');

const statementCache = new Map();
const rawUnresolved = [...audit.blockers, ...audit.review_items];
const decisions = [];
for (const finding of rawUnresolved) {
  const statement = statementAt(finding.file, finding.statement_index, statementCache);
  const decision = identityDisposition(finding, statement) ?? mutationDisposition(finding, statement) ?? {
    decision_resolved: false,
    disposition: finding.disposition ?? 'UNRESOLVED',
    transform_required: false,
    rationale: 'No Build 3 disposition rule exists for this finding.',
  };
  decisions.push({
    file: finding.file,
    statement_index: finding.statement_index,
    finding_code: finding.code,
    severity: finding.severity,
    statement_sha256: finding.sha256,
    statement_kind: classify(statement),
    statement_preview: normalizeSql(statement).slice(0, 220),
    ...decision,
  });
}

const unresolved = decisions.filter((d) => !d.decision_resolved);
const resolved = decisions.filter((d) => d.decision_resolved);
const transforms = resolved.filter((d) => d.transform_required);
const exclusions = resolved.filter((d) => d.disposition.startsWith('EXCLUDE_'));
const counts = decisions.reduce((acc, d) => {
  acc[d.disposition] = (acc[d.disposition] ?? 0) + 1;
  return acc;
}, {});

const identityBoundary = {
  version: 'AWS-V0-INTERNAL-IDENTITY-1',
  internal_user_relation: 'public.marketroute_users',
  internal_user_primary_key: 'uuid',
  external_identity_binding: 'DEFER_TO_BUILD_5',
  database_actor_contract: 'EXPLICIT_INTERNAL_USER_UUID',
  trusted_backend_contract: 'SERVER_SIDE_DATA_API_ONLY',
  browser_database_access: false,
  supabase_auth_schema_allowed: false,
  supabase_roles_allowed: false,
  request_jwt_session_state_allowed: false,
};

const dispositionAudit = {
  format_version: 1,
  build: 'AWS-V0-BUILD-3',
  mode: 'canonical-disposition',
  generated_at: new Date().toISOString(),
  source_audit_format: audit.format_version,
  raw_unresolved_count: rawUnresolved.length,
  resolved_decisions: resolved.length,
  unresolved_count: unresolved.length,
  required_transforms: transforms.length,
  resolved_exclusions: exclusions.length,
  disposition_counts: counts,
  identity_boundary: identityBoundary,
  decisions,
  unresolved,
};

const dispositionManifest = {
  format_version: 1,
  build: 'AWS-V0-BUILD-3',
  status: unresolved.length === 0 ? 'READY_FOR_FINAL_OBJECT_RESOLUTION' : 'DISPOSITION_REVIEW_REQUIRED',
  generated_at: dispositionAudit.generated_at,
  prohibited_historical_data_import: true,
  identity_boundary: identityBoundary,
  required_transforms: transforms,
  exclusions,
  unresolved,
  source_schema_manifest: {
    format_version: sourceManifest.format_version,
    excluded_migrations: sourceManifest.excluded_migrations,
    object_candidate_count: sourceManifest.object_candidates.length,
  },
};

fs.writeFileSync(dispositionAuditPath, `${JSON.stringify(dispositionAudit, null, 2)}\n`);
fs.writeFileSync(dispositionManifestPath, `${JSON.stringify(dispositionManifest, null, 2)}\n`);

console.log(JSON.stringify({
  build: dispositionAudit.build,
  mode: dispositionAudit.mode,
  raw_unresolved: dispositionAudit.raw_unresolved_count,
  resolved_decisions: dispositionAudit.resolved_decisions,
  unresolved: dispositionAudit.unresolved_count,
  required_transforms: dispositionAudit.required_transforms,
  resolved_exclusions: dispositionAudit.resolved_exclusions,
  disposition_counts: dispositionAudit.disposition_counts,
  manifest_status: dispositionManifest.status,
  audit: path.relative(repoRoot, dispositionAuditPath),
  manifest: path.relative(repoRoot, dispositionManifestPath),
}, null, 2));
