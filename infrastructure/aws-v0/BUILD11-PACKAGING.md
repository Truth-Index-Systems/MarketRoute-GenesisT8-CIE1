# Build 11 — Reproducible research-worker package

Status: IMPLEMENTED / CI PROOF REQUIRED / LIVE ACTIVATION BLOCKED.

This slice packages the existing admitted worker. It does not change its semantic
prompt, schema, model, ranking, canonical database routines or activation switches.

## Package contract

- Runtime: Node.js 22; Lambda target ARM64; handler `index.handler`.
- Runtime-local package/lock with the existing reviewed SDK versions:
  `@aws-sdk/client-bedrock-runtime` 3.1111.0 and `@aws-sdk/client-rds-data` 3.1114.0.
  The transitive lock entries preserve the root lock's versions and integrity
  hashes. No attempt is made to upgrade to a newer SDK in this slice.
- An explicit runtime-file allowlist and clean temporary `npm ci --omit=dev
  --ignore-scripts --no-bin-links` installation prevent unrelated application
  modules, local environment files and root node_modules from entering the ZIP.
- Archive paths, native/binary modules, symlinks, dependency versions and archive
  size are checked. ZIP entries are sorted, timestamp-fixed, stored without
  compression and use 0644 file permissions. Dependency licences are retained.
- The external manifest binds all archive entries, runtime inputs, package lock
  and packaging script to SHA-256 hashes. It is an integrity/build receipt, not a
  cryptographic signature or a security audit of third-party dependencies.
- CDK uses the ZIP directly and checks its source/lock freshness before synthesis.
  The template exposes its package SHA-256. A synth test verifies that CDK's asset
  has identical bytes. There is no fallback to source-only packaging.

## Commands (no deployment)

From `infrastructure/aws-v0`:

```sh
npm run package:research
npm run verify:research-package
npm run synth
npm run validate:synth
```

`npm run build` now prepares the package before compiling infrastructure. This
also applies to existing deploy scripts, but no deploy script is invoked by the
package proof. A package build requires Node 22, npm, Python 3 and npm registry
access. Verification requires no registry or AWS access.

## Proof boundary

The credential-free Build 11 workflow builds the ZIP twice from separate clean
installations and compares ZIP and manifest hashes. It extracts the ZIP outside
the repository and runs its actual handler and default SDK adapters. The pinned
SDK middleware, signing, HTTP serialization and response deserialization execute;
only the final HTTP handler is replaced. Network connection attempts are blocked.
The PostgreSQL integration uses the actual serialized Data API SQL/parameters,
not an injected production ledger, and synthetic Bedrock responses. It covers
first success, invalid output with measured cost, replay, denied budget and absent
evidence. The retained ZIP is also exercised on a native ARM64 Linux runner.

These proofs are not live AWS endpoint, restricted-worker IAM, SQS, Amazon Linux
runtime, model output quality, tariff or production planner certification. A
successful package proof must identify its tested commit and archive digest.

## Remaining Build 11 gates

Controlled CountTokens and structured InvokeModel under the restricted worker
role; live model/profile/tariff verification; unresolved crash-window and canonical
retry recovery; admission-deferral/SQS receive-limit handling; reviewed Aurora
migration and AWS deployment receipts. The PR stays draft. SQS consumption and
the model admission scope remain disabled. No infrastructure is deployed here.

## Primary references

- https://docs.aws.amazon.com/lambda/latest/dg/nodejs-package.html
- https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_CountTokens.html
- https://docs.aws.amazon.com/bedrock/latest/userguide/structured-output.html
- https://docs.github.com/en/actions/reference/runners/github-hosted-runners
