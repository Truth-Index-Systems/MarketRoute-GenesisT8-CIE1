#!/usr/bin/env node
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const engine = path.resolve(process.cwd(), 'database/aws/apply-build3-dispositions.mjs');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mr-disposition-'));
const migrationsDir = path.join(root, 'migrations');
const outputDir = path.join(root, 'aws');
fs.mkdirSync(migrationsDir, { recursive: true });
fs.mkdirSync(outputDir, { recursive: true });

const migration = `
CREATE TABLE public.organisations (
  id uuid PRIMARY KEY,
  created_by uuid NOT NULL REFERENCES auth.users(id)
);
CREATE OR REPLACE FUNCTION public.member_check(p_org uuid)
RETURNS boolean LANGUAGE sql AS $$
  SELECT EXISTS (SELECT 1 FROM public.organisations WHERE created_by = auth.uid());
$$;
CREATE POLICY org_select ON public.organisations FOR SELECT TO authenticated USING (created_by = auth.uid());
CREATE OR REPLACE FUNCTION public.require_backend()
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_role text := COALESCE(auth.role()::text, current_setting('request.jwt.claim.role', true));
BEGIN NULL; END;
$$;
INSERT INTO public.marketroute_schema_releases(release_key) VALUES ('OLD');
UPDATE public.organisations SET created_by = created_by;
INSERT INTO public.canonical_config(key) VALUES ('KEEP_ME_MAYBE');
DO $$ BEGIN UPDATE public.organisations SET created_by = created_by; END; $$;
WITH changed AS (UPDATE public.organisations SET created_by = created_by RETURNING id) SELECT count(*) FROM changed;
`;
fs.writeFileSync(path.join(migrationsDir, '0001_fixture.sql'), migration);

const findings = [
  ['AWS_IDENTITY_REWRITE_REQUIRED', 'BLOCKER', 1],
  ['AWS_IDENTITY_REWRITE_REQUIRED', 'BLOCKER', 2],
  ['AWS_IDENTITY_REWRITE_REQUIRED', 'BLOCKER', 3],
  ['SUPABASE_ROLE_REWRITE_REQUIRED', 'BLOCKER', 3],
  ['AWS_IDENTITY_REWRITE_REQUIRED', 'BLOCKER', 4],
  ['AWS_REQUEST_JWT_REWRITE_REQUIRED', 'BLOCKER', 4],
  ['MIGRATION_TIME_DML_REVIEW', 'REVIEW', 5],
  ['MIGRATION_TIME_DML_REVIEW', 'REVIEW', 6],
  ['MIGRATION_TIME_DML_REVIEW', 'REVIEW', 7],
  ['HIDDEN_DO_BLOCK_DML_REVIEW', 'REVIEW', 8],
  ['CTE_DML_REVIEW', 'REVIEW', 9],
].map(([code, severity, statement_index], i) => ({ file: '0001_fixture.sql', code, severity, statement_index, sha256: `sha${i}` }));

const blockers = findings.filter((f) => f.severity === 'BLOCKER');
const review_items = findings.filter((f) => f.severity === 'REVIEW');
fs.writeFileSync(path.join(outputDir, 'build3_schema_audit.json'), JSON.stringify({
  format_version: 2,
  mode: 'hardened-audit',
  blockers,
  review_items,
}, null, 2));
fs.writeFileSync(path.join(outputDir, '0001_marketroute_aws_schema_manifest.json'), JSON.stringify({
  format_version: 2,
  excluded_migrations: ['0019_v1_evidence_migration.sql'],
  object_candidates: [{ key: 'table:public.organisations' }],
}, null, 2));

const run = spawnSync(process.execPath, [engine], {
  cwd: root,
  env: {
    ...process.env,
    MARKETROUTE_MIGRATIONS_DIR: migrationsDir,
    MARKETROUTE_AWS_DATABASE_DIR: outputDir,
  },
  encoding: 'utf8',
});

try {
  assert(run.status === 0, run.stderr || run.stdout);
  const audit = JSON.parse(fs.readFileSync(path.join(outputDir, 'build3_disposition_audit.json'), 'utf8'));
  const manifest = JSON.parse(fs.readFileSync(path.join(outputDir, '0001_marketroute_aws_disposition_manifest.json'), 'utf8'));

  assert(audit.raw_unresolved_count === 11, `raw count ${audit.raw_unresolved_count}`);
  assert(audit.resolved_decisions === 10, `expected ten resolved decisions, got ${audit.resolved_decisions}`);
  assert(audit.unresolved_count === 1, `expected one canonical seed review, got ${audit.unresolved_count}`);
  assert(manifest.status === 'DISPOSITION_REVIEW_REQUIRED', 'expected review-required status');
  assert(audit.decisions.some((d) => d.disposition === 'REWRITE_AUTH_USERS_FK_TO_MARKETROUTE_USERS' && d.decision_resolved), 'auth.users rewrite missing');
  assert(audit.decisions.some((d) => d.disposition === 'REWRITE_AUTH_UID_TO_EXPLICIT_ACTOR_USER_ID' && d.decision_resolved), 'auth.uid rewrite missing');
  assert(audit.decisions.filter((d) => d.disposition === 'EXCLUDE_SUPABASE_RLS_POLICY' && d.decision_resolved).length === 2, 'policy findings must collapse to exclusions');
  assert(!audit.decisions.some((d) => d.statement_index === 3 && d.transform_required), 'excluded RLS policy must not require a transform');
  assert(audit.decisions.filter((d) => d.disposition === 'REWRITE_TO_TRUSTED_BACKEND_EXECUTION_BOUNDARY').length === 2, 'backend boundary rewrites missing');
  assert(audit.decisions.some((d) => d.disposition === 'EXCLUDE_HISTORICAL_SCHEMA_RELEASE_ROW'), 'schema release exclusion missing');
  assert(audit.decisions.filter((d) => d.disposition === 'EXCLUDE_HISTORICAL_BACKFILL_OR_REPAIR').length === 3, 'historical backfill exclusions missing');
  assert(audit.unresolved[0].disposition === 'CANONICAL_SEED_REVIEW_REQUIRED', 'seed review missing');
  assert(audit.unresolved[0].mutation?.relation === 'public.canonical_config', 'seed target missing');
  assert(manifest.identity_boundary.internal_user_relation === 'public.marketroute_users', 'identity relation missing');
  assert(manifest.identity_boundary.external_identity_binding === 'DEFER_TO_BUILD_5', 'Build 5 boundary missing');

  console.log(JSON.stringify({
    build: 'AWS-V0-BUILD-3',
    test: 'disposition-engine',
    status: 'PASS',
    raw_unresolved: audit.raw_unresolved_count,
    resolved: audit.resolved_decisions,
    unresolved: audit.unresolved_count,
    required_transforms: audit.required_transforms,
    canonical_seed_reviews: audit.unresolved.filter((d) => d.disposition === 'CANONICAL_SEED_REVIEW_REQUIRED').length,
    identity_boundary: manifest.identity_boundary.version,
  }, null, 2));
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
