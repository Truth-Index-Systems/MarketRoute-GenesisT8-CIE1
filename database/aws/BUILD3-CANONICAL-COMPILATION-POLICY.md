# AWS V0 Build 3 — Canonical Schema Compilation Policy

Status: FROZEN FOR BUILD 3

Build 3 compiles the final MarketRoute database contract into one clean AWS PostgreSQL baseline. Historical Supabase migration history is forensic input only; it is not AWS migration history.

Doctrine: **Fresh data. Final logic. Clean provenance.**

## 1. Source history boundary

- `supabase/migrations/0001` through `0065` are schema/behaviour oracles only.
- AWS history starts at `database/aws/0001_marketroute_aws_canonical_baseline.sql`.
- The AWS baseline must contain zero historical users, organisations, campaigns, companies, evidence, claims, opportunities, jobs, research spend, runtime events, or mixed-version snapshots.
- `0019_v1_evidence_migration.sql` is excluded in full. Its V1 -> V2 ETL tables, functions, audit rows and import machinery are not part of AWS V0.

## 2. Supabase/PostgREST infrastructure that must not enter the AWS baseline

The following are infrastructure coupling, not MarketRoute semantics:

- PostgreSQL roles `anon`, `authenticated`, and `service_role`.
- GRANT/REVOKE statements whose only purpose is those Supabase roles.
- PostgREST schema-cache commands such as `NOTIFY pgrst, 'reload schema'`.
- Direct `auth.users` foreign-key dependencies.
- `auth.uid()`, `auth.role()` and request-JWT session-setting dependencies.
- RLS policies whose identity model depends on Supabase roles or Supabase `auth.*` helpers.

They must be removed or replaced by explicit AWS runtime/identity boundaries. They must never be copied into the baseline merely to make historical SQL compile.

## 3. Identity semantics that must be preserved

Removing Supabase identity infrastructure does **not** remove MarketRoute tenancy semantics.

The AWS schema must preserve:

- stable internal MarketRoute user UUIDs;
- organisation membership and ownership;
- seller/campaign ownership;
- entitlement and commercial-boundary ownership;
- anonymous Discovery -> account -> claim -> workspace continuation semantics;
- tenant-private versus globally reusable Genesis/Truth boundaries.

Cognito identity mapping is implemented in Build 5. Build 3 therefore exposes clean database boundaries that Build 5 can bind to; Build 3 does not embed Cognito-specific tokens into canonical commercial logic.

## 4. Historical DML classification

Migration-time DML must not be copied blindly into the fresh AWS baseline.

### 4.1 Schema-release history

Historical inserts into `public.marketroute_schema_releases` are migration bookkeeping. They are excluded as historical rows. The AWS baseline may create the release table if it is part of the final schema and may write one AWS-V0 baseline release record, but it must not reproduce the old release chain.

### 4.2 Backfills and repair DML

Migration-time `UPDATE`, `INSERT`, `DELETE`, `TRUNCATE` or `COPY` statements that repair rows created by earlier builds are excluded because the AWS database starts empty.

Their **resulting invariant** must still be represented in final DDL. Example: an old migration may add a nullable column, backfill historic rows, then make the column `NOT NULL`; the AWS baseline should create the final column directly with the final constraint and should not execute the historical backfill.

### 4.3 Runtime function DML

DML inside final stored functions/procedures is not historical migration data. Runtime writes that implement evidence ingestion, claim persistence, Truth/authority lifecycle, Genesis work, commercial lifecycle, billing state or other canonical behaviour must be preserved unless a later authoritative definition supersedes them.

The compiler must distinguish migration-time executable DML from DML contained inside stored routine bodies.

### 4.4 DO blocks and CTE mutations

A migration-time `DO $$ ... $$` block containing DML and a top-level `WITH ... INSERT/UPDATE/DELETE/MERGE` statement count as migration-time data mutation and must be explicitly classified. They may not bypass the fresh-data gate merely because the first token is `DO` or `WITH`.

## 5. Final-object rule

For tables, views, routines, triggers, indexes, policies and other schema objects, Build 3 reconstructs the **final effective state**, not the chronological migration path.

- superseded routine/view definitions are not emitted;
- obsolete temporary objects are not emitted;
- later hotfixes are folded into the canonical definition;
- final constraints/defaults/indexes/triggers are emitted once;
- strange-but-authoritative Truth/CIE/R4/R5/R6 definitions are preserved and flagged rather than semantically cleaned up.

## 6. Frozen semantic boundaries

Build 3 must not change these rules:

1. AI is never commercial authority.
2. Truth/evidence is authoritative for factual state.
3. R4/R5/R6 authority remains explicit.
4. CIE/UDOSIB owns deterministic commercial reasoning and ranking.
5. External facts retain provenance/currentness requirements.
6. Queue messages are never canonical state.
7. Work is designed for at-least-once execution and idempotent recovery.
8. Research budgets and entitlements remain authoritative below infrastructure autoscaling.
9. Customer-private intelligence cannot leak into the global Genesis bank.
10. A company may be globally reusable without organisation-private research becoming global.
11. No mixed-version research is imported.

## 7. Build 3 emission gate

`0001_marketroute_aws_canonical_baseline.sql` may be emitted only when all of the following are true:

- all source migrations are inventoried and hashed;
- `0019_v1_evidence_migration.sql` is excluded from canonical candidates;
- Supabase/PostgREST-only statements have explicit exclusion dispositions;
- every `auth.*` / request-JWT dependency has an explicit AWS rewrite disposition;
- every migration-time DML statement has an explicit exclusion or canonical-seed disposition;
- hidden mutation in `DO`/CTE statements is detected;
- all unclassified SQL is resolved;
- final object candidates have deterministic provenance;
- no historical application/research/customer data can be emitted.

After emission, the baseline must compile cleanly against an empty PostgreSQL 16 database before it is ever applied to the AWS V0 Aurora cluster.
