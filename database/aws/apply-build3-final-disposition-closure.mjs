#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const repoRoot = process.cwd();
const migrationsDir = path.resolve(repoRoot, process.env.MARKETROUTE_MIGRATIONS_DIR ?? 'supabase/migrations');
const outputDir = path.resolve(repoRoot, process.env.MARKETROUTE_AWS_DATABASE_DIR ?? 'database/aws');
const baseAuditPath = path.join(outputDir, 'build3_disposition_audit.json');
const baseManifestPath = path.join(outputDir, '0001_marketroute_aws_disposition_manifest.json');
const ledgerPath = path.resolve(
  repoRoot,
  process.env.MARKETROUTE_REVIEWED_DISPOSITIONS_PATH ?? 'database/aws/BUILD3-REVIEWED-DISPOSITIONS.json',
);
const finalAuditPath = path.join(outputDir, 'build3_final_disposition_audit.json');
const finalManifestPath = path.join(outputDir, '0001_marketroute_aws_final_disposition_manifest.json');

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
    if (!fs.existsSync(fullPath)) throw new Error(`Reviewed migration not found: ${file}`);
    cache.set(file, splitSql(fs.readFileSync(fullPath, 'utf8')));
  }
  const statement = cache.get(file)[statementIndex - 1];
  if (!statement) throw new Error(`Statement ${statementIndex} not found in ${file}`);
  return statement;
}

function normalizeMarker(marker) {
  return String(marker ?? '').replace(/\s+/g, ' ').trim().toLowerCase();
}

if (!fs.existsSync(baseAuditPath) || !fs.existsSync(baseManifestPath)) {
  throw new Error('Run apply-build3-dispositions.mjs before final disposition closure.');
}
if (!fs.existsSync(ledgerPath)) throw new Error(`Reviewed disposition ledger not found: ${ledgerPath}`);

const baseAudit = JSON.parse(fs.readFileSync(baseAuditPath, 'utf8'));
const baseManifest = JSON.parse(fs.readFileSync(baseManifestPath, 'utf8'));
const ledgerText = fs.readFileSync(ledgerPath, 'utf8');
const ledger = JSON.parse(ledgerText);

if (baseAudit.build !== 'AWS-V0-BUILD-3' || baseAudit.mode !== 'canonical-disposition') {
  throw new Error('Canonical Build 3 disposition audit required.');
}
if (baseManifest.build !== 'AWS-V0-BUILD-3') throw new Error('Canonical Build 3 disposition manifest required.');
if (ledger.build !== 'AWS-V0-BUILD-3' || ledger.format_version !== 1 || !Array.isArray(ledger.entries)) {
  throw new Error('Reviewed disposition ledger v1 required.');
}

const allowedDispositions = new Set([
  'KEEP_CANONICAL_CONFIGURATION',
  'EXCLUDE_HISTORICAL_BACKFILL_OR_REPAIR',
]);
const ids = new Set();
for (const entry of ledger.entries) {
  if (!entry.id || ids.has(entry.id)) throw new Error(`Duplicate or missing reviewed disposition id: ${entry.id ?? 'UNKNOWN'}`);
  ids.add(entry.id);
  if (!entry.file || !entry.finding_code || !entry.marker || !allowedDispositions.has(entry.disposition)) {
    throw new Error(`Invalid reviewed disposition entry: ${entry.id}`);
  }
}

const statementCache = new Map();
const decisions = baseAudit.decisions.map((d) => ({ ...d }));
const consumedDecisionKeys = new Set();
const matches = [];

for (const entry of ledger.entries) {
  const candidates = [];
  for (let i = 0; i < decisions.length; i += 1) {
    const decision = decisions[i];
    if (decision.file !== entry.file || decision.finding_code !== entry.finding_code) continue;
    if (entry.statement_index != null && decision.statement_index !== entry.statement_index) continue;

    const statement = statementAt(decision.file, decision.statement_index, statementCache);
    const normalized = normalizeSql(statement).toLowerCase();
    if (!normalized.includes(normalizeMarker(entry.marker))) continue;

    if (entry.relation) {
      const relation = (decision.mutation?.relation ?? mutationTarget(statement).relation ?? '').toLowerCase();
      if (relation !== entry.relation.toLowerCase()) continue;
    }
    candidates.push({ i, decision, statement });
  }

  if (candidates.length !== 1) {
    throw new Error(`Reviewed disposition ${entry.id} matched ${candidates.length} findings; expected exactly 1.`);
  }

  const { i, decision, statement } = candidates[0];
  const decisionKey = `${decision.file}:${decision.statement_index}:${decision.finding_code}`;
  if (consumedDecisionKeys.has(decisionKey)) {
    throw new Error(`Reviewed disposition collision on ${decisionKey}`);
  }
  consumedDecisionKeys.add(decisionKey);

  const replacement = {
    ...decision,
    decision_resolved: true,
    disposition: entry.disposition,
    transform_required: false,
    reviewed_disposition_id: entry.id,
    reviewed_ledger_version: ledger.format_version,
    reviewed_statement_sha256: sha256(statement),
    preserve_statement: entry.disposition === 'KEEP_CANONICAL_CONFIGURATION',
    canonical_configuration: entry.disposition === 'KEEP_CANONICAL_CONFIGURATION',
    rationale: entry.rationale,
  };
  decisions[i] = replacement;
  matches.push({
    id: entry.id,
    file: decision.file,
    statement_index: decision.statement_index,
    finding_code: decision.finding_code,
    relation: entry.relation ?? decision.mutation?.relation ?? null,
    disposition: entry.disposition,
    statement_sha256: replacement.reviewed_statement_sha256,
  });
}

