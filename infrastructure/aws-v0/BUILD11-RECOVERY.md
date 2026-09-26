# Build 11 — Bounded recovery and queue deferral

Status: IMPLEMENTED / CURRENT-COMMIT CI PROOF REQUIRED / LIVE ACTIVATION BLOCKED.
Base for this tranche: `aac4c22fa042897614dc9c11827b7161e435f0ae`.

## Guarantees and explicit trade-off

Recovery retains the stored envelope, work ID, canonical attempt and reservation.
It cannot mint customer capacity, rewind a completed/failed job, grant semantic
truth, rank leads, or invoke the provider itself. Migrations 0001–0006 are unchanged.
The forward migration is 0007. Its recovery-control row defaults to disabled.

The scheduler's old abandoned-job reaper excludes AWS-dispatched work even after
its ownership deadline expires. It continues handling non-AWS work as before.
AWS retries must go through the separate bounded recovery transition instead of
advancing the canonical job and colliding with its existing execution receipt.

A saved success or terminal failure can synchronize after transport expiry without
another provider invocation. The execution function no longer records a failure
when a completion write has an ambiguous response. Replay checks the durable row.
When a worker crashed before any admission, the controller may refund only that
unadmitted claim; previous provider receipts must all exist. Active leases plus a
60-second safety grace are not recovered concurrently.

If an admitted provider call has no saved result, **automatic paid retry stops**.
RESERVED, UNKNOWN, and measured-but-result-missing attempts remain charged/held in
the existing accounting system and get a durable REVIEW_REQUIRED record. No usage
is invented or zeroed. This favors bounded cost and avoiding blind re-execution
over fully automatic recovery. Human reconciliation is required for these cases;
this tranche does not implement a review UI or issue refunds. A later distinct
work item must be explicitly authorized, not created by rewriting an old attempt.

## Queue behavior

The initial dispatcher no longer calls canonical failure once publication has
started: a publisher timeout or lost mark-sent response cannot prove SQS rejected
the message. PREPARED/SENT state and its reservation survive for recovery.

`runAwsV0RecoveryCycle` is a bounded, dependency-injected controller iteration.
It selects up to 20 due records (five by default), claims an exclusive 60-second
publication lease, republishes the canonical envelope once, and confirms the send.
There is no in-process publisher retry. Ambiguous sends/confirmations retain their
lease and publication count. A later iteration can publish the same envelope;
duplicate SQS message IDs do not create a new work identity or inference budget.
Three recovery publications are permitted by default, with a 25-minute cooldown
and a 24-hour automatic-recovery horizon. Exhaustion leads to REVIEW_REQUIRED.
Policy/campaign pauses wait without consuming publication attempts. Stored terminal
receipts are checked/synchronized before waiting, preventing a rate pause from
blocking already-finished work. Candidates are derived from database dispatch and
recovery records, independently of SQS message retention or a DLQ sample.

The Lambda entry permits one short rate wait (at most 12 seconds) only when the
request was specifically rate-deferred and enough invocation time remains. Budget
or policy denial never triggers this short retry. Failed source-queue deliveries
record their highest receive count in the database; recording does **not** acknowledge
them. If recording fails, the message still remains unacknowledged. Poison payloads
continue through the queue's existing failure/DLQ mechanism.

Queue configuration remains 1,440-second visibility, maxReceiveCount 5, four-day
source retention and 14-day DLQ retention. No bulk DLQ redrive, queue purge, message
deletion, new worker SQS-send permission or automatic deployment is introduced.
Recover known canonical work, not arbitrary/deleted DLQ payloads. A malformed
message that never mapped to canonical work still needs DLQ operator inspection.

## Integration and rollout gates

The controller is implemented/tested as source, **not deployed or scheduled**.
Its concrete scheduled runtime and least-privilege SQS publisher must be wired in
Build 13 and certified before the recovery-control switch or production consumer
is enabled. This migration is not a substitute for that scheduler. Review-required
records and held reservations need a monitored operational workflow before pilot.
The worker, admission scope and recovery control remain off in the live account;
no migration or deployment is executed by this tranche.

The worker package now includes the named recovery-ledger adapter. Existing ZIP
receipts are historical after runtime changes. A fresh package, independent double
build, x64/PostgreSQL proof and native ARM64 proof must be attached to this commit.
The proof tests synthetic state/transports, real SQL and real packaged SDKs—not
AWS endpoint timing, live SQS redrive, Bedrock output quality or worker-role IAM.

## Acceptance proof

Database checks cover: disabled control, uncertain initial send, confirmation
collision, competing controllers, pre-admission crash, active-worker grace,
RESERVED/MEASURED/UNKNOWN lost outcomes, post-expiry success/failure sync,
canonical-attempt mismatch, finite recovery count, paused campaigns, receive-limit
recording, database-only rediscovery, legacy-reaper separation and denied callers.
Runtime tests inject completion-response loss before/after database commit,
ambiguous publication, duplicate deliveries, bounded rate waits and failed recovery
receipt writes. Packaged SDK tests exercise all four new named database calls.

## Primary references

- https://docs.aws.amazon.com/lambda/latest/dg/services-sqs-configure.html
- https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-dead-letter-queues.html
- https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/setting-up-dead-letter-queue-retention.html
