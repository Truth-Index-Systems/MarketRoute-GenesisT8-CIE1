import crypto from 'node:crypto';
import fs from 'node:fs';

export const DATA_API_SQL_MAX_BYTES = 65536;
export const EXPECTED_BASELINE_SHA256 = '46d9c3aee85d1021d7f514c0384aef036b7f53073a7aa78be4bfabd3266d5e5a';
export const EXPECTED_BASELINE_BYTES = 859730;
export const EXPECTED_STATEMENT_COUNT = 792;
export const EXPECTED_MAX_STATEMENT_BYTES = 19130;
export const EXPECTED_CANONICAL_MUTATIONS = 19;

export function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

export function splitTopLevelSql(sql) {
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

export function stripPsqlMetaCommands(sql) {
  const meta = [];
  const body = sql
    .split(/\r?\n/)
    .filter((line) => {
      if (/^\\(?:restrict|unrestrict)\b/.test(line)) {
        meta.push(line);
        return false;
      }
      return true;
    })
    .join('\n');
  return { sql: body, meta };
}

function stripLeadingNoise(statement) {
  let value = statement.trimStart();
  for (;;) {
    const before = value;
    value = value.replace(/^--[^\n]*(?:\n|$)/, '').trimStart();
    value = value.replace(/^\/\*[\s\S]*?\*\//, '').trimStart();
    if (before === value) return value;
  }
}

export function topLevelMutation(statement) {
  const sql = stripLeadingNoise(statement);
  if (/^INSERT\s+INTO\b/i.test(sql)) return 'INSERT';
  if (/^UPDATE\b/i.test(sql)) return 'UPDATE';
  if (/^DELETE\s+FROM\b/i.test(sql)) return 'DELETE';
  if (/^COPY\b[\s\S]*\bFROM\s+stdin\b/i.test(sql)) return 'COPY_FROM_STDIN';
  return null;
}

export function mutationRelation(statement) {
  const sql = stripLeadingNoise(statement);
  const match = sql.match(/^(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+(?:ONLY\s+)?(?:public\.)?([A-Za-z_][A-Za-z0-9_]*)/i);
  return match?.[1]?.toLowerCase() ?? null;
}

export function inspectBaseline(raw) {
  const stripped = stripPsqlMetaCommands(raw);
  const statements = splitTopLevelSql(stripped.sql);
  const statementBytes = statements.map((statement) => Buffer.byteLength(statement));
  const mutations = statements
    .map((statement, index) => ({ index, kind: topLevelMutation(statement), relation: mutationRelation(statement) }))
    .filter((entry) => entry.kind);

  return {
    raw_sha256: sha256(raw),
    raw_bytes: Buffer.byteLength(raw),
    meta_commands: stripped.meta,
    statements,
    statement_count: statements.length,
    max_statement_bytes: Math.max(0, ...statementBytes),
    mutations,
    mutation_count: mutations.length,
  };
}

export function readJson(path) {
  return JSON.parse(fs.readFileSync(path, 'utf8'));
}
