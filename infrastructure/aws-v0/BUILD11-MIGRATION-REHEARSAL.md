# Build 11 — migration transaction and rollback rehearsal

Status: TEST-ONLY IMPLEMENTATION; see commit-specific CI results for execution.
This is not a live migration runner or approval to apply SQL to Aurora.
The previously blocked operator-runner publication is not retried by this work.
No runtime, existing migration, identity, scoring or deployment configuration is
changed. PR #11 remains draft and production activation remains blocked.

## Purpose

The reviewed live metadata is consistent with baseline 0001 and identity 0002,
with the new AWS research tables absent. The user supplied an available encrypted
pre-migration snapshot. Those are prerequisites, not execution/restore proofs.
This new test rehearses the five exact forward SQL files (0003 through 0007) with
synthetic pre-existing data and verifies PostgreSQL transaction failure behavior.
It does not ask the operator to repeat the schema collection or create a backup.

## Deliberately isolated test boundary

`tests/integration/aws-v0-build11-migration-rehearsal.py` starts and removes its own
Docker container using PostgreSQL 16, no network and no published ports. The data
directory is a temporary in-memory filesystem. It accepts no arguments, existing
container, DSN, endpoint, host or live mode. It has no AWS client, credentials,
SQL-over-Data-API implementation or deployment capability. Its subprocesses do not
inherit the parent shell's AWS, PostgreSQL or remote-Docker connection settings.

Only seven checksum-pinned source SQL files are accepted. The test restores
0001/0002 only into this newly created empty test database. It seeds a synthetic
identity, organisation, seller, company, campaign, source/evidence, research plan,
active background job and held budget reservation with original constraints and
triggers enabled. No customer data or uploaded catalogue is stored in the repo.

## Test matrix

For each of the five migrations:

1. Execute its transaction through the point immediately before COMMIT, inject a
   statement error, then verify the full schema dump and all table-row digests
   equal the state before that migration.
2. Inject a statement timeout at that boundary and verify the same rollback.
3. Close the client connection at that boundary without COMMIT and verify rollback.
4. Apply the original, unchanged file and verify every original table's rows are
   unchanged. Earlier migrations remain committed if a later transaction fails.

For 0004, a competing connection holds the affected table lock; a test-local
lock timeout must fail without dropping the old constraint or undoing 0003.
The fault injection modifies only an in-memory test string, not the source files.
The boundary helper is for those exact pinned files, not a general SQL parser.

After ordered application, check the exact seven-table addition, both disabled
controls, preservation of original routine definitions/ACLs except the intentional
reaper replacement, PUBLIC-execute revocation for research routines, and continued
append-only protection of work, evidence and budget rows.

## Two procedural hazards that must not be hidden

**The five files are not one atomic batch.** Each has its own BEGIN/COMMIT. A
failed 0004 can leave 0003 committed, which is a valid partial migration state to
record and resume deliberately. A future live executor needs a durable per-file
checksum/release record in the same transaction as each applied file, a lock
against concurrent migrators, pre/post checks and explicit ambiguous-commit
reconciliation. None of that live executor is supplied or certified here.

**Blind replay is unsafe even when it succeeds.** 0003/0004/0006/0007 recreate
objects and will fail when already installed. More subtly, 0005 uses CREATE OR
REPLACE: reapplying it after 0007 can silently replace the newer recovery-aware
claim routine with the older replay-only version. The test demonstrates that
change inside a transaction and rolls it back. Do not use an error-or-no-error
result as migration-history evidence or retry the entire directory blindly.

The files do not update `marketroute_schema_releases`; preserving that existing
history is verified. Its presence is not evidence that these five files ran.

## What rollback means here

A pre-commit SQL error, timeout or client disconnect is tested to restore the
previous committed database state within PostgreSQL. This is not a restore of
an Aurora snapshot, a guarantee about a lost Data API commit response, or proof
of an all-files transaction. PostgreSQL/server-side and client/API timeouts are
different failure boundaries.

After committed schema changes, destructive reverse SQL is not the default
rollback. Keep consumers and admission off, preserve any new receipts/reservations
and investigate the committed state. Restoring an Aurora snapshot creates a NEW
cluster; it cannot overwrite the existing one. It needs separate configuration,
writer-instance, network/IAM and data-continuity review before any cutover. The
available pre-migration snapshot has not been restore-tested by this work.

## Execution evidence and remaining gate

The credential-free CI job retains a receipt with the tested commit, actual
PostgreSQL version/image ID, seven input checksums, per-stage schema hashes,
baseline table-row digests and individual assertion results. A checksum is an
integrity record, not a signature or proof of cloud execution.

This tests PostgreSQL via its native local client, NOT a production migration
executor and NOT Data API transaction or network behavior. PostgreSQL 16 patch
level is recorded; the live Aurora report says 16.8, so the environments are not
identical. It also does not emulate customer workload scale or perform a full
security assessment. Existing worker tests remain a separate proof workflow.

The unresolved live-executor publication/validation gate is retained. No blocked
write is rerouted, and no replacement live runner or manual SQL application
command is included. Next required execution work is a permitted, reviewed,
tested release-ledger/transaction procedure; then a targeted operator-run schema
change, research-stack-only deployment with queues off and bounded worker canary.

## Primary references

- https://www.postgresql.org/docs/16/app-psql.html
- https://www.postgresql.org/docs/16/tutorial-transactions.html
- https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/data-api.calling.cli.html
- https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/data-api-timeouts.html
- https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-restore-snapshot.html
