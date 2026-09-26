# Build 11 — controlled migration executor candidate

Status: **DRAFT. Read commit-specific CI evidence. No live migration has run.**
The successful operator read-only Data API probe is already recorded in PR #11;
it must not be repeated as a substitute for completing this execution path.

## Scope

This implementation supplies a narrow execution path for the exact existing
0003–0007 files, rather than a general SQL endpoint or a modified diagnostic.
It makes no AWS calls by default. Inspection is separate from applying a plan.
It targets only the existing London MarketRoute database, administrator-role
session and already confirmed snapshot. It never provisions infrastructure,
changes IAM, creates another snapshot, invokes a model or activates research.
The command which applies a plan is a real database-writing operation, not a
read-only test. Do not run it without reviewing the generated plan and report.

The earlier blocked draft is not provided in this change. Review this new,
closed-statement implementation and its normal connector/CI results on their own
merits. No alternative API route, secret encoding or live test environment is used
to conceal a write. No claim about the cause of the earlier block is made.

## Execution contract

1. Verify all five original SHA-256 file hashes before any AWS call. The package
   contains no executable copy of baseline 0001 or identity migration 0002.
2. Segment only those exact trusted files, preserving quotes, dollar-quoted
   function bodies and comments. The scanner is not a general SQL validator.
   PostgreSQL independently parses the 68 resulting statements in CI, and the
   resulting catalogues are compared with a separate database running the original
   unsegmented files. Each Data API call sends one of these pinned statements.
3. Validate the existing role/account, database stack, Aurora version and Data API
   status, available encrypted snapshot and absent research worker. A topology
   change stops this rollout for review. The worker must be deployed after it.
4. Use a fixed SELECT 1 for bounded readiness only. Never automatically retry
   transactional DDL, BEGIN, COMMIT or an uncertain migration outcome.
5. Inspect in READ ONLY / READ COMMITTED with a transaction-scoped advisory lock.
   Reference mismatch, active research, history drift, changed owners/grants,
   enabled admission/recovery or missing predecessors stop the executor.
6. A successful inspection creates a one-hour plan containing target, initial
   stage, catalogue fingerprint and package-plan fingerprint. An exact second
   confirmation is required before entering the write path. The generated plan
   is not an external approval, security signature or production activation gate.
7. Each write transaction obtains the same advisory lock, short statement/lock
   timeouts, and SHARE locks on participating work/policy tables before checking
   that research and scheduler leases are idle. Privileged raw DDL outside this
   protocol is not prevented; use a controlled maintenance window.
8. Create the private `marketroute_migration_control` schema and immutable history
   only in the same transaction as the first missing migration. Existing
   `public.marketroute_schema_releases` is not repurposed or backfilled.
9. Apply exactly the next missing file, verify its successor catalogue, and insert
   its filename/checksum/plan/predecessor/successor/run receipt before COMMIT.
   Source files are not rewritten. Only their outer BEGIN/COMMIT are replaced by
   explicit Data API transaction operations. Later files retain separate commits.
10. Verify the latest installed catalogue/history in a fresh locked transaction.
    A repeated request for an installed file skips it only after that verification.
    In particular, 0005 must not replace the later recovery-aware claim routine.
11. An uncertain commit triggers one fresh locked reconciliation, then stops the
    batch regardless of whether it reads COMMITTED, NOT_COMMITTED or UNKNOWN.
    It never automatically re-executes DDL. An unavailable lock is UNKNOWN, not
    permission to retry. Normal rollback has at most one attempt per transaction;
    unknown closures remain in the report. Abrupt process termination can prevent
    cleanup and report finalisation; durable database history is authoritative.

## References and cross-environment checks

CI creates an independent PostgreSQL reference using the database role
`marketroute_admin`. It observes every stage of the unchanged files and the
separate control schema. Object-level fingerprints include ordinary tables,
columns, constraints, indexes, triggers, owners, grants, RLS flags and routines.
They exclude row data, OIDs and unrelated system schemas. Views, extension state,
roles and policy bodies are not a complete security audit. Each returned metadata
row is small; the whole catalogue is not squeezed into one large Data API field.

A source-derived reference is NOT assumed identical to Aurora. The operator
inspection must compare the actual live metadata before any migration. Different
catalogue rendering, schema ownership or ACLs require explicit review; the tool
lists differing object keys rather than deleting, normalising away or accepting
the disagreement. Your earlier detailed schema report remains reviewed input.

## CI versus live evidence

The integration test uses the actual Engine and Cloud CLI request-building code,
then supplies simulated AWS envelopes and control-plane metadata to real native
PostgreSQL sessions in a new network-disabled container. It exercises each
migration, rollback, connection loss, competing locks, durable receipt reuse and
uncertain commit branches. It is NOT actual Data API DDL, AWS commit-uncertainty,
Aurora minor-version equivalence, customer-scale lock contention or snapshot
restoration proof. The database and container are test-owned and removed.

The same archived Python source and pinned SQL are intended for the operator kit.
Integrity checksums are not signatures. Read the final CI results before issuing
operator instructions. No production history or migration receipt has been
created merely by publishing or testing this source.

## Operator sequence (after offline tests pass)

Upload/extract the generated executor kit in a new directory; retain old receipts.
Verify SHA256SUMS, then run the package's `migration-runner/run_migrations.py`
with `--inspect`. This can wake Aurora and incur database/Data API charges.
Inspection runs no DDL and generates a new report plus plan. Review both before
using any apply mode. Do not edit the reference or plan to force a match.

Application requires the reviewed plan file and exact `--confirm-plan-sha256`
value. The implementation does not print an auto-executing apply command. Execute
only during the approved maintenance conditions; stop on any error or uncertainty
and preserve the report. Later failure leaves earlier committed files in place.
Never run the raw directory, invent receipts, rerun baseline 0001/0002 or use a
reverse/drop migration as a rollback. Snapshot restoration creates a separate
cluster and requires its own data-continuity/cutover plan; it is not certified here.

After known successful application, verify the final schema and disabled controls
before reviewing the separate research-stack deployment and bounded worker test.
PR #11 remains draft. Queue consumption, recovery, model admission, Truth Index,
CIE, UDOSIB and R4/R5/R6 authority/ranking boundaries remain unchanged.

## Primary API references

- https://docs.aws.amazon.com/rdsdataservice/latest/APIReference/API_BeginTransaction.html
- https://docs.aws.amazon.com/rdsdataservice/latest/APIReference/API_ExecuteStatement.html
- https://docs.aws.amazon.com/rdsdataservice/latest/APIReference/API_CommitTransaction.html
- https://docs.aws.amazon.com/rdsdataservice/latest/APIReference/API_RollbackTransaction.html
- https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/data-api.troubleshooting.html
