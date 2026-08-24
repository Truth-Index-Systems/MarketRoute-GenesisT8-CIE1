# AWS V0 Build 9 — Bounded Idempotent Research Worker

Status: SOURCE COMPLETE / LIVE BEDROCK PROOF PENDING AWS QUOTA

## Purpose

Build 9 turns the Build 8 Lambda shell into the first real AWS research executor while preserving the frozen transport and all Truth Index / Genesis / CIE / UDOSIB authority boundaries.

The worker performs one named semantic capability: evidence-grounded company understanding. It accepts only canonical Build 8 envelopes whose persisted work-unit metadata explicitly selects contract `MR-AWS-V0-COMPANY-UNDERSTANDING-1.0.0` and operation `ai.companyUnderstanding`.

## Durable claim and idempotency

Migration `database/aws/0003_marketroute_aws_build9_research_execution.sql` adds an Aurora-owned execution ledger and three fixed stored functions:

- `marketroute_claim_aws_v0_research_execution_v1`
- `marketroute_complete_aws_v0_research_execution_v1`
- `marketroute_fail_aws_v0_research_execution_v1`

The claim routine compares the full queue envelope with the canonical `research_work_units` row, locks execution by the existing 64-character dedupe key, fingerprints the envelope, enforces a 210-second lease, and caps execution at three attempts. A successful receipt is replay-safe and suppresses a second provider call. Payload or fingerprint collisions fail closed.

Aurora remains authoritative. No DynamoDB shadow state is introduced.

## First executor

The worker invokes the existing EU Claude Sonnet 4.5 application inference profile through non-streaming Bedrock `Converse` structured output. It preserves the Build 7.7 controls:

- evidence is untrusted content, never instructions;
- evidence identifiers are bounded, unique and output-allow-listed;
- every semantic statement must cite supplied evidence;
- structured output is closed and locally revalidated;
- AI cannot score, rank, adjudicate Truth, grant execution, or perform deterministic commercial mathematics;
- no browser or public HTTP surface is added.

Provider retries are owned by the queue/ledger boundary. The AWS SDK is configured for one attempt, each provider call has a 120-second timeout, and the durable execution ceiling is three attempts.

## Economic guard

Every successful invocation records token usage and normal-cost economics using the frozen Sonnet 4.5 EU pricing basis:

- input: `$3.30` per million tokens;
- output: `$16.50` per million tokens.

AWS credits never erase economic cost. A measured equivalent cost above the canonical work-unit ceiling fails terminally.

## IAM boundary

The worker receives only:

- Build 8 SQS consumer and dedicated log permissions;
- `rds-data:ExecuteStatement` for the exact AWS V0 Aurora cluster;
- secret read for the exact Aurora secret parameter;
- non-streaming `bedrock:InvokeModel` for the exact application profile and fixed EU Sonnet 4.5 destination model ARNs.

It does not receive generic SQL, transactions, SQS publishing, DynamoDB, marketplace, IAM role passing, streaming Bedrock, public route, or browser credentials.

## Activation boundary

The Lambda executor latch is enabled in its private environment, but the SQS event source mapping remains disabled. Build 9 therefore proves the worker without allowing a semantic receipt to be mistaken for canonical research completion.

Build 10 adds the planner/dispatcher/worker/sync integration, canonical budget settlement, and replay-safe result synchronization. The event source mapping still may not be enabled until the distinct synthesis action has a live deterministic planner producer and the AWS quota/economic proof passes.
