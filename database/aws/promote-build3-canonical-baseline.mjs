#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import {
  DATA_API_SQL_MAX_BYTES,
  EXPECTED_BASELINE_BYTES,
  EXPECTED_BASELINE_SHA256,
  EXPECTED_CANONICAL_MUTATIONS,
  EXPECTED_MAX_STATEMENT_BYTES,
  EXPECTED_STATEMENT_COUNT,
  inspectBaseline,
  readJson,
  sha256,
} from './build3-canonical-baseline-lib.mjs';

const repoRoot = process.cwd();
const sourceDir = path.resolve(process.env.MARKETROUTE_PROMOTION_SOURCE_DIR ?? 'database/aws/build3_promotion_source');
const candidatePath = path.join(sourceDir, '0001_marketroute_aws_canonical_baseline_candidate.sql');
const transformManifestPath = path.join(sourceDir, 'build3_aws_final_transform_manifest.json');
const validatedManifestPath = path.join(sourceDir, 'build3_aws_transformed_schema_manifest.json');
const transformedSchemaPath = path.join(sourceDir, 'build3_aws_transformed_reference_schema.sql');
const outputDir = path.resolve(repoRoot, process.env.MARKETROUTE_AWS_DATABASE_DIR ?? 'database/aws');
const baselinePath = path.join(outputDir, '0001_marketroute_aws_canonical_baseline.sql');
const manifestPath = path.join(outputDir, '0001_marketroute_aws_canonical_baseline_manifest.json');

const SOURCE = Object.freeze({
  commit_sha: '6b73e0e85c5f968a60e8090a5ab066d033324f53',
  workflow_run_id: 32321349965,
  artifact_id: 9389866413,
  artifact_name: 'aws-v0-build3-final-transform',
  artifact_zip_sha256: '43d921780aa9db505733470c3f77d52269a824189f89ed8406f909e94c5b723c',
  candidate_sha256: EXPECTED_BASELINE_SHA256,
  transform_manifest_sha256: 'd45aeb67ab062ec99f232ad30acf32cd1c36c371daad2d8bdaabfbba0871d21f',
  validated_manifest_sha256: 'a358b3e18e0b27b73b276ad382745affca5fdb42282a7a93401d0d1c4dc4e1f1',
  transformed_schema_sha256: '651e9594d607b19f163f89c205a91ab8188e6e48265764c62befb250aee15d48',
});

for (const required of [candidatePath, transformManifestPath, validatedManifestPath, transformedSchemaPath]) {
  if (!fs.existsSync(required)) throw new Error(`Promotion source artifact is incomplete: ${required}`);
}
if (fs.existsSync(baselinePath) || fs.existsSync(manifestPath)) {
  throw new Error('Canonical baseline promotion is immutable: output already exists.');
}

const candidate = fs.readFileSync(candidatePath, 'utf8');
const transformManifestRaw = fs.readFileSync(transformManifestPath, 'utf8');
const validatedManifestRaw = fs.readFileSync(validatedManifestPath, 'utf8');
const transformedSchemaRaw = fs.readFileSync(transformedSchemaPath, 'utf8');
const transformManifest = JSON.parse(transformManifestRaw);
const validatedManifest = JSON.parse(validatedManifestRaw);
const inspection = inspectBaseline(candidate);

const exactHashes = {
  candidate: sha256(candidate),
  transform_manifest: sha256(transformManifestRaw),
  validated_manifest: sha256(validatedManifestRaw),
  transformed_schema: sha256(transformedSchemaRaw),
};
if (exactHashes.candidate !== SOURCE.candidate_sha256) throw new Error(`Certified candidate hash drifted: ${exactHashes.candidate}`);
if (exactHashes.transform_manifest !== SOURCE.transform_manifest_sha256) throw new Error('Certified transform manifest hash drifted.');
if (exactHashes.validated_manifest !== SOURCE.validated_manifest_sha256) throw new Error('Certified validation manifest hash drifted.');
if (exactHashes.transformed_schema !== SOURCE.transformed_schema_sha256) throw new Error('Certified transformed schema hash drifted.');

if (transformManifest.build !== 'AWS-V0-BUILD-3' || transformManifest.mode !== 'aws-final-transformation') throw new Error('Unexpected transform manifest.');
if (transformManifest.status !== 'READY_FOR_SECOND_EPHEMERAL_POSTGRES_VALIDATION') throw new Error('Transform manifest is not promotion-ready.');
if (transformManifest.output?.sha256 !== SOURCE.candidate_sha256 || transformManifest.output?.bytes !== EXPECTED_BASELINE_BYTES) throw new Error('Transform output identity drifted.');
if (transformManifest.source?.source_transform_decisions !== 35) throw new Error('Expected 35 source transform decisions.');
if (transformManifest.aurora_execution_allowed !== false || transformManifest.baseline_emission_allowed !== false) throw new Error('Source candidate safety boundary drifted.');

