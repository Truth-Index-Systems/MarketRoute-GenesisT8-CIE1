# AWS V0 Build 8 — Research Transport / Worker Substrate

Status: source-complete pending CI certification and explicit AWS deployment.

## Purpose

Build 8 turns the reserved `MrAwsV0ResearchStack` boundary into a bounded asynchronous research transport without granting research execution authority yet.

## Runtime shape

- Standard SQS source queue: `marketroute-aws-v0-research-work`
- Dedicated DLQ: `marketroute-aws-v0-research-dlq`
- Node.js 22 arm64 Lambda: `marketroute-aws-v0-research-worker`
- Source queue encryption: SQS-managed SSE
- TLS-only queue policies
- Source retention: 4 days
- DLQ retention: 14 days
- Worker timeout: 240 seconds
- Source visibility timeout: 1,440 seconds (6x worker timeout)
- Redrive after 5 receives
- Batch size: 1
- Event-source maximum concurrency: 2
- Partial batch responses enabled
- Event source mapping disabled in Build 8

The six-times visibility timeout and `maxReceiveCount >= 5` follow current AWS Lambda/SQS guidance. Batch size one plus maximum concurrency two preserves the existing heavy-research concurrency discipline while later builds install durable idempotency and provider execution.

## Fail-closed execution boundary

Build 8 deliberately does **not** execute research providers and does not acknowledge valid research work. The Lambda runtime validates transport framing and returns the message as failed. The SQS event source mapping is also synthesized with `Enabled: false`.

This means an accidental queue message cannot be silently deleted before Build 9 installs the durable execution/idempotency boundary.

## Authority boundaries

The Build 8 worker has no permissions for:

- Bedrock
- RDS Data API
- Secrets Manager
- SSM
- DynamoDB
- Marketplace
- IAM role passing
- SQS publishing

Its IAM authority is limited to the source queue consumer actions and its dedicated CloudWatch Logs group. No Function URL, API Gateway, public route, producer grant, canonical persistence path, AI provider call, or deterministic commercial authority is introduced.

## Transport contract

`core/research/aws-v0-transport.ts` freezes transport schema version `1`, a 64 KiB message ceiling, batch size one, maximum concurrency two, worker/visibility timeouts, redrive count, strict work-unit framing, and dedupe-key continuity between envelope and `ResearchWorkUnit`.

## Deployment policy

`deploy:research` exists for explicit manual deployment. The existing CI deploy job remains database-only; Build 8 does not silently expand automatic AWS deployment scope.

## Next build

Build 9 should add the durable claim/idempotency boundary and the first real research executor behind the disabled Build 8 transport. Only after that boundary is certified should the SQS event source mapping be enabled.
