# Build 11: zero-budget worker/database canary

This operator creates **retained, explicitly synthetic records in the live database** and synchronously invokes the existing numeric Lambda version 1 once. It does not run migrations, change schema/IAM, change model or recovery switches, send/receive SQS, or make a model call. Default invocation prints help and makes no AWS calls.

## Purpose

Prove the deployed worker can load its Data API dependency, claim a properly shaped work record and persist the deferred execution state. The prior invalid-input test returns before any database call. This canary fills that gap; it is not a lead-generation or paid-inference pass.

The campaign is PAUSED before its work becomes visible. Its budget policy is disabled with all money and capacity ceilings zero. There is no monetary reservation. The company's lifecycle is ARCHIVED, its name begins `[SYNTHETIC]`, the source is INTERNAL, and its evidence text explicitly says it is fictional. There is no Cognito identity, email, real domain or user-provided business information.

The canonical-shaped job/plan/dispatch are test fixtures, not a claim that the planner produced them. A simulated SENT dispatch is necessary for the worker contract; its message ID begins `SIMULATED-DIRECT-INVOKE`. The direct invocation omits SQS receive-count fields and does not claim actual queue delivery.

The live pass requires a new database execution row (absent before invocation), the expected work/envelope fingerprint, FAILED_RETRYABLE state with ADMISSION_DEFERRED, refunded execution attempt count zero, no inference receipts, no semantic artifacts, no nonzero budget events, and the expected version-1 handler response. This proves the claim/defer database path. It does **not independently prove the preflight return reason**: the worker can also defer after some errors. The isolated integration test observes CAMPAIGN_NOT_ACTIVE directly; the live API does not expose that internal trace.

After the verified result, the existing canonical failure and scheduler-completion functions close the synthetic job/run, retaining a zero-valued RELEASE and the original execution evidence. A RESOLVED test recovery record prevents future recovery polling of that simulated dispatch. No rows are deleted and no append-only protections are disabled.

## Operation

Verify SHA256SUMS, then run `python3 canary.py --run-zero-budget` only when the operator explicitly accepts these synthetic database writes and the Lambda invocation. Normal Lambda, Aurora and logging charges may apply; the zero budget concerns model inference, not AWS infrastructure costs.

An exclusive local marker is written before starting. The fixture identifiers and an append/flushed journal are saved before commit/invoke requests. The operator prints progress at major stages. A repeat run is rejected; do not remove its marker, refresh IDs or invoke a second time to force a pass.

On failure or lost response, preserve its folder. `python3 canary.py --inspect-existing <saved-folder>` verifies AWS version/target and reads that fixture's state; it does not invoke, modify or repair it. An uncertain commit is never automatically replayed. A disconnected run can leave the synthetic job open; its paused campaign and disabled zero budget still prevent paid research, but explicit reviewed closure may be required before other research begins. Do not resume generic migration inspection: its original rollout expected no worker.

## Evidence limits

CI uses real native PostgreSQL 16 in a newly owned network-disabled Docker container, the actual operator request validator and actual source Lambda handler. AWS metadata/CLI responses and the Lambda transport are simulated; handler database methods are injected native-PostgreSQL adapters. This is not live worker IAM, AWS SDK network, PostgreSQL least-privilege, structured Bedrock, cost settlement, queue, planner or complete product certification. The user-run result supplies the live claim/defer evidence. No function package changes are included.

## Invocation command correction

Lambda `invoke` has a streaming output file and does not support
`--cli-input-json`. The operator now passes the already validated function,
qualifier, invocation type and log type as explicit flags, and writes the exact
event bytes to a private temporary file used through `--payload fileb://...`.
All other API calls retain their closed JSON argument validation. No SQL,
fixture identifier, worker version, control setting or retry policy changed.
The actual AWS CLI is exercised against an unsigned loopback-only HTTP test
server; this tests CLI parsing/serialization, not AWS permission or live Lambda.

An older attempt can have committed the fixture before CLI parameter validation
stopped invocation. Preserve that folder, marker, fixture and original summary.
Do NOT rerun `--run-zero-budget`, delete the marker, or construct a new fixture.
`--inspect-existing <original-folder>` still reads the existing database state
without invoking, seeding, closing work or altering model/recovery controls.
The original dispatch ownership expires; this patch does not renew it, provide
an automatic resume operation or authorize re-invocation of an interrupted run.
