#!/usr/bin/env node
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const repoRoot = process.cwd();
const generator = path.resolve(repoRoot, 'database/aws/build3-final-object-replay.mjs');
const verifier = path.resolve(repoRoot, 'database/aws/verify-build3-final-object-dump.mjs');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mr-final-object-'));
const migrationsDir = path.join(root, 'migrations');
const outputDir = path.join(root, 'aws');
fs.mkdirSync(migrationsDir, { recursive: true });
fs.mkdirSync(outputDir, { recursive: true });

try {
  const statements = ['BEGIN;'];
  const decisions = [];

  for (let i = 0; i < 19; i += 1) {
    statements.push(`INSERT INTO public.config_${i}(k) VALUES ('v${i}');`);
    decisions.push({
      file: '0001_fixture.sql',
      statement_index: 2 + i,
      disposition: 'KEEP_CANONICAL_CONFIGURATION',
      decision_resolved: true,
      transform_required: false,
    });
  }

  for (let i = 0; i < 35; i += 1) {
    statements.push(`CREATE OR REPLACE FUNCTION public.legacy_actor_${i}() RETURNS uuid LANGUAGE sql AS $$ SELECT auth.uid() $$;`);
    decisions.push({
      file: '0001_fixture.sql',
      statement_index: 21 + i,
      disposition: 'REWRITE_AUTH_UID_TO_EXPLICIT_ACTOR_USER_ID',
      decision_resolved: true,
      transform_required: true,
      transform: 'AUTH_UID_TO_EXPLICIT_UUID_PARAMETER',
    });
  }

  statements.push('GRANT SELECT ON public.example TO authenticated;');
  statements.push("NOTIFY pgrst,'reload schema';");
  statements.push('COMMIT;');

  fs.writeFileSync(path.join(migrationsDir, '0001_fixture.sql'), `${statements.join('\n')}\n`);

  fs.writeFileSync(path.join(outputDir, 'build3_schema_audit.json'), JSON.stringify({
    build: 'AWS-V0-BUILD-3',
    format_version: 2,
    mode: 'hardened-audit',
    migration_count: 1,
    migrations: [{ file: '0001_fixture.sql' }],
    resolved_exclusions: [
      { file: '0001_fixture.sql', statement_index: 56, disposition: 'EXCLUDE_SUPABASE_INFRASTRUCTURE', resolved: true },
      { file: '0001_fixture.sql', statement_index: 57, disposition: 'EXCLUDE_SUPABASE_INFRASTRUCTURE', resolved: true },
    ],
  }, null, 2));

  fs.writeFileSync(path.join(outputDir, 'build3_final_disposition_audit.json'), JSON.stringify({
    build: 'AWS-V0-BUILD-3',
    mode: 'final-disposition-closure',
    unresolved_count: 0,
    required_transforms: 35,
    decisions,
  }, null, 2));

  fs.writeFileSync(path.join(outputDir, '0001_marketroute_aws_final_disposition_manifest.json'), JSON.stringify({
    build: 'AWS-V0-BUILD-3',
    status: 'READY_FOR_FINAL_OBJECT_RESOLUTION',
  }, null, 2));

  const env = {
    ...process.env,
    MARKETROUTE_MIGRATIONS_DIR: migrationsDir,
    MARKETROUTE_AWS_DATABASE_DIR: outputDir,
  };

  const generated = spawnSync(process.execPath, [generator], { cwd: root, env, encoding: 'utf8' });
  assert(generated.status === 0, generated.stderr || generated.stdout);

  const replay = fs.readFileSync(path.join(outputDir, 'build3_final_object_replay.sql'), 'utf8');
  const replayManifest = JSON.parse(fs.readFileSync(path.join(outputDir, 'build3_final_object_replay_manifest.json'), 'utf8'));

  assert(replayManifest.counters.canonical_configuration_statements === 19, 'canonical configuration count mismatch');
  assert(replayManifest.counters.transform_source_statements === 35, 'transform-source decision count mismatch');
  assert(replayManifest.status === 'READY_FOR_EPHEMERAL_POSTGRES_REPLAY', 'unexpected replay status');
  assert(replay.includes("INSERT INTO public.config_0(k) VALUES ('v0');"), 'canonical configuration missing from replay');
  assert(replay.includes('SELECT auth.uid()'), 'legacy transform source missing from replay');
  assert(!replay.includes('GRANT SELECT ON public.example TO authenticated;'), 'Supabase grant leaked into replay');
  assert(!replay.includes("NOTIFY pgrst,'reload schema';"), 'PostgREST notification leaked into replay');

  const requiredTables = [
    'organisations',
    'companies',
    'claims',
    'truth_claim_snapshots',
    'commercial_reality_r4_records',
    'route_authority_r5_records',
    'contact_authority_r6_records',
    'marketroute_plan_catalog',
  ];
  const schema = [];
  for (const name of requiredTables) schema.push(`CREATE TABLE public.${name} (id uuid);`);
  for (let i = requiredTables.length; i < 50; i += 1) schema.push(`CREATE TABLE public.synthetic_table_${i} (id uuid);`);

  schema.push(`CREATE FUNCTION public.marketroute_truth_policy_for_claim_v1() RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  INSERT INTO public.synthetic_table_8(id) VALUES (NULL);
  PERFORM auth.uid();
END;
$fn$;`);
  schema.push('CREATE FUNCTION public.marketroute_authority_envelope_v1() RETURNS void LANGUAGE plpgsql AS $$ BEGIN PERFORM auth.uid(); END $$;');
  schema.push('CREATE FUNCTION public.marketroute_workspace_commercial_access_v1() RETURNS void LANGUAGE plpgsql AS $$ BEGIN PERFORM auth.uid(); END $$;');

  for (let i = 3; i < 150; i += 1) {
    schema.push(`CREATE FUNCTION public.synthetic_function_${i}() RETURNS void LANGUAGE plpgsql AS $$ BEGIN NULL; END $$;`);
  }
  schema.push('ALTER TABLE public.organisations ENABLE ROW LEVEL SECURITY;');
  schema.push('CREATE FUNCTION public.marketroute_founder_dashboard_snapshot_v1() RETURNS void LANGUAGE plpgsql AS $$ BEGIN PERFORM 1 FROM public.marketroute_v1_migration_batches; END $$;');

  const referenceSchemaPath = path.join(outputDir, 'build3_final_object_reference_schema.sql');
  fs.writeFileSync(referenceSchemaPath, `${schema.join('\n')}\n`);

  const verifierEnv = {
    ...env,
    MARKETROUTE_FINAL_OBJECT_REFERENCE_SCHEMA: referenceSchemaPath,
  };

  const verified = spawnSync(process.execPath, [verifier], {
    cwd: root,
    env: verifierEnv,
    encoding: 'utf8',
  });
  assert(verified.status === 0, verified.stderr || verified.stdout);

  const resolution = JSON.parse(fs.readFileSync(path.join(outputDir, 'build3_final_object_resolution_manifest.json'), 'utf8'));
  assert(resolution.status === 'FINAL_OBJECTS_RESOLVED_AWS_TRANSFORMS_PENDING', 'expected transform-pending status');
  const blockerCodes = new Set(resolution.blockers.map((b) => b.code));
  assert(blockerCodes.has('AWS_AUTH_UID_REFERENCE_REWRITE_PENDING'), 'auth.uid blocker missing');
  assert(blockerCodes.has('AWS_RLS_EXECUTION_MODEL_REVIEW_REQUIRED'), 'RLS blocker missing');
  assert(blockerCodes.has('V1_ETL_REFERENCE_REWRITE_PENDING'), 'V1 observability blocker missing');
  assert(resolution.source_reference_schema.schema_only === true, 'schema-only proof missing');
  assert(resolution.source_reference_schema.top_level_data_mutation_count === 0, 'top-level data mutation proof missing');
  assert(resolution.source_reference_schema.routine_body_dml_allowed === true, 'routine-body DML boundary missing');

  fs.appendFileSync(referenceSchemaPath, '\nINSERT INTO public.organisations(id) VALUES (NULL);\n');
  const topLevelMutationRejected = spawnSync(process.execPath, [verifier], {
    cwd: root,
    env: verifierEnv,
    encoding: 'utf8',
  });
  assert(topLevelMutationRejected.status !== 0, 'verifier must reject top-level INSERT in schema-only dump');
  assert(
    `${topLevelMutationRejected.stderr}\n${topLevelMutationRejected.stdout}`.includes('top-level data mutation: INSERT'),
    'verifier rejected top-level INSERT for the wrong reason',
  );

  const badAudit = JSON.parse(fs.readFileSync(path.join(outputDir, 'build3_final_disposition_audit.json'), 'utf8'));
  badAudit.required_transforms = 34;
  fs.writeFileSync(path.join(outputDir, 'build3_final_disposition_audit.json'), JSON.stringify(badAudit, null, 2));
  const failClosed = spawnSync(process.execPath, [generator], { cwd: root, env, encoding: 'utf8' });
  assert(failClosed.status !== 0, 'generator must fail closed when transform count drifts');

  console.log(JSON.stringify({
    build: 'AWS-V0-BUILD-3',
    test: 'final-object-resolver',
    status: 'PASS',
    canonical_configuration_statements: 19,
    transform_source_decisions: 35,
    schema_only_reference_verified: true,
    routine_body_dml_ignored_by_top_level_data_gate: true,
    top_level_data_mutation_rejected: true,
    blocker_detection_verified: [...blockerCodes].sort(),
    fail_closed_transform_drift: true,
  }, null, 2));
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}