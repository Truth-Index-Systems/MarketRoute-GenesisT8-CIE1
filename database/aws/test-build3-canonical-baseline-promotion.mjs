#!/usr/bin/env node
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { EXPECTED_BASELINE_SHA256 } from './build3-canonical-baseline-lib.mjs';

const repoRoot = process.cwd();
const baseline = path.join(repoRoot, 'database/aws/0001_marketroute_aws_canonical_baseline.sql');
const manifest = path.join(repoRoot, 'database/aws/0001_marketroute_aws_canonical_baseline_manifest.json');
if (!fs.existsSync(baseline) || !fs.existsSync(manifest)) throw new Error('Promoted baseline must exist before promotion regression runs.');

function runVerifier(extraEnv = {}) {
  return spawnSync(process.execPath, ['database/aws/verify-build3-canonical-baseline-promotion.mjs'], {
    cwd: repoRoot,
    encoding: 'utf8',
    env: { ...process.env, ...extraEnv },
  });
}
const pass = runVerifier();
if (pass.status !== 0) throw new Error(`Real promoted baseline verifier failed: ${pass.stderr || pass.stdout}`);
const result = JSON.parse(pass.stdout);
if (result.status !== 'PASS' || result.sha256 !== EXPECTED_BASELINE_SHA256 || result.statements !== 792 || result.max_statement_bytes !== 19130) throw new Error('Real promotion verifier output drifted.');

const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'marketroute-build3-promotion-'));
const tampered = path.join(temp, 'baseline.sql');
fs.copyFileSync(baseline, tampered);
fs.appendFileSync(tampered, '\n-- intentional integrity drift\n');
const fail = runVerifier({ MARKETROUTE_CANONICAL_BASELINE_PATH: tampered });
if (fail.status === 0) throw new Error('Promotion verifier did not fail closed on baseline byte drift.');

const plan = spawnSync(process.execPath, ['database/aws/apply-build3-canonical-baseline-data-api.mjs', '--json'], {
  cwd: repoRoot,
  encoding: 'utf8',
});
if (plan.status !== 0) throw new Error(`Data API apply plan failed: ${plan.stderr || plan.stdout}`);
const planJson = JSON.parse(plan.stdout);
if (planJson.data_api_statements !== 792 || planJson.max_statement_bytes !== 19130 || planJson.apply_requested !== false) throw new Error('Data API plan drifted.');

console.log(JSON.stringify({
  build: 'AWS-V0-BUILD-3',
  test: 'canonical-baseline-promotion',
  status: 'PASS',
  baseline_sha256: result.sha256,
  statements: result.statements,
  max_statement_bytes: result.max_statement_bytes,
  reviewed_canonical_mutations: result.reviewed_canonical_mutations,
  fail_closed_byte_drift: true,
  data_api_plan_safe: true,
}, null, 2));
