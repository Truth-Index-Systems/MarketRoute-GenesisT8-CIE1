#!/usr/bin/env node
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const compiler = path.resolve(process.cwd(), 'database/aws/compile-canonical-baseline.mjs');

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'marketroute-build3-'));
const migrationsDir = path.join(root, 'migrations');
const outputDir = path.join(root, 'aws');
fs.mkdirSync(migrationsDir, { recursive: true });

fs.writeFileSync(path.join(migrationsDir, '0001_fixture.sql'), `
BEGIN;
CREATE TABLE public.fixture (id uuid PRIMARY KEY, owner_id uuid REFERENCES auth.users(id), value text);
CREATE OR REPLACE FUNCTION public.fixture_runtime_write(p_id uuid, p_value text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO public.fixture(id, value) VALUES (p_id, p_value);
END;
$$;
GRANT SELECT ON public.fixture TO service_role;
NOTIFY pgrst, 'reload schema';
DO $$
BEGIN
  UPDATE public.fixture SET value = 'backfill';
END;
$$;
DO $$
BEGIN
  RAISE NOTICE 'UPDATE is text only';
  -- INSERT is a comment only
END;
$$;
WITH changed AS (
  UPDATE public.fixture SET value = 'cte-backfill' RETURNING id
)
SELECT count(*) FROM changed;
COMMIT;
`);

fs.writeFileSync(path.join(migrationsDir, '0019_v1_evidence_migration.sql'), `
CREATE OR REPLACE FUNCTION public.should_never_be_candidate()
RETURNS void LANGUAGE plpgsql AS $$ BEGIN NULL; END; $$;
`);

function run(args = []) {
  return spawnSync(process.execPath, [compiler, ...args], {
    cwd: root,
    env: {
      ...process.env,
      MARKETROUTE_MIGRATIONS_DIR: migrationsDir,
      MARKETROUTE_AWS_DATABASE_DIR: outputDir,
    },
    encoding: 'utf8',
  });
}

try {
  const first = run();
  assert(first.status === 0, `audit run failed: ${first.stderr || first.stdout}`);

  const audit = JSON.parse(fs.readFileSync(path.join(outputDir, 'build3_schema_audit.json'), 'utf8'));
  const manifest = JSON.parse(fs.readFileSync(path.join(outputDir, '0001_marketroute_aws_schema_manifest.json'), 'utf8'));

  assert(audit.format_version === 2, 'expected hardened audit format v2');
  assert(audit.mode === 'hardened-audit', 'expected hardened audit mode');
  assert(manifest.format_version === 2, 'expected manifest format v2');
  assert(manifest.prohibited_historical_data_import === true, 'fresh-data prohibition missing');

  const fixture = audit.migrations.find((m) => m.file === '0001_fixture.sql');
  const excluded = audit.migrations.find((m) => m.file === '0019_v1_evidence_migration.sql');
  assert(fixture, 'fixture migration missing');
  assert(excluded && excluded.canonical_candidate === false, '0019 must be excluded from canonical candidates');
  assert(!audit.final_object_candidates.some((o) => o.key.includes('should_never_be_candidate')), '0019 object leaked into canonical candidates');

  assert(fixture.findings.some((f) => f.code === 'POSTGREST_NOTIFY_EXCLUDED' && f.resolved === true), 'PostgREST NOTIFY was not explicitly excluded');
  assert(fixture.findings.some((f) => f.code === 'SUPABASE_ROLE_GRANT_EXCLUDED' && f.resolved === true), 'Supabase role grant was not explicitly excluded');
  assert(fixture.findings.some((f) => f.code === 'AWS_IDENTITY_REWRITE_REQUIRED' && f.resolved === false), 'auth.users dependency was not held for AWS rewrite');

  const doFindings = fixture.findings.filter((f) => f.code === 'HIDDEN_DO_BLOCK_DML_REVIEW');
  assert(doFindings.length === 1, `expected exactly one mutating DO block, got ${doFindings.length}`);
  assert(doFindings[0].mutation_keywords.includes('UPDATE'), 'mutating DO block UPDATE not detected');
  assert(fixture.findings.some((f) => f.code === 'CTE_DML_REVIEW' && f.mutation_keywords.includes('UPDATE')), 'CTE UPDATE not detected');

  const runtime = audit.final_object_candidates.find((o) => o.key.startsWith('routine:public.fixture_runtime_write'));
  assert(runtime, 'runtime writing function was not preserved as canonical candidate');
  const runtimeStatementIndex = runtime.final_source.statement_index;
  assert(!fixture.findings.some((f) => f.statement_index === runtimeStatementIndex && /DML_REVIEW$/.test(f.code)), 'runtime function DML was misclassified as migration-time DML');

  const emitted = run(['--emit-baseline']);
  assert(emitted.status === 2, `expected fail-closed exit 2 while unresolved findings remain, got ${emitted.status}`);
  assert(!fs.existsSync(path.join(outputDir, '0001_marketroute_aws_canonical_baseline.sql')), 'baseline was emitted despite unresolved findings');

  console.log(JSON.stringify({
    build: 'AWS-V0-BUILD-3',
    test: 'compiler-hardening',
    status: 'PASS',
    hidden_do_mutations: doFindings.length,
    unresolved_findings: audit.unresolved_count,
    resolved_exclusions: audit.resolved_exclusions.length,
    runtime_writer_preserved: true,
    v1_etl_candidate_excluded: true,
  }, null, 2));
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
