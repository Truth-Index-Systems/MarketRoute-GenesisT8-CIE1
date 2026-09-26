# Build 11 — retire an unexecuted zero-budget test fixture

This is operator tooling, not a migration or a worker deployment. The new
`--close-uninvoked-existing /absolute/path/to/original-fixture-folder` mode writes
only the reviewed fixture's lifecycle state. It neither creates a new fixture
nor invokes Lambda. Default invocation continues to make no AWS calls.

## Input and evidence

Use only the saved STOPPED/ParamValidation fixture already inspected by the
operator. Its original summary, journal, fixture identifiers and attempt marker
are preserved. A new exclusive retirement marker and evidence subfolder are
written before the operation. Do not delete these markers after a failure.

The recorded operator state had one synthetic work unit, a PAUSED campaign and
disabled policy, RUNNING job/run, and zero execution/inference/artifact/nonzero
budget records. That is not worker database success and does not prove every
possible Lambda or infrastructure billing event. RUNNING was seeded by the test.

## Locked closure

Acquire the existing canary lock and the same per-work advisory lock used by
worker claim/recovery, followed by NOWAIT locks on the fixture's mutable rows
and shared locks on model/recovery controls. Verify the exact saved synthetic
ownership/payload, expired dispatch, paused campaign, archived fictional company,
disabled zero policy, original job attempt, no other active work, and no
execution/inference/artifact/budget/recovery records. Stop on conflict or drift;
never renew dispatch ownership, overwrite history, or accept arbitrary SQL.

The three writes use the existing canonical failure and scheduler closure
routines, plus a RESOLVED synthetic recovery receipt, in one transaction. Expected
outcome: job FAILED, job attempt FAILED, scheduler CANCELLED, one zero-valued
RELEASE and one RESOLVED recovery receipt. No money is refunded. Synthetic source,
evidence and work records remain. The dispatch is retained unchanged; resolved
recovery excludes it from polling and FAILED canonical work rejects a later claim.
A new read verifies the committed result. No claim/defer or model PASS is granted.

An uncertain commit is not retried or reported as successful closure. Inspect the
saved original fixture rather than recreating records. A session interruption may
prevent final report writing; retain the append/fsync journal. A privileged
administrator bypassing application locks remains outside these safeguards.

## Proof limits and next test

Read commit-specific CI receipts: boundary tests use simulated transports; the
integration runs the actual operator against real network-disabled PostgreSQL,
with simulated AWS response envelopes and adapted test database identity. The
lost-acknowledgement scenario deliberately discards a real local commit response;
it is not live Data API network-failure proof. No live closure is established by
passing CI. No database schema, worker code/package, IAM, queue state, model
admission, recovery, Truth Index, CIE, UDOSIB or R4/R5/R6 ranking logic changes.

After verified retirement, a separately requested fresh canary uses the corrected
explicit AWS CLI invocation arguments and new identifiers. It is not a replay or
relabelling of the original failed test. Keep all production switches disabled.

Primary locking reference: https://www.postgresql.org/docs/16/sql-lock.html