if (validatedManifest.build !== 'AWS-V0-BUILD-3' || validatedManifest.mode !== 'aws-transformed-schema-validation') throw new Error('Unexpected transformed-schema manifest.');
if (validatedManifest.status !== 'AWS_FINAL_OBJECTS_TRANSFORMED' || validatedManifest.blocker_count !== 0) throw new Error('Certified transformed schema is not blocker-free.');
if (validatedManifest.canonical_baseline_candidate_validated_in_postgresql16 !== true) throw new Error('PostgreSQL 16 validation proof missing.');
if (validatedManifest.source_transform_manifest_sha256 !== SOURCE.transform_manifest_sha256) throw new Error('Validation manifest does not bind to certified transform manifest.');
if (validatedManifest.object_counts?.tables !== 77 || validatedManifest.object_counts?.routines !== 206 || validatedManifest.object_counts?.views !== 5 || validatedManifest.object_counts?.triggers !== 64 || validatedManifest.object_counts?.indexes !== 88) {
  throw new Error('Certified AWS object counts drifted.');
}
if (validatedManifest.identity?.internal_user_fk_count !== 13 || validatedManifest.identity?.explicit_actor_function_count !== 13) throw new Error('Certified AWS identity boundary drifted.');

if (inspection.raw_bytes !== EXPECTED_BASELINE_BYTES) throw new Error(`Candidate byte size drifted: ${inspection.raw_bytes}`);
if (inspection.statement_count !== EXPECTED_STATEMENT_COUNT) throw new Error(`Expected ${EXPECTED_STATEMENT_COUNT} Data API statements, got ${inspection.statement_count}.`);
if (inspection.max_statement_bytes !== EXPECTED_MAX_STATEMENT_BYTES) throw new Error(`Expected max SQL statement size ${EXPECTED_MAX_STATEMENT_BYTES}, got ${inspection.max_statement_bytes}.`);
if (inspection.max_statement_bytes > DATA_API_SQL_MAX_BYTES) throw new Error('Candidate contains a statement larger than the Data API SQL limit.');
if (inspection.mutation_count !== EXPECTED_CANONICAL_MUTATIONS) throw new Error(`Expected ${EXPECTED_CANONICAL_MUTATIONS} reviewed canonical mutations, got ${inspection.mutation_count}.`);
if (inspection.meta_commands.length !== 2 || !inspection.meta_commands.some((x) => /^\\restrict\b/.test(x)) || !inspection.meta_commands.some((x) => /^\\unrestrict\b/.test(x))) {
  throw new Error('Expected exactly the pg_dump restrict/unrestrict meta-command pair.');
}

fs.mkdirSync(outputDir, { recursive: true });
fs.copyFileSync(candidatePath, baselinePath);
if (sha256(fs.readFileSync(baselinePath)) !== SOURCE.candidate_sha256) throw new Error('Canonical baseline byte-copy verification failed.');

const promotionManifest = {
  format_version: 1,
  build: 'AWS-V0-BUILD-3',
  mode: 'canonical-baseline-promotion',
  status: 'CANONICAL_BASELINE_PROMOTED_PENDING_MANUAL_AURORA_APPLICATION',
  doctrine: ['Fresh data', 'Final logic', 'Clean provenance'],
  source_certification: SOURCE,
  canonical_baseline: {
    path: path.relative(repoRoot, baselinePath),
    sha256: SOURCE.candidate_sha256,
    bytes: EXPECTED_BASELINE_BYTES,
    immutable: true,
    byte_for_byte_certified_candidate: true,
    top_level_statement_count: inspection.statement_count,
    reviewed_top_level_data_mutation_count: inspection.mutation_count,
    pg_dump_meta_commands_removed_by_data_api_executor: inspection.meta_commands.length,
  },
  postgresql16_validation: {
    blocker_count: 0,
    object_counts: validatedManifest.object_counts,
    internal_user_fk_count: 13,
    explicit_actor_function_count: 13,
  },
  data_api_application_contract: {
    execute_statement_sql_max_bytes: DATA_API_SQL_MAX_BYTES,
    canonical_statement_count: inspection.statement_count,
    canonical_max_statement_bytes: inspection.max_statement_bytes,
    transaction_required: true,
    multi_statement_requests_allowed: false,
    target_account_id: '801132668416',
    target_region: 'eu-west-2',
    target_cluster_arn: 'arn:aws:rds:eu-west-2:801132668416:cluster:marketroute-aws-v0',
    target_secret_arn: 'arn:aws:secretsmanager:eu-west-2:801132668416:secret:marketroute/aws-v0/database/admin-pXxyUD',
    target_database: 'marketroute',
    requires_empty_public_schema: true,
    confirmation_phrase: 'APPLY_AWS_V0_BUILD3_BASELINE',
  },
  safety: {
    prohibited_historical_data_import: true,
    automatic_aurora_execution_allowed: false,
    manual_aurora_application_gate_ready: true,
    github_oidc_data_api_access_required: false,
    cloud_shell_manual_execution_only: true,
    rollback_on_statement_failure: true,
    production_domain_cutover_allowed: false,
  },
};

fs.writeFileSync(manifestPath, `${JSON.stringify(promotionManifest, null, 2)}\n`);
console.log(JSON.stringify({
  build: promotionManifest.build,
  mode: promotionManifest.mode,
  status: promotionManifest.status,
  baseline: promotionManifest.canonical_baseline.path,
  sha256: promotionManifest.canonical_baseline.sha256,
  bytes: promotionManifest.canonical_baseline.bytes,
  statements: promotionManifest.data_api_application_contract.canonical_statement_count,
  max_statement_bytes: promotionManifest.data_api_application_contract.canonical_max_statement_bytes,
  postgresql16_blockers: promotionManifest.postgresql16_validation.blocker_count,
  automatic_aurora_execution_allowed: false,
  manual_aurora_application_gate_ready: true,
}, null, 2));
