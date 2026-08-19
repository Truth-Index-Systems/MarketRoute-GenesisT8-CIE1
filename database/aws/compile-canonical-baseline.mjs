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

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function listMigrations() {
  if (!fs.existsSync(migrationsDir)) throw new Error(`Migration directory not found: ${migrationsDir}`);
  return fs.readdirSync(migrationsDir)
    .filter((name) => /^\d{4}_.+\.sql$/.test(name))
    .sort((a, b) => a.localeCompare(b, 'en'));
}

// SQL statement splitter aware of comments, quoted strings/identifiers and PostgreSQL dollar quoting.
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

function classify(statement) {
  const normalized = stripLeadingComments(statement).replace(/\s+/g, ' ').trim();
  const upper = normalized.toUpperCase();
  if (/^(BEGIN|COMMIT|ROLLBACK)(\s|;|$)/.test(upper)) return 'transaction';
  if (/^(INSERT|UPDATE|DELETE|TRUNCATE|COPY)\b/.test(upper)) return 'data-mutation';
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
  if (/^(DO|SELECT|WITH|COMMENT|SET|RESET)\b/.test(upper)) return 'procedural-or-query';
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

const SUPABASE_PATTERNS = [
  ['auth-schema', /\bauth\.(?:users|uid\s*\(|jwt\s*\()/i],
  ['supabase-role', /\b(?:anon|authenticated|service_role)\b/i],
  ['request-jwt-setting', /current_setting\s*\(\s*['"]request\.jwt\./i],
  ['storage-schema', /\bstorage\./i],
  ['postgrest', /\bpostgrest\b|\/rest\/v1\//i],
];

const migrations = listMigrations();
if (migrations.length === 0) throw new Error('No ordered SQL migrations found.');
const findings = [];
const objectHistory = new Map();
const counts = {};

for (const file of migrations) {
  const fullPath = path.join(migrationsDir, file);
  const source = fs.readFileSync(fullPath, 'utf8');
  const statements = splitSql(source);
  const migration = {
    file,
    sha256: sha256(source),
    bytes: Buffer.byteLength(source),
    statements: statements.length,
    findings: [],
  };

  statements.forEach((statement, index) => {
    const kind = classify(statement);
    counts[kind] = (counts[kind] ?? 0) + 1;
    const id = objectIdentity(statement, kind);
    if (id) {
      const key = `${kind}:${id.toLowerCase()}`;
      const history = objectHistory.get(key) ?? [];
      history.push({ file, statement_index: index + 1, sha256: sha256(statement) });
      objectHistory.set(key, history);
    }
    if (kind === 'data-mutation') {
      migration.findings.push({ severity: 'REVIEW', code: 'HISTORICAL_DML', statement_index: index + 1, sha256: sha256(statement) });
    }
    if (kind === 'unclassified') {
      migration.findings.push({ severity: 'REVIEW', code: 'UNCLASSIFIED_SQL', statement_index: index + 1, sha256: sha256(statement) });
    }
    for (const [code, pattern] of SUPABASE_PATTERNS) {
      if (pattern.test(statement)) {
        migration.findings.push({
          severity: 'BLOCKER',
          code: `SUPABASE_${code.toUpperCase().replaceAll('-', '_')}`,
          statement_index: index + 1,
          sha256: sha256(statement),
        });
      }
    }
  });

  // This is an offline V1 -> V2 ETL migration. It is forensic input, never part of fresh AWS history.
  if (file === '0019_v1_evidence_migration.sql') {
    migration.findings.push({ severity: 'BLOCKER', code: 'V1_ETL_EXCLUDED_FROM_AWS_BASELINE' });
  }
  findings.push(migration);
}

const finalObjects = [...objectHistory.entries()].map(([key, history]) => ({
  key,
  revisions: history.length,
  final_source: history.at(-1),
  superseded_sources: history.slice(0, -1),
})).sort((a, b) => a.key.localeCompare(b.key, 'en'));

const allFindings = findings.flatMap((migration) => migration.findings.map((finding) => ({ file: migration.file, ...finding })));
const blockers = allFindings.filter((finding) => finding.severity === 'BLOCKER');
const reviewItems = allFindings.filter((finding) => finding.severity === 'REVIEW');
const generatedAt = new Date().toISOString();

const audit = {
  format_version: 1,
  build: 'AWS-V0-BUILD-3',
  mode: 'audit',
  generated_at: generatedAt,
  doctrine: ['Fresh data', 'Final logic', 'Clean provenance'],
  migration_count: migrations.length,
  migration_range: [migrations[0], migrations.at(-1)],
  statement_counts: counts,
  blockers,
  review_items: reviewItems,
  migrations: findings,
  final_object_candidates: finalObjects,
};

fs.mkdirSync(outputDir, { recursive: true });
fs.writeFileSync(auditPath, `${JSON.stringify(audit, null, 2)}\n`);

const manifest = {
  format_version: 1,
  build: 'AWS-V0-BUILD-3',
  status: blockers.length === 0 && reviewItems.length === 0 ? 'READY_FOR_BASELINE_COMPILATION' : 'AUDIT_REQUIRED',
  generated_at: generatedAt,
  source_migrations: findings.map(({ file, sha256: hash, bytes, statements }) => ({ file, sha256: hash, bytes, statements })),
  object_candidates: finalObjects,
  prohibited_historical_data_import: true,
  excluded_migrations: ['0019_v1_evidence_migration.sql'],
  unresolved_blockers: blockers,
  unresolved_review_items: reviewItems,
};
fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);

if (emitBaseline) {
  if (blockers.length || reviewItems.length) {
    console.error(`Refusing baseline emission: ${blockers.length} blocker(s), ${reviewItems.length} review item(s).`);
    process.exitCode = 2;
  } else {
    // Deliberately unreachable until historical DML and infrastructure coupling are explicitly classified.
    fs.writeFileSync(baselinePath, '-- AWS-V0 Build 3 canonical baseline\n-- Compiler gate cleared.\n');
  }
}

console.log(JSON.stringify({
  build: 'AWS-V0-BUILD-3',
  migrations: migrations.length,
  statements: Object.values(counts).reduce((sum, count) => sum + count, 0),
  blockers: blockers.length,
  review_items: reviewItems.length,
  audit: path.relative(repoRoot, auditPath),
  manifest: path.relative(repoRoot, manifestPath),
  baseline_emitted: emitBaseline && blockers.length === 0 && reviewItems.length === 0,
}, null, 2));
