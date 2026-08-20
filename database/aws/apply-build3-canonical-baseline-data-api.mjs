#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { inspectBaseline, readJson } from './build3-canonical-baseline-lib.mjs';

const TARGET = Object.freeze({
  accountId: '801132668416',
  region: 'eu-west-2',
  clusterId: 'marketroute-aws-v0',
  clusterArn: 'arn:aws:rds:eu-west-2:801132668416:cluster:marketroute-aws-v0',
  secretArn: 'arn:aws:secretsmanager:eu-west-2:801132668416:secret:marketroute/aws-v0/database/admin-pXxyUD',
  database: 'marketroute',
  confirmation: 'APPLY_AWS_V0_BUILD3_BASELINE',
});

const repoRoot = process.cwd();
const baselinePath = path.resolve(repoRoot, process.env.MARKETROUTE_CANONICAL_BASELINE_PATH ?? 'database/aws/0001_marketroute_aws_canonical_baseline.sql');
const manifestPath = path.resolve(repoRoot, process.env.MARKETROUTE_CANONICAL_BASELINE_MANIFEST_PATH ?? 'database/aws/0001_marketroute_aws_canonical_baseline_manifest.json');
const receiptPath = path.resolve(repoRoot, process.env.MARKETROUTE_AURORA_APPLY_RECEIPT_PATH ?? 'database/aws/build3_aurora_apply_receipt.json');
const apply = process.argv.includes('--apply');
const jsonOnly = process.argv.includes('--json');

if (!fs.existsSync(baselinePath) || !fs.existsSync(manifestPath)) throw new Error('Promoted canonical baseline and manifest are required.');
const raw = fs.readFileSync(baselinePath, 'utf8');
const manifest = readJson(manifestPath);
const inspection = inspectBaseline(raw);
if (manifest.status !== 'CANONICAL_BASELINE_PROMOTED_PENDING_MANUAL_AURORA_APPLICATION') throw new Error('Baseline promotion gate is not ready.');
if (inspection.raw_sha256 !== manifest.canonical_baseline?.sha256) throw new Error('Baseline hash does not match promotion manifest.');
if (inspection.statement_count !== manifest.data_api_application_contract?.canonical_statement_count) throw new Error('Baseline statement count does not match promotion manifest.');
if (inspection.max_statement_bytes > manifest.data_api_application_contract?.execute_statement_sql_max_bytes) throw new Error('Baseline contains a statement larger than the pinned Data API limit.');

const plan = {
  build: 'AWS-V0-BUILD-3',
  mode: apply ? 'manual-aurora-application' : 'aurora-application-plan',
  baseline_sha256: inspection.raw_sha256,
  baseline_bytes: inspection.raw_bytes,
  data_api_statements: inspection.statement_count,
  max_statement_bytes: inspection.max_statement_bytes,
  target: { account_id: TARGET.accountId, region: TARGET.region, cluster_id: TARGET.clusterId, database: TARGET.database },
  automatic_execution: false,
  apply_requested: apply,
};
if (!apply) {
  console.log(JSON.stringify(plan, null, 2));
  process.exit(0);
}
if (process.env.MARKETROUTE_AURORA_BASELINE_CONFIRM !== TARGET.confirmation) {
  throw new Error(`Manual apply requires MARKETROUTE_AURORA_BASELINE_CONFIRM=${TARGET.confirmation}`);
}

