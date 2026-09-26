# Build 11 — fixed read-only Data API transaction probe

Status: operator diagnostic, **not a migration executor or migration approval**.
The earlier blocked live migration-runner publication is not retried by this
separate read-only check. No live-schema write adapter is provided.

## Why this check exists

The offline migration-ledger specimen uses one PostgreSQL backend transaction
for ownership, schema changes and its history receipt. The actual Data API path
has not yet demonstrated transaction continuity. The supplied schema report and
available encrypted snapshot are already recorded: do not request them again.

This probe observes only the connection prerequisites. It never loads migration
files, creates a history schema, changes an existing table, queries business rows
or alters research controls. A PASS does not close the live-migration gate.

## Exact actions

Using the existing MarketRoute administrator role session in account 801132668416,
London, the script checks STS identity and the existing database stack outputs.
It resolves only the approved secret ARN; it never fetches a secret value.

It then opens three short transactions, with at most two active concurrently.
Each is set to READ COMMITTED, READ ONLY before any query, with a local five-second
statement timeout. Queries use only PostgreSQL built-ins. The probe:

1. Records A's backend PID and transaction-local marker across separate requests.
2. Has independent transaction B try the same exclusive transaction-level lock;
   B must fail to acquire it while A holds it.
3. Rolls A back. B must now be able to acquire that same lock.
4. Verifies B's backend and separate local marker remain consistent.
5. Starts C. C must have no prior probe marker and cannot acquire B's lock.
6. Commits **read-only B**, which contains no schema or business-data writes.
   C must then acquire the lock, demonstrating release after commit.
7. Rolls C back and records cleanup outcomes.

Lock namespace 1297241168 is reserved for this diagnostic and a random positive
32-bit key is selected for each run. This does NOT use the migration lock or take
an application-table lock. Local settings and lock ownership are transient state;
“read-only” does not claim that the database service performs no physical writes.

Only six explicit API actions and five fixed single SQL statements are permitted.
All database SQL includes a transactionId; there is no autocommit SQL path. Whole
payloads, parameter names/types and targets are checked before CLI execution.
There is no SQL/DSN/endpoint/migration-file argument or schema-write mode. Requests
use pinned HTTPS endpoints, TLS validation and one CLI attempt. CLI JSON inputs
are temporary mode-0600 files, removed after use. Receipts do not include raw
transaction IDs, SQL bodies, arbitrary errors, credentials or secret values.

## Operator use

Upload the generated kit to the existing CloudShell. Extract it, enter its root
folder, verify SHA256SUMS, then run:

```sh
python3 scripts/build11-data-api-transaction-probe.py --run-read-only
```

No arguments performs no AWS calls and shows help. Python 3.10+, AWS CLI v2 and
the existing authenticated role session are sufficient; no npm/pip is required.
No new IAM grants, snapshot, deployment or production-control changes are needed
merely to run this check. An AccessDenied result is a blocker to inspect, not a
reason for broader grants.

The check may wake Aurora and incur normal Aurora/Data API charges. There is no
Bedrock/token-count/inference call. Only DatabaseResumingException before the
first established transaction can retry: maximum three begins, ten seconds apart.
All later failures stop the sequence. There are no automatic commit retries.
The script attempts one rollback per known open transaction on failure. Missing
transaction IDs, uncertain end responses and failed cleanup remain explicit,
not successful rollback or inferred migration commit. If interrupted with SIGKILL
or the connection is lost before a BeginTransaction ID returns, cleanup cannot
be guaranteed; Data API documents automatic rollback after three minutes without
transaction activity. This probe cannot prove an unknown write-commit outcome.

Save and return the generated JSON file. Its summary has seven PASS checks only
on full success. `migrationApproval: NOT_GRANTED`, `liveWorkerProof: NOT_RUN` and
`productionActivation: BLOCKED` remain even after transport success. A fresh
receipt path is used by default, and existing files/symlinks are rejected.

## Offline verification and limits

The safety suite uses controlled AWS-shaped responses and no credentials. The
PostgreSQL suite starts an owned network-disabled PostgreSQL 16 container with no
published ports. It drives the exact probe SQL through native psql sessions with
validated parameter conversion, verifies the real lock/session semantics, and
compares schema dumps before and after. This is not actual AWS wire-format, IAM,
Aurora16.8 or RDS Data API certification. Control-plane and transaction response
envelopes are simulated. One failure test discards a successful native COMMIT
response; it is not a real network partition or unknown DDL commit experiment.

A successful live receipt establishes a prerequisite for the migration procedure,
not a runnable implementation of it. The separate live migration executor,
production history installation and write-transport reconciliation remain
unpublished/untested; do not adapt this diagnostic into a writer or run the lab
migration specimen against Aurora. Research deployment and restricted-worker
proof also remain outstanding.

## Primary references reviewed on 26 September 2026

- https://docs.aws.amazon.com/rdsdataservice/latest/APIReference/API_BeginTransaction.html
- https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/data-api.calling.cli.html
- https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/data-api.troubleshooting.html
- https://www.postgresql.org/docs/16/sql-set-transaction.html
- https://www.postgresql.org/docs/16/functions-admin.html#FUNCTIONS-ADVISORY-LOCKS


## Transaction-ending response correction (26 September 2026)

The operator's first three checks passed before `END_RESPONSE_UNVERIFIED`.
In this code path the first end operation is rollback of transaction A. The old
probe required the exact CLI-example text `Rollback Complete`; its receipt did
not preserve the returned status field. Thus the old receipt does not establish
what AWS actually returned or prove that either cleanup operation failed at AWS.
It must remain BLOCKED and is never retrospectively relabelled as successful.

AWS's CommitTransaction and RollbackTransaction API references specify a
successful HTTP 200 response and a transactionStatus string with length 0..128,
not an enum of particular phrases. AwsCli already rejects nonzero CLI exit codes,
malformed JSON and non-object responses. Following a successful API call, the
probe now validates the status field's string shape and length, including an
empty string, instead of matching a documentation example. Missing/non-string
fields and strings longer than 128 remain blocked conservatively. No endpoint,
SQL, transaction ownership, retry, model or permission setting changed.

Every returned end response now records the transaction label (A/B/C), operation,
normal/cleanup path, field presence, shape validity, length, SHA-256 and a class
(EMPTY_STRING, CLI_EXAMPLE, OTHER_STRING, MISSING_OR_NON_STRING). Arbitrary returned
text, raw transaction IDs and secrets are not recorded. An API acknowledgement is
not an independent lock-release result. The normal-path rollback/commit lock
transfer checks still must pass; a success-looking response that leaves the lock
held fails those checks. Real API errors and uncertain responses are never
converted to success or retried as commits. This read-only probe does not certify
write durability or reconciliation of an unknown migration commit.

The safety tests now use independent example fixtures and cover empty strings,
other bounded strings, missing/malformed/oversized fields, redaction, cleanup,
nonzero CLI exit with success-looking stdout, and false acknowledgements with
locks still held. Native PostgreSQL reruns the complete probe with example,
empty and different status text envelopes, plus a lost-commit-response case.
These status envelopes are simulated; the rerun in CloudShell is still needed
to establish the actual live outcome and response shape.

References:
- https://docs.aws.amazon.com/rdsdataservice/latest/APIReference/API_RollbackTransaction.html
- https://docs.aws.amazon.com/rdsdataservice/latest/APIReference/API_CommitTransaction.html
- https://docs.aws.amazon.com/cli/latest/reference/rds-data/rollback-transaction.html