if (matches.length !== ledger.entries.length) throw new Error('Reviewed disposition ledger accounting mismatch.');

const unresolved = decisions.filter((d) => !d.decision_resolved);
const resolved = decisions.filter((d) => d.decision_resolved);
const transforms = resolved.filter((d) => d.transform_required);
const exclusions = resolved.filter((d) => d.disposition.startsWith('EXCLUDE_'));
const canonicalConfiguration = resolved.filter((d) => d.disposition === 'KEEP_CANONICAL_CONFIGURATION');
const counts = decisions.reduce((acc, d) => {
  acc[d.disposition] = (acc[d.disposition] ?? 0) + 1;
  return acc;
}, {});

const ledgerSummary = {
  path: path.relative(repoRoot, ledgerPath),
  format_version: ledger.format_version,
  sha256: sha256(ledgerText),
  entry_count: ledger.entries.length,
  matched_count: matches.length,
  matches,
};

const generatedAt = new Date().toISOString();
const finalAudit = {
  format_version: 1,
  build: 'AWS-V0-BUILD-3',
  mode: 'final-disposition-closure',
  generated_at: generatedAt,
  source_disposition_mode: baseAudit.mode,
  raw_unresolved_count: baseAudit.raw_unresolved_count,
  resolved_decisions: resolved.length,
  unresolved_count: unresolved.length,
  required_transforms: transforms.length,
  resolved_exclusions: exclusions.length,
  canonical_configuration_statements: canonicalConfiguration.length,
  disposition_counts: counts,
  reviewed_ledger: ledgerSummary,
  identity_boundary: baseManifest.identity_boundary,
  decisions,
  unresolved,
};

const finalManifest = {
  format_version: 1,
  build: 'AWS-V0-BUILD-3',
  status: unresolved.length === 0 ? 'READY_FOR_FINAL_OBJECT_RESOLUTION' : 'FINAL_DISPOSITION_REVIEW_REQUIRED',
  generated_at: generatedAt,
  prohibited_historical_data_import: true,
  identity_boundary: baseManifest.identity_boundary,
  reviewed_ledger: ledgerSummary,
  required_transforms: transforms,
  canonical_configuration_statements: canonicalConfiguration,
  exclusions,
  unresolved,
  source_disposition_manifest: {
    status: baseManifest.status,
    required_transform_count: baseManifest.required_transforms?.length ?? 0,
    unresolved_count: baseManifest.unresolved?.length ?? 0,
  },
};

fs.writeFileSync(finalAuditPath, `${JSON.stringify(finalAudit, null, 2)}\n`);
fs.writeFileSync(finalManifestPath, `${JSON.stringify(finalManifest, null, 2)}\n`);

console.log(JSON.stringify({
  build: finalAudit.build,
  mode: finalAudit.mode,
  raw_unresolved: finalAudit.raw_unresolved_count,
  resolved_decisions: finalAudit.resolved_decisions,
  unresolved: finalAudit.unresolved_count,
  required_transforms: finalAudit.required_transforms,
  resolved_exclusions: finalAudit.resolved_exclusions,
  canonical_configuration_statements: finalAudit.canonical_configuration_statements,
  reviewed_ledger_entries: ledgerSummary.entry_count,
  reviewed_ledger_matches: ledgerSummary.matched_count,
  disposition_counts: finalAudit.disposition_counts,
  manifest_status: finalManifest.status,
  audit: path.relative(repoRoot, finalAuditPath),
  manifest: path.relative(repoRoot, finalManifestPath),
}, null, 2));
