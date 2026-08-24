# AWS V0 Build 10 — Planner / Dispatcher / Worker / Synchronizer Split

Status: SOURCE COMPLETE / ACTIVATION BLOCKED

## Purpose

Build 10 separates deterministic planning, durable dispatch, disposable semantic execution, and canonical synchronization. Planning can run with zero workers. SQS remains transport only; Aurora owns work, attempt, dispatch, idempotency, cost, and synchronization state.

## Capability correction

Build 9's Bedrock capability summarizes evidence already supplied. It does not acquire new evidence. Build 10 therefore adds the distinct `SYNTHESIZE_COMPANY_UNDERSTANDING` action and refuses to dispatch `ACQUIRE_CLAIM_EVIDENCE` through that executor.

The synthesis input must reference 1–40 canonical evidence-item UUIDs. Synchronization re-checks every referenced item against Aurora, including company subject, tenant scope, exact excerpt, observation time, and source type. A customer-private evidence item can never be reused by another organisation.

## Durable split

- `ResearchPlanningAutomationService` has no provider or worker dependency.
- `AwsV0ResearchDispatcher` prepares an Aurora-owned envelope before publishing and records the SQS message afterward. A send/record crash may duplicate transport delivery, which the execution ledger handles idempotently.
- The Build 9 Lambda remains disposable and bounded to one semantic capability.
- `marketroute_sync_aws_v0_research_execution_v1` stores a non-authority semantic artifact, commits measured normal-cost economics through the existing canonical research budget function, completes the canonical job, and only then permits queue acknowledgment.
- Terminal execution failure is acknowledged only after `marketroute_sync_aws_v0_research_failure_v1` conservatively settles the canonical attempt and marks the job failed.
- A duplicate delivery re-runs synchronization without re-running Bedrock or double-settling the budget.

Dispatched ownership lasts 130 minutes, covering five 24-minute visibility windows plus margin. Canonical abandoned-work recovery skips only a sent, unexpired dispatch; expired ownership returns to the existing conservative recovery path.

## Authority boundary

The semantic artifact grants no Truth, confidence, score, ranking, viability, R4/R5/R6 authority, or execution permission. Truth Index and the existing deterministic authority writers remain unchanged.

## Activation gate

The SQS event source mapping remains disabled. Activation requires both:

1. a deterministic planner producer that emits the new synthesis action from canonical evidence; and
2. a successful live Bedrock quota/economic/replay proof.

Automatic GitHub deployment remains database-stack-only. No research stack is silently deployed or activated by this build.