function aws(args) {
  const result = spawnSync('aws', [...args, '--region', TARGET.region, '--no-cli-pager', '--output', 'json'], {
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`AWS CLI failed (${args.slice(0, 3).join(' ')}): ${result.stderr || result.stdout}`);
  const text = result.stdout.trim();
  return text ? JSON.parse(text) : {};
}

function dataApi(sql, transactionId = null, formatted = false) {
  const args = [
    'rds-data', 'execute-statement',
    '--resource-arn', TARGET.clusterArn,
    '--secret-arn', TARGET.secretArn,
    '--database', TARGET.database,
    '--sql', sql,
  ];
  if (transactionId) args.push('--transaction-id', transactionId);
  if (formatted) args.push('--format-records-as', 'JSON');
  return aws(args);
}

function rows(sql, transactionId = null) {
  const result = dataApi(sql, transactionId, true);
  return result.formattedRecords ? JSON.parse(result.formattedRecords) : [];
}

const caller = aws(['sts', 'get-caller-identity']);
if (caller.Account !== TARGET.accountId) throw new Error(`Wrong AWS account: ${caller.Account}`);
const cluster = aws(['rds', 'describe-db-clusters', '--db-cluster-identifier', TARGET.clusterId]).DBClusters?.[0];
if (!cluster || cluster.DBClusterArn !== TARGET.clusterArn) throw new Error('Target Aurora cluster identity mismatch.');
if (cluster.Status !== 'available' || cluster.Engine !== 'aurora-postgresql' || cluster.HttpEndpointEnabled !== true) throw new Error('Target Aurora cluster is not available PostgreSQL with Data API enabled.');

const preflight = rows("SELECT count(*)::int AS public_tables FROM pg_catalog.pg_tables WHERE schemaname='public'");
if (Number(preflight[0]?.public_tables ?? -1) !== 0) throw new Error(`Aurora public schema is not empty: ${preflight[0]?.public_tables}`);

let transactionId = null;
try {
  transactionId = aws([
    'rds-data', 'begin-transaction',
    '--resource-arn', TARGET.clusterArn,
    '--secret-arn', TARGET.secretArn,
    '--database', TARGET.database,
  ]).transactionId;
  if (!transactionId) throw new Error('Data API did not return a transaction ID.');

  for (let i = 0; i < inspection.statements.length; i += 1) {
    dataApi(inspection.statements[i], transactionId, false);
    if (!jsonOnly && ((i + 1) % 25 === 0 || i + 1 === inspection.statements.length)) {
      console.log(`Applied ${i + 1}/${inspection.statements.length} canonical statements inside transaction.`);
    }
  }

  aws([
    'rds-data', 'commit-transaction',
    '--resource-arn', TARGET.clusterArn,
    '--secret-arn', TARGET.secretArn,
    '--transaction-id', transactionId,
  ]);
  transactionId = null;
} catch (error) {
  if (transactionId) {
    try {
      aws([
        'rds-data', 'rollback-transaction',
        '--resource-arn', TARGET.clusterArn,
        '--secret-arn', TARGET.secretArn,
        '--transaction-id', transactionId,
      ]);
    } catch (rollbackError) {
      console.error(`Rollback attempt also failed: ${rollbackError.message}`);
    }
  }
  throw error;
}

const smoke = rows(`
SELECT
  (SELECT count(*)::int FROM pg_catalog.pg_tables WHERE schemaname='public') AS tables,
  (SELECT count(*)::int FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.prokind='f') AS routines,
  (SELECT count(*)::int FROM pg_views WHERE schemaname='public') AS views,
  (SELECT count(*)::int FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND NOT t.tgisinternal) AS triggers,
  (SELECT count(*)::int FROM pg_indexes WHERE schemaname='public') AS indexes,
  (SELECT count(*)::int FROM pg_constraint WHERE contype='f' AND confrelid='public.marketroute_users'::regclass) AS internal_user_fks,
  (SELECT count(*)::int FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='r' AND c.relrowsecurity) AS rls_enabled,
  (SELECT count(*)::int FROM public.marketroute_users) AS users,
  (SELECT count(*)::int FROM public.organisations) AS organisations,
  (SELECT count(*)::int FROM public.companies) AS companies,
  (SELECT count(*)::int FROM public.claims) AS claims,
  (SELECT count(*)::int FROM public.opportunities) AS opportunities,
  (SELECT enabled FROM public.genesis_growth_settings WHERE singleton=true) AS genesis_growth_enabled,
  (SELECT active_market_limit FROM public.marketroute_plan_catalog WHERE plan_code='GROWTH') AS growth_limit,
  (SELECT active_market_limit FROM public.marketroute_plan_catalog WHERE plan_code='SCALE') AS scale_limit,
  (SELECT count(*)::int FROM public.marketroute_schema_releases) AS schema_release_rows
`)[0] ?? {};

const expected = { tables: 77, routines: 206, views: 5, triggers: 64, indexes: 88, internal_user_fks: 13, rls_enabled: 0, users: 0, organisations: 0, companies: 0, claims: 0, opportunities: 0, genesis_growth_enabled: false, growth_limit: 3, scale_limit: 10, schema_release_rows: 0 };
for (const [key, value] of Object.entries(expected)) {
  if (smoke[key] !== value) throw new Error(`Post-apply smoke invariant failed for ${key}: expected ${value}, got ${smoke[key]}`);
}
const v1 = rows("SELECT (to_regclass('public.marketroute_v1_migration_batches') IS NULL AND to_regclass('public.marketroute_v1_migration_id_map') IS NULL AND to_regclass('public.marketroute_v1_migration_rejections') IS NULL AND to_regclass('public.marketroute_v1_migration_audit_events') IS NULL) AS v1_absent")[0];
if (v1?.v1_absent !== true) throw new Error('V1 ETL object exists after canonical baseline application.');
const truth = rows("SELECT (SELECT policy_key FROM public.truth_claim_policy_bindings WHERE subject_type='PERSON' AND claim_key='employment.current') AS employment_policy, (SELECT policy_key FROM public.truth_claim_policy_bindings WHERE subject_type='PERSON' AND claim_key='role.current') AS role_policy, (SELECT policy_key FROM public.truth_claim_policy_bindings WHERE subject_type='CHANNEL' AND claim_key='ownership.current') AS channel_policy")[0] ?? {};
if (truth.employment_policy !== 'PERSON_CURRENT_EMPLOYMENT_V1' || truth.role_policy !== 'PERSON_CURRENT_ROLE_V1' || truth.channel_policy !== 'CHANNEL_OWNERSHIP_CURRENT_V1') throw new Error('Truth policy binding drift after canonical baseline application.');

const receipt = {
  format_version: 1,
  build: 'AWS-V0-BUILD-3',
  mode: 'manual-aurora-baseline-application-receipt',
  status: 'AURORA_CANONICAL_BASELINE_APPLIED',
  applied_at: new Date().toISOString(),
  baseline_sha256: inspection.raw_sha256,
  target: { account_id: TARGET.accountId, region: TARGET.region, cluster_arn: TARGET.clusterArn, database: TARGET.database },
  smoke,
  v1_etl_absent: true,
  truth_policy_bindings_validated: true,
};
fs.writeFileSync(receiptPath, `${JSON.stringify(receipt, null, 2)}\n`);
console.log(JSON.stringify(receipt, null, 2));
