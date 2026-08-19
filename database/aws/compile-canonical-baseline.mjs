#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

const repoRoot = process.cwd();
const migrationsDir = path.resolve(repoRoot, process.env.MARKETROUTE_MIGRATIONS_DIR ?? 'supabase/migrations');
const outputDir = path.resolve(repoRoot, process.env.MARKETROUTE_AWS_DATABASE_DIR ?? 'database/aws');
const auditPath = path.join(outputDir, 'build3_schema_audit.json');
const manifestPath = path.join(outputDir, '0001_marketroute_aws_schema_manifest.json');
const baselinePath = path.join(outputDir, '0001_marketroute_aws_canonical_baseline.sql');
const emitBaseline = process.argv.includes('--emit-baseline');

const EXCLUDED_MIGRATIONS = new Set(['0019_v1_evidence_migration.sql']);
const MUTATION_KEYWORDS = ['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'COPY', 'MERGE'];

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function listMigrations() {
  if (!fs.existsSync(migrationsDir)) throw new Error(`Migration directory not found: ${migrationsDir}`);
  return fs.readdirSync(migrationsDir)
    .filter((name) => /^\d{4}_.+\.sql$/.test(name))
    .sort((a, b) => a.localeCompare(b, 'en'));
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
        continue;
      }
      i += 1;
      continue;
    }
    if (mode === 'single') {
      if (ch === "'" && next === "'") {
        i += 2;
        continue;
      }
      if (ch === "'") mode = 'normal';
      i += 1;
      continue;
    }
    if (mode === 'double') {
      if (ch === '"' && next === '"') {
        i += 2;
        continue;
      }
      if (ch === '"') mode = 'normal';
      i += 1;
      continue;
    }
    if (mode === 'dollar') {
      if (sql.startsWith(dollarTag, i)) {
        i += dollarTag.length;
        mode = 'normal';
        dollarTag = null;
        continue;
      }
      i += 1;
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
  if (mode !== 'normal' && mode !== 'line-comment') throw new Error(`Unterminated SQL lexical construct: ${mode}`);
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

function normalizeSql(statement) {
  return stripLeadingComments(statement).replace(/\s+/g, ' ').trim();
}

function classify(statement) {
  const upper = normalizeSql(statement).toUpperCase();
  if (/^(BEGIN|COMMIT|ROLLBACK)(\s|;|$)/.test(upper)) return 'transaction';
  if (/^(INSERT|UPDATE|DELETE|TRUNCATE|COPY|MERGE)\b/.test(upper)) return 'data-mutation';
  if (/^WITH\b/.test(upper) && /\b(INSERT|UPDATE|DELETE|MERGE)\b/.test(upper)) return 'data-mutation-cte';
  if (/^NOTIFY\b/.test(upper)) return 'notify';
  if (/^(GRANT|REVOKE)\b/.test(upper)) return 'grant';
  if (/^CREATE\s+(OR\s+REPLACE\s+)?(FUNCTION|PROCEDURE)\b/.test(upper)) return 'routine';
  if (/^CREATE\s+(OR\s+REPLACE\s+)?(MATERIALIZED\s+)?VIEW\b/.test(upper)) return 'view';
  if (/^CREATE\s+(CONSTRAINT\s+)?TRIGGER\b/.test(upper)) return 'trigger';
  if (/^CREATE\s+(UNIQUE\s+)?INDEX\b/.test(upper)) return 'index';
  if (/^CREATE\s+TABLE\b/.test(upper)) return 'table';
  if (/^CREATE\s+(TYPE|DOMAIN|SCHEMA|EXTENSION|SEQUENCE)\b/.test(upper)) return 'schema-object';
  if (/^CREATE\s+POLICY\b/.test(upper)) return 'policy';
  if (/^ALTER\b/.test(upper)) return 'alter';
  if (/^DROP\b/.test(upper)) return 'drop';
  if (/^DO\b/.test(upper)) return 'do-block';
  if (/^(SELECT|WITH|COMMENT|SET|RESET)\b/.test(upper)) return 'procedural-or-query';
  return 'unclassified';
}

function objectIdentity(statement, kind) {
  const sql = stripLeadingComments(statement);
  const patterns = {
    routine: /^CREATE\s+(?:OR\s+REPLACE\s+)?(?:FUNCTION|PROCEDURE)\s+([^\s(]+)\s*\(([^)]*)\)/i,
    view: /^CREATE\s+(?:OR\s+REPLACE\s+)?(?:MATERIALIZED\s+)?VIEW\s+([^\s(]+)\b/i,
    trigger: /^CREATE\s+(?:CONSTRAINT\s+)?TRIGGER\s+([^\s]+)[\s\S]*?\bON\s+([^\s;]+)/i,
    table: /^CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?([^\s(]+)\b/i,
    index: /^CREATE\s+(?:UNIQUE\s+)?INDEX\s+(?:IF\s+NOT\s+EXISTS\s+)?([^\s(]+)\b/i,
    policy: /^CREATE\s+POLICY\s+([^\s]+)\s+ON\s+([^\s;]+)/i,
  };
  const match = patterns[kind]?.exec(sql);
  if (!match) return null;
  if (kind === 'routine') return `${match[1]}(${match[2].replace(/\s+/g, ' ').trim()})`;
  if (kind === 'trigger' || kind === 'policy') return `${match[2]}::${match[1]}`;
  return match[1];
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

function executableMutationKeywords(text) {
  const found = new Set();
  let i = 0;
  let mode = 'normal';
  let dollarTag = null;
  let token = '';
  const flush = () => {
    if (!token) return;
    const upper = token.toUpperCase();
    if (MUTATION_KEYWORDS.includes(upper)) found.add(upper);
    token = '';
  };

  while (i < text.length) {
    const ch = text[i];
    const next = text[i + 1];
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
      if (text.startsWith(dollarTag, i)) {
        i += dollarTag.length;
        mode = 'normal';
        dollarTag = null;
      } else i += 1;
      continue;
    }
    if (ch === '-' && next === '-') {
      flush();
      mode = 'line-comment';
      i += 2;
      continue;
    }
    if (ch === '/' && next === '*') {
      flush();
      mode = 'block-comment';
      i += 2;
      continue;
    }
    if (ch === "'") {
      flush();
      mode = 'single';
      i += 1;
      continue;
    }
    if (ch === '"') {
      flush();
      mode = 'double';
      i += 1;
      continue;
    }
    if (ch === '$') {
      const match = text.slice(i).match(/^\$[A-Za-z_][A-Za-z0-9_]*\$|^\$\$/);
      if (match) {
        flush();
        dollarTag = match[0];
        mode = 'dollar';
        i += dollarTag.length;
        continue;
      }
    }
    if (/[A-Za-z_]/.test(ch)) token += ch;
    else flush();
    i += 1;
  }
  flush();
  return [...found].sort();
}

function hiddenMigrationMutation(statement, kind) {
  if (kind === 'data-mutation-cte') {
    const keywords = executableMutationKeywords(stripLeadingComments(statement));
    return { detected: keywords.length > 0, keywords };
  }
  if (kind === 'do-block') {
    const body = extractOuterDollarBody(statement);
    if (body == null) return { detected: false, keywords: [], parse_error: 'DO_BLOCK_DOLLAR_BODY_NOT_FOUND' };
    const keywords = executableMutationKeywords(body);
    return { detected: keywords.length > 0, keywords };
  }
  return { detected: false, keywords: [] };
}

function isPostgrestNotify(statement, kind) {
  return kind === 'notify' && /^NOTIFY\s+pgrst\b/i.test(normalizeSql(statement));
}

function supabaseRoleReference(statement) {
  const sql = normalizeSql(statement);
  return /\b(?:TO|FROM)\s+(?:anon|authenticated|service_role)\b/i.test(sql);
}

function infrastructureFindings(statement, kind) {
  const findings = [];
  const sql = stripLeadingComments(statement);

  if (/\bauth\.(?:users|uid\s*\(|role\s*\(|jwt\s*\()/i.test(sql)) {
    findings.push({ severity: 'BLOCKER', code: 'AWS_IDENTITY_REWRITE_REQUIRED', disposition: 'AWS_REWRITE_REQUIRED', resolved: false });
  }
  if (/current_setting\s*\(\s*['"]request\.jwt\./i.test(sql)) {
    findings.push({ severity: 'BLOCKER', code: 'AWS_REQUEST_JWT_REWRITE_REQUIRED', disposition: 'AWS_REWRITE_REQUIRED', resolved: false });
  }
  if (/\bstorage\./i.test(sql)) {
    findings.push({ severity: 'BLOCKER', code: 'AWS_STORAGE_REWRITE_REQUIRED', disposition: 'AWS_REWRITE_REQUIRED', resolved: false });
  }
  if (supabaseRoleReference(statement)) {
    const pureRoleGrant = kind === 'grant';
    findings.push({
      severity: pureRoleGrant ? 'INFO' : 'BLOCKER',
      code: pureRoleGrant ? 'SUPABASE_ROLE_GRANT_EXCLUDED' : 'SUPABASE_ROLE_REWRITE_REQUIRED',
      disposition: pureRoleGrant ? 'EXCLUDE_SUPABASE_INFRASTRUCTURE' : 'AWS_REWRITE_REQUIRED',
      resolved: pureRoleGrant,
    });
  }
  if (isPostgrestNotify(statement, kind) || /\bpostgrest\b|\/rest\/v1\//i.test(sql)) {
    const pureNotify = isPostgrestNotify(statement, kind);
    findings.push({
      severity: pureNotify ? 'INFO' : 'BLOCKER',
      code: pureNotify ? 'POSTGREST_NOTIFY_EXCLUDED' : 'POSTGREST_COUPLING_REWRITE_REQUIRED',
      disposition: pureNotify ? 'EXCLUDE_SUPABASE_INFRASTRUCTURE' : 'AWS_REWRITE_REQUIRED',
      resolved: pureNotify,
    });
  }
  return findings;
}

const migrations = listMigrations();
if (migrations.length === 0) throw new Error('No ordered SQL migrations found.');

const migrationAudits = [];
const objectHistory = new Map();
const counts = {};

for (const file of migrations) {
  const fullPath = path.join(migrationsDir, file);
  const source = fs.readFileSync(fullPath, 'utf8');
  const statements = splitSql(source);
  const excludedMigration = EXCLUDED_MIGRATIONS.has(file);
  const migration = {
    file,
    sha256: sha256(source),
    bytes: Buffer.byteLength(source),
    statements: statements.length,
    canonical_candidate: !excludedMigration,
    disposition: excludedMigration ? 'EXCLUDE_V1_ETL' : 'ANALYSE',
    findings: [],
  };

  statements.forEach((statement, index) => {
    const statementIndex = index + 1;
    const kind = classify(statement);
    counts[kind] = (counts[kind] ?? 0) + 1;

    if (excludedMigration) {
      migration.findings.push({
        severity: 'INFO',
        code: 'V1_ETL_STATEMENT_EXCLUDED',
        disposition: 'EXCLUDE_V1_ETL',
        resolved: true,
        statement_index: statementIndex,
        sha256: sha256(statement),
      });
      return;
    }

    const id = objectIdentity(statement, kind);
    if (id) {
      const key = `${kind}:${id.toLowerCase()}`;
      const history = objectHistory.get(key) ?? [];
      history.push({ file, statement_index: statementIndex, sha256: sha256(statement) });
      objectHistory.set(key, history);
    }

    if (kind === 'data-mutation') {
      migration.findings.push({
        severity: 'REVIEW',
        code: 'MIGRATION_TIME_DML_REVIEW',
        disposition: 'CLASSIFY_HISTORICAL_OR_CANONICAL_SEED',
        resolved: false,
        statement_index: statementIndex,
        sha256: sha256(statement),
      });
    }

    const hidden = hiddenMigrationMutation(statement, kind);
    if (hidden.parse_error) {
      migration.findings.push({
        severity: 'BLOCKER',
        code: hidden.parse_error,
        disposition: 'COMPILER_PARSE_REQUIRED',
        resolved: false,
        statement_index: statementIndex,
        sha256: sha256(statement),
      });
    } else if (hidden.detected) {
      migration.findings.push({
        severity: 'REVIEW',
        code: kind === 'do-block' ? 'HIDDEN_DO_BLOCK_DML_REVIEW' : 'CTE_DML_REVIEW',
        disposition: 'CLASSIFY_HISTORICAL_OR_CANONICAL_SEED',
        resolved: false,
        statement_index: statementIndex,
        mutation_keywords: hidden.keywords,
        sha256: sha256(statement),
      });
    }

    if (kind === 'unclassified') {
      migration.findings.push({
        severity: 'REVIEW',
        code: 'UNCLASSIFIED_SQL',
        disposition: 'COMPILER_CLASSIFICATION_REQUIRED',
        resolved: false,
        statement_index: statementIndex,
        sha256: sha256(statement),
      });
    }

    for (const finding of infrastructureFindings(statement, kind)) {
      migration.findings.push({ ...finding, statement_index: statementIndex, sha256: sha256(statement) });
    }
  });

  if (excludedMigration) {
    migration.findings.push({ severity: 'INFO', code: 'V1_ETL_MIGRATION_EXCLUDED', disposition: 'EXCLUDE_V1_ETL', resolved: true });
  }
  migrationAudits.push(migration);
}

const finalObjects = [...objectHistory.entries()].map(([key, history]) => ({
  key,
  revisions: history.length,
  final_source: history.at(-1),
  superseded_sources: history.slice(0, -1),
  provenance_complete: true,
})).sort((a, b) => a.key.localeCompare(b.key, 'en'));

const allFindings = migrationAudits.flatMap((migration) => migration.findings.map((finding) => ({ file: migration.file, ...finding })));
const unresolved = allFindings.filter((finding) => finding.resolved === false);
const resolvedExclusions = allFindings.filter((finding) => finding.resolved === true && String(finding.disposition).startsWith('EXCLUDE_'));
const blockers = unresolved.filter((finding) => finding.severity === 'BLOCKER');
const reviewItems = unresolved.filter((finding) => finding.severity === 'REVIEW');
const generatedAt = new Date().toISOString();

const dispositionCounts = allFindings.reduce((acc, finding) => {
  const key = finding.disposition ?? 'NONE';
  acc[key] = (acc[key] ?? 0) + 1;
  return acc;
}, {});

const audit = {
  format_version: 2,
  build: 'AWS-V0-BUILD-3',
  mode: 'hardened-audit',
  generated_at: generatedAt,
  doctrine: ['Fresh data', 'Final logic', 'Clean provenance'],
  migration_count: migrations.length,
  migration_range: [migrations[0], migrations.at(-1)],
  excluded_migrations: [...EXCLUDED_MIGRATIONS].sort(),
  statement_counts: counts,
  disposition_counts: dispositionCounts,
  unresolved_count: unresolved.length,
  blockers,
  review_items: reviewItems,
  resolved_exclusions: resolvedExclusions,
  migrations: migrationAudits,
  final_object_candidates: finalObjects,
};

fs.mkdirSync(outputDir, { recursive: true });
fs.writeFileSync(auditPath, `${JSON.stringify(audit, null, 2)}\n`);

const manifest = {
  format_version: 2,
  build: 'AWS-V0-BUILD-3',
  status: unresolved.length === 0 ? 'READY_FOR_BASELINE_COMPILATION' : 'AUDIT_REQUIRED',
  generated_at: generatedAt,
  source_migrations: migrationAudits.map(({ file, sha256: hash, bytes, statements, canonical_candidate, disposition }) => ({
    file,
    sha256: hash,
    bytes,
    statements,
    canonical_candidate,
    disposition,
  })),
  object_candidates: finalObjects,
  prohibited_historical_data_import: true,
  excluded_migrations: [...EXCLUDED_MIGRATIONS].sort(),
  unresolved_findings: unresolved,
  resolved_exclusions: resolvedExclusions,
};
fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);

if (emitBaseline) {
  if (unresolved.length) {
    console.error(`Refusing baseline emission: ${unresolved.length} unresolved finding(s) (${blockers.length} blocker(s), ${reviewItems.length} review item(s)).`);
    process.exitCode = 2;
  } else {
    console.error('Refusing baseline emission: canonical final-object emitter is not implemented yet.');
    process.exitCode = 3;
  }
}

console.log(JSON.stringify({
  build: 'AWS-V0-BUILD-3',
  audit_format: audit.format_version,
  migrations: migrations.length,
  statements: Object.values(counts).reduce((sum, count) => sum + count, 0),
  excluded_migrations: audit.excluded_migrations,
  unresolved: unresolved.length,
  blockers: blockers.length,
  review_items: reviewItems.length,
  resolved_exclusions: resolvedExclusions.length,
  object_candidates: finalObjects.length,
  audit: path.relative(repoRoot, auditPath),
  manifest: path.relative(repoRoot, manifestPath),
  baseline_emitted: false,
}, null, 2));
