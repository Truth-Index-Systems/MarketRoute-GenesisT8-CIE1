# AWS V0 Build 11 — Research Execution Repair and Proof

Status: IN PROGRESS / FIRST REPLAY-AND-IAM REPAIR IMPLEMENTED / LIVE ACTIVATION BLOCKED

Base: `aws-v0` at `1f65cc8c478fc487e92de401107d4dd1965a0b81`.
Implementation branch: `aws-v0-build11-staging`. Draft PR: #11.

This is the first bounded implementation slice of the Build 11 scope, not a declaration that the complete build or the product is ready.

## Implemented

1. Forward migration `database/aws/0005_marketroute_aws_build11_terminal_replay.sql` repairs terminal redelivery in `marketroute_claim_aws_v0_research_execution_v2`. Exact persisted envelope, tenant, work identity, canonical attempt and capability checks precede receipt reuse. A synchronized success must have a matching result artifact and completed canonical job. A settled terminal failure must match its failed canonical job. Only unfinished execution still requires live dispatch ownership. Missing contract fields and ownership deadlines fail closed.
2. The worker's foundation-model IAM condition uses the documented service key `bedrock:InferenceProfileArn`. Exact application-profile and Sonnet model resource scopes remain unchanged. Both source and synthesized-template validators check the correction; the synth validator explicitly rejects the old global-key spelling.
3. A credential-free PR workflow restores the actual AWS baseline and migrations 0002–0004 into disposable PostgreSQL 16. It first reproduces Build 10's terminal replay rejection, then applies 0005 and runs the repaired behavior tests.
4. The actual Node Lambda executor and entry handler are exercised against PostgreSQL claim/synchronization routines. A provider sentinel fails the test if any repeated completed delivery invokes inference.

## Test coverage and limits

`tests/integration/aws-v0-build11-db.py` contains 14 assertion groups: settled success/failure replay without additional budget settlement; cross-tenant and altered payload rejection; wrong fingerprint rejection; simultaneous claims; active execution lease; persisted result awaiting synchronization; expired/null dispatch deadline; unconfirmed send; canonical-attempt mismatch; missing result artifact; already-settled expired deadline; and denied PUBLIC routine execution.

`tests/integration/aws-v0-build11-runtime.mjs` contains five assertion groups: actual executor success/failure replay; Lambda partial-batch acknowledgment behavior; tampered/malformed rejection; and unchanged provider-call, attempt, budget and artifact counts.

The fixture inserts synthetic canonical-shaped state with database constraints enabled. It does not use the unfinished production planner. It does not validate evidence acquisition or the first successful full synchronization from freshly acquired evidence. The Node proof uses a test PostgreSQL adapter in place of the AWS Data API network adapter. No Bedrock response is generated, no cloud resources are provisioned, and passing these tests is not a live IAM or SQS certification.

Run both commands in order against the same disposable service using `BUILD11_POSTGRES_CONTAINER`. The PR workflow provides that service; neither harness accepts a production connection URL.

## Work still required before closing Build 11

- Database-backed pre-invocation budget admission and per-provider-attempt reservation/settlement, including measured usage on rejected responses and conservative treatment of unknown usage.
- Shared model/account/Region request admission for the observed 10 RPM quota; proposed operating budget is six starts/minute across relevant workers, including retries. Concurrency alone is not this limiter.
- Additional fault injection for ambiguous send/record outcomes, provider completion before receipt persistence, synchronization failure, ownership expiration and canonical retry transitions. The current stale-attempt test proves rejection, not automatic recovery.
- Package pinned compatible AWS SDK dependencies in the exact Lambda asset, verify its structured `Converse` request and produce a reproducible artifact manifest.
- Pre-inference canonical evidence scope/content validation and the remaining execution safety review.
- Controlled live proof through the restricted worker role, capturing structured response validation, usage, cost and request metadata, plus reviewed AWS migration/deployment receipts.

## Frozen boundaries

No Truth Index, CIE, UDOSIB, R4/R5/R6 authority or ranking logic is changed. Migrations 0001–0004 are not rewritten. No broad IAM policy, model switch, new production endpoint or fallback provider is introduced. The SQS event source mapping remains disabled. The automatic infrastructure deployment workflow remains unchanged and database-stack-only on its existing guarded production branch. Build 11 must not be merged or activated on the strength of replay checks alone.

## Documentation references

- AWS geographic cross-region profile conditions: https://docs.aws.amazon.com/bedrock/latest/userguide/geographic-cross-region-inference.html
- Lambda/SQS duplicate-delivery behavior: https://docs.aws.amazon.com/lambda/latest/dg/with-sqs.html
- Node.js Lambda deployment dependencies: https://docs.aws.amazon.com/lambda/latest/dg/nodejs-package.html
