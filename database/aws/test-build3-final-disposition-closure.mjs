#!/usr/bin/env node
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const engine = path.resolve(process.cwd(), 'database/aws/apply-build3-final-disposition-closure.mjs');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mr-final-disposition-'));
const migrationsDir = path.join(root, 'migrations');
const outputDir = path.join(root, 'aws');
const ledgerPath = path.join(root, 'ledger.json');
fs.mkdirSync(migrationsDir, { recursive: true });
fs.mkdirSync(outputDir, { recursive: true });

const migration = `
BEGIN;
INSERT INTO public.canonical_config(key,value) VALUES('A','v1');
UPDATE public.canonical_config SET value='v2' WHERE key='A';
DO $$ BEGIN INSERT INTO public.runtime_history(id) VALUES(gen_random_uuid()); END; $$;
COMMIT;
`;
fs.writeFileSync(path.join(migrationsDir, '0001_fixture.sql'), migration);

const decisions = [
  {
    file: '0001_fixture.sql', statement_index: 2, finding_code: 'MIGRATION_TIME_DML_REVIEW', severity: 'REVIEW',
    decision_resolved: false, disposition: 'CANONICAL_SEED_REVIEW_REQUIRED', transform_required: false,
    mutation: { verb: 'INSERT', relation: 'public.canonical_config' },
  },
  {
    file: '0001_fixture.sql', statement_index: 3, finding_code: 'MIGRATION_TIME_DML_REVIEW', severity: 'REVIEW',
    decision_resolved: true, disposition: 'EXCLUDE_HISTORICAL_BACKFILL_OR_REPAIR', transform_required: false,
    mutation: { verb: 'UPDATE', relation: 'public.canonical_config' },
  },
  {
    file: '0001_fixture.sql', statement_index: 4, finding_code: 'HIDDEN_DO_BLOCK_DML_REVIEW', severity: 'REVIEW',
    decision_resolved: false, disposition: 'CANONICAL_SEED_REVIEW_REQUIRED', transform_required: false,
    mutation_keywords: ['INSERT'],
  },
];

fs.writeFileSync(path.join(outputDir, 'build3_disposition_audit.json'), JSON.stringify({
  format_version: 1,
  build: 'AWS-V0-BUILD-3',
  mode: 'canonical-disposition',
  raw_unresolved_count: 3,
  resolved_decisions: 1,
  unresolved_count: 2,
  required_transforms: 0,
  resolved_exclusions: 1,
  decisions,
  unresolved: decisions.filter((d) => !d.decision_resolved),
}, null, 2));

fs.writeFileSync(path.join(outputDir, '0001_marketroute_aws_disposition_manifest.json'), JSON.stringify({
  format_version: 1,
  build: 'AWS-V0-BUILD-3',
  status: 'DISPOSITION_REVIEW_REQUIRED',
  prohibited_historical_data_import: true,
  identity_boundary: {
    version: 'AWS-V0-INTERNAL-IDENTITY-1',
    internal_user_relation: 'public.marketroute_users',
  },
  required_transforms: [],
  unresolved: decisions.filter((d) => !d.decision_resolved),
}, null, 2));

const ledger = {
  format_version: 1,
  build: 'AWS-V0-BUILD-3',
  entries: [
    {
      id: 'seed', file: '0001_fixture.sql', finding_code: 'MIGRATION_TIME_DML_REVIEW', relation: 'public.canonical_config',
      marker: "VALUES('A','v1')", disposition: 'KEEP_CANONICAL_CONFIGURATION', rationale: 'fixture seed',
    },
    {
      id: 'config-update', file: '0001_fixture.sql', finding_code: 'MIGRATION_TIME_DML_REVIEW', relation: 'public.canonical_config',
      marker: "SET value='v2'", disposition: 'KEEP_CANONICAL_CONFIGURATION', rationale: 'fixture config evolution',
    },
    {
      id: 'historical-do', file: '0001_fixture.sql', finding_code: 'HIDDEN_DO_BLOCK_DML_REVIEW',
      marker: 'INSERT INTO public.runtime_history', disposition: 'EXCLUDE_HISTORICAL_BACKFILL_OR_REPAIR', rationale: 'fixture history',
    },
  ],
};
fs.writeFileSync(ledgerPath, JSON.stringify(ledger, null, 2));

function runClosure(pathToLedger) {
  return spawnSync(process.execPath, [engine], {
    cwd: root,
    env: {
      ...process.env,
      MARKETROUTE_MIGRATIONS_DIR: migrationsDir,
      MARKETROUTE_AWS_DATABASE_DIR: outputDir,
      MARKETROUTE_REVIEWED_DISPOSITIONS_PATH: pathToLedger,
    },
    encoding: 'utf8',
  });
}

try {
  const run = runClosure(ledgerPath);
  assert(run.status === 0, run.stderr || run.stdout);

  const audit = JSON.parse(fs.readFileSync(path.join(outputDir, 'build3_final_disposition_audit.json'), 'utf8'));
  const manifest = JSON.parse(fs.readFileSync(path.join(outputDir, '0001_marketroute_aws_final_disposition_manifest.json'), 'utf8'));

  assert(audit.raw_unresolved_count === 3, 'raw count mismatch');
  assert(audit.resolved_decisions === 3, 'all fixture decisions must resolve');
  assert(audit.unresolved_count === 0, 'fixture closure must have zero unresolved decisions');
  assert(audit.canonical_configuration_statements === 2, 'seed and config update must both be preserved');
  assert(audit.resolved_exclusions === 1, 'historical DO block must be excluded');
  assert(audit.reviewed_ledger.entry_count === 3 && audit.reviewed_ledger.matched_count === 3, 'ledger match accounting failed');
  assert(audit.decisions.filter((d) => d.disposition === 'KEEP_CANONICAL_CONFIGURATION').every((d) => d.preserve_statement === true), 'canonical configuration must be marked for preservation');
  assert(manifest.status === 'READY_FOR_FINAL_OBJECT_RESOLUTION', 'closure readiness status missing');

  const badLedger = {
    ...ledger,
    entries: ledger.entries.map((e) => ({ ...e })),
  };
  badLedger.entries[0].marker = 'THIS_MARKER_MUST_NOT_MATCH';
  const badLedgerPath = path.join(root, 'bad-ledger.json');
  fs.writeFileSync(badLedgerPath, JSON.stringify(badLedger, null, 2));
  const badRun = runClosure(badLedgerPath);
  assert(badRun.status !== 0, 'closure must fail closed when a reviewed statement no longer matches');

  console.log(JSON.stringify({
    build: 'AWS-V0-BUILD-3',
    test: 'final-disposition-closure',
    status: 'PASS',
    raw_unresolved: audit.raw_unresolved_count,
    resolved: audit.resolved_decisions,
    unresolved: audit.unresolved_count,
    canonical_configuration_statements: audit.canonical_configuration_statements,
    reviewed_entries: audit.reviewed_ledger.entry_count,
    fail_closed_marker_drift: true,
    manifest_status: manifest.status,
  }, null, 2));
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
