# Build 11 — transaction-coupled migration history and resume protocol

Status: **TEST-ONLY PROTOCOL SPECIMEN**. Read commit-specific CI receipts for
execution results. This is not a live Aurora migration runner or permission to
apply SQL. No connection to the user's database is available in this test.
The previously blocked live runner is not republished, renamed or rerouted.

## Problem being addressed

The earlier rehearsal demonstrated that each file commits independently and
that replaying 0005 after 0007 can silently downgrade the recovery-aware claim
function. A completed command, an old terminal log, or the mere existence of a
table cannot establish which ordered file versions committed.

The existing `marketroute_schema_releases` is retained, not repurposed or
backfilled. This specimen uses a separate **test-only** schema,
`build11_ledger_lab`, inside its newly owned network-disabled PostgreSQL instance.
Nothing installs that schema in AWS or changes production migration files.

## Executable protocol exercised by the test

1. Validate every source file against the previously pinned SHA-256 manifest.
2. Begin READ COMMITTED and obtain one transaction-scoped advisory lock before
   observing the catalogue or history. A busy lock produces MIGRATION_BUSY;
   it never becomes proof that a migration did not commit.
3. Verify actual backend lock possession, not just a process-local flag. Ending
   the transaction invalidates that permission to inspect/apply.
4. Validate a contiguous history prefix: ordinal, filename, content hash, plan
   fingerprint, predecessor catalogue hash, successor catalogue hash and a run
   identifier. Gaps, reordering, different bytes and unknown files are rejected.
5. Compare the **latest** catalogue with the last recorded stage. Checking the
   original postcondition for every historical file would be wrong because later
   migrations legitimately replace some earlier functions.
6. If the requested file is already in that validated prefix, skip its body. If
   it is not the next file, stop before any DDL. If there is no history but the
   schema is beyond the baseline, require review instead of inventing receipts.
7. Execute the unchanged file body, check the successor catalogue, and insert its
   receipt in the **same transaction**. The original hash-pinned outer BEGIN and
   COMMIT are replaced only inside the isolated test to insert that receipt;
   source files on disk are not edited. Function bodies are not semicolon-split.
8. Check catalogue/history agreement again before COMMIT. If the application
   loses its success acknowledgement, open a fresh connection, reacquire the
   lock, and inspect durable state. Do not automatically replay a file.

The specimen deliberately stops if model admission or recovery is enabled. It
checks history structure, grants and triggers as well as history values. History
updates, deletes and truncation are rejected by test-local database triggers;
untrusted database roles have no schema/table access.

## Reference and independence of the comparison

The test restores baseline 0001 and identity 0002 only into a new empty database
and seeds synthetic pre-existing rows using the prior rehearsal fixture. It then
clones that disposable database into a separate reference database. The reference
executes the original, unwrapped migrations in order and captures each observed
catalogue. The protocol database is compared against those observations.

Catalogues include ordinary tables, columns, constraints, indexes, non-internal
triggers, function-definition hashes, owners, grants and row-security flags.
They exclude OIDs and data values. This is not a full PostgreSQL object audit:
roles, extensions, views and policy bodies are not fully compared. Reference
hashes are generated in this PostgreSQL test environment, NOT transplanted into
Aurora as a newly approved live schema contract.

## Failure and concurrency cases

For each of 0003–0007, after writing the test receipt but before committing:

- Inject an SQL error, a statement timeout, or a client disconnect. Compare the
  public schema dump, baseline row fingerprints and committed history with their
  pre-transaction state. Neither a success receipt nor partial DDL may survive.
- Hold the transaction open while another coordinator tries to inspect or apply.
  It must report busy rather than reading an absent uncommitted receipt as a
  retry authorisation. After commit, a fresh coordinator must skip the file and
  retain exactly one receipt.
- Discard the application's knowledge of a real local COMMIT response. A fresh
  connection must recover the committed prefix without executing the file again.

Other checks cover an incorrect successor contract, out-of-order input, changed
source bytes, a downgraded function with apparently valid history, disabled
history protection, enabled controls, and an installed schema with absent
history. Seven separate in-memory perturbations of actual database receipts test
history validation; those seven are not described as on-disk corruption tests.
All original public table rows, including the existing release table, must stay
unchanged. No synthetic record is copied into the production database.

## What the proof does NOT establish

This is a native psql protocol specimen in an owned PostgreSQL 16 container with
network mode `none`, no ports, temporary storage and no AWS/PG/remote-Docker
connection environment inherited. The entry point accepts no arguments, DSN,
existing container or live target. Both owned databases disappear with the
container. There is no AWS SDK/CLI call, migration deployment or live-mode flag.

The lost-acknowledgement case discards a received client acknowledgement AFTER a
real local commit. It is not an actual network partition during COMMIT and is not
Data API commit/reconciliation certification. The protocol only serialises
cooperating migrators. A database owner issuing raw DDL outside that lock can
bypass it; operating permissions and a maintenance window need separate review.
The test is not resistant to a privileged administrator disabling its safeguards.
Integrity hashes are not cryptographic signatures or malicious-tampering proof.

## Remaining operational work

A permitted live execution method is still required. It must preserve one backend
transaction from lock acquisition through schema change, receipt insert and
commit, retain the same pre/post checks, and handle bounded failures and uncertain
commit outcomes. The current test does not supply a Data API adapter, a general
SQL parser, credentials, a production history migration, automatic backfill,
manual application command or snapshot-restoration procedure.

The provided live schema report and encrypted snapshot confirmation remain valid
inputs already supplied by the operator; do not request them again to repeat the
same review. Before any live change, validate the actual selected transport and
review its connection role, metadata normalisation, safety switches, snapshot
availability and rollback/data-continuity procedure. Do not enable production
consumers until the separate worker/recovery integration gates pass.

## Primary references

- https://www.postgresql.org/docs/16/functions-admin.html#FUNCTIONS-ADVISORY-LOCKS
- https://www.postgresql.org/docs/16/explicit-locking.html
- https://www.postgresql.org/docs/16/applevel-consistency.html
- https://www.postgresql.org/docs/16/app-psql.html
