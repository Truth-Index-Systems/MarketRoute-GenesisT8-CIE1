# AWS V0 Build 11 — Research Execution Repair and Proof

Status: IN PROGRESS / REPLAY, IAM AND ADMISSION IMPLEMENTED / LIVE ACTIVATION BLOCKED

Base: `aws-v0` at `1f65cc8c478fc487e92de401107d4dd1965a0b81`.
Implementation branch: `aws-v0-build11-staging`. Draft PR: #11.

Build 11 remains a draft. Source changes and offline tests are not permission to merge, deploy or activate production research.

## Implemented

1. Forward migration `database/aws/0005_marketroute_aws_build11_terminal_replay.sql` repairs terminal redelivery in `marketroute_claim_aws_v0_research_execution_v2`. Exact persisted envelope, tenant, work identity, canonical attempt and capability checks precede receipt reuse. A synchronized success must have a matching result artifact and completed canonical job. A settled terminal failure must match its failed canonical job. Only unfinished execution still requires live dispatch ownership. Missing contract fields and ownership deadlines fail closed.
2. The worker's foundation-model IAM condition uses the documented service key `bedrock:InferenceProfileArn`. Exact application-profile and Sonnet model resource scopes remain unchanged. Both source and synthesized-template validators check the correction; the synth validator explicitly rejects the old global-key spelling.
3. A credential-free PR workflow restores the actual AWS baseline and migrations 0002–0004 into disposable PostgreSQL 16. It first reproduces Build 10's terminal replay rejection, then applies 0005 and runs the repaired behavior tests.
4. The actual Node Lambda executor and entry handler are exercised against PostgreSQL claim/synchronization routines. A provider sentinel fails the test if any repeated completed delivery invokes inference.

## Original replay tranche: test coverage and limits

`tests/integration/aws-v0-build11-db.py` contains 14 assertion groups: settled success/failure replay without additional budget settlement; cross-tenant and altered payload rejection; wrong fingerprint rejection; simultaneous claims; active execution lease; persisted result awaiting synchronization; expired/null dispatch deadline; unconfirmed send; canonical-attempt mismatch; missing result artifact; already-settled expired deadline; and denied PUBLIC routine execution.

`tests/integration/aws-v0-build11-runtime.mjs` contains five assertion groups: actual executor success/failure replay; Lambda partial-batch acknowledgment behavior; tampered/malformed rejection; and unchanged provider-call, attempt, budget and artifact counts.

The fixture inserts synthetic canonical-shaped state with database constraints enabled. It does not use the unfinished production planner. It does not validate evidence acquisition or the first successful full synchronization from freshly acquired evidence. The Node proof uses a test PostgreSQL adapter in place of the AWS Data API network adapter. No Bedrock response is generated, no cloud resources are provisioned, and passing these tests is not a live IAM or SQS certification.

Run both commands in order against the same disposable service using `BUILD11_POSTGRES_CONTAINER`. The PR workflow provides that service; neither harness accepts a production connection URL.

## Frozen boundaries

No Truth Index, CIE, UDOSIB, R4/R5/R6 authority or ranking logic is changed. Migrations 0001–0004 are not rewritten. No broad IAM policy, model switch, new production endpoint or fallback provider is introduced. The SQS event source mapping remains disabled. The automatic infrastructure deployment workflow remains unchanged and database-stack-only on its existing guarded production branch. Build 11 must not be merged or activated on the strength of replay checks alone.

## Documentation references

- AWS geographic cross-region profile conditions: https://docs.aws.amazon.com/bedrock/latest/userguide/geographic-cross-region-inference.html
- Lambda/SQS duplicate-delivery behavior: https://docs.aws.amazon.com/lambda/latest/dg/with-sqs.html
- Node.js Lambda deployment dependencies: https://docs.aws.amazon.com/lambda/latest/dg/nodejs-package.html

## Admission tranche — implementation and verification scope

The production entry now uses `admitted-executor.mjs`. The original executor module
remains the source of the frozen semantic parser and execution-ledger adapter; its
unguarded orchestration is retained only for historical tests, not the Lambda entry.

`0006_marketroute_aws_build11_inference_admission.sql` adds a disabled-by-default
model/account/source-Region/EU-route admission scope and durable per-provider-attempt
sub-reservations. It does not allocate extra customer credit or create a second
canonical budget ledger. An outstanding canonical reservation and active policy
are prerequisites. Outstanding prior-day reservations remain counted. Requests
compete on database locks; a model scope is shared across organisations and workers,
not keyed by customer or application-profile identifier. The scope allowlists the
existing application profile and preserves the current accounting tariff; verify
that tariff and profile configuration before any live enabling change.

Each request first rechecks canonical evidence scope/content and active campaign.
It then counts the exact native request bytes, reserves input cost plus the full
1,400-token output cap, and obtains a short-lived permit. The gated provider uses
native **CountTokens + InvokeModel** rather than the old Converse transport, so the
structured request body can be byte-identical for counting and inference. The JSON
schema, system instruction and evidence prompt are covered by byte-parity tests.
The new read-only `bedrock:CountTokens` grant is restricted to the same model in
London. No extra InvokeModel or cross-region permissions are added.

Permits are spaced at least 11 seconds apart and must be used within one second;
an elapsed-time check prevents delayed permit reuse. This limits admission grants,
not traffic from administrator shells or other integrations that bypass this
runtime. Only one use of each in-memory prepared request is allowed. Ambiguous
admission responses never authorise another provider invocation.

Denials release the execution claim without consuming a provider attempt or
settling a failed canonical job. They do not erase the existing canonical budget
reservation. Earlier executions without cost receipts block further admission until reconciled.
Failure synchronization follows execution/dispatch/job lock ordering. Every admitted
attempt retains either measured usage, an unknown-cost
reservation, or a trusted NOT_SENT record. Repeated settlements cannot double
charge; conflicting receipts are rejected. Measured overruns are recorded and halt
new admissions instead of discarding usage. Successful canonical completion uses
the accumulated attempt costs. The failure synchronizer uses those same receipts;
historical failures without receipts retain their previous conservative treatment.

Offline verification includes native request-byte parity, denied-inference
sentinels, real PostgreSQL concurrent admissions, reservations across retries,
unknown costs, evidence rejection, paused campaigns, privilege rejection, and
actual-handler first execution/synchronization with synthetic evidence and a fake
Bedrock network. This is not live token-counter, billing, Data API or worker-role
certification. Proof results must be attached to the exact tested commit.

Remaining release gates: package pinned SDK dependencies in the deployable asset;
prove CountTokens/structured InvokeModel and accounting against live Bedrock under
the restricted worker role; verify tariff/model/profile configuration; finish
crash-window and canonical-retry recovery tests and review deployment receipts.
SQS still has its historical visibility timeout and receive ceiling: admission
deferral does not consume a provider attempt but **does** consume a transport
receive. Retry timing/DLQ recovery must be proved before queue activation.

No production model-scope enabling, Aurora migration, deployment or queue activation
is performed by this tranche or its credential-free CI workflow.
