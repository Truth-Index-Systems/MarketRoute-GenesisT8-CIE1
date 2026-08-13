# MarketRoute V2 — Build 2: Constitutional Supabase Schema

**Build:** 2 / 18  
**Status:** schema foundation candidate  
**Constitution:** `MRV2-CONSTITUTION-1.0.0`  
**Database boundary:** `MRV2-DB-BOUNDARY-1.0.0`

## Purpose

Build 2 establishes the fresh MarketRoute V2 persistence constitution. It intentionally implements **no Truth mathematics, no commercial reasoning, no R4/R5/R6 writer, no opportunity transition RPC, and no engagement logic**.

The database now has explicit storage boundaries for:

1. identity and tenancy;
2. canonical entities and raw provenance;
3. claims and evidence linkage;
4. non-authoritative reasoning;
5. locked future authority;
6. human workflow;
7. scheduler/resumability primitives;
8. AI cost telemetry;
9. append-only forensic audit history.

The governing invariant is physical: **evidence is not reasoning; reasoning is not authority; authority is not workflow.**

## Migration history

The new Supabase project begins at migration `0001`.

- `0001_platform_identity_and_tenancy.sql`
- `0002_canonical_entities_and_evidence.sql`
- `0003_reasoning_authority_and_workflow_separation.sql`
- `0004_scheduler_jobs_and_observability.sql`
- `0005_append_only_integrity_and_build2_release.sql`

`APPLY-IN-SUPABASE-MARKETROUTE-V2-BUILD2.sql` is an exact ordered concatenation of those five canonical migrations.

## Schema surface

Build 2 creates **27 tables**, **8 functions**, **23 triggers**, **6 authenticated RLS policies**, and **30 explicit indexes**.

### Identity / tenancy

- `organisations`
- `organisation_memberships`
- `seller_businesses`
- `campaigns`

Tenant-scoped composite foreign keys prevent campaign/seller/reasoning/authority/workflow rows from crossing organisation boundaries.

Authenticated users currently receive read-only access to their organisation/configuration rows. `marketroute_create_organisation()` is the sole user-facing write RPC introduced in Build 2 and atomically creates the organisation plus OWNER membership.

### Canonical entities / provenance

- `companies`
- `people`
- `organisation_company_scopes`
- `source_records`
- `source_acquisitions`
- `evidence_items`
- `claims`
- `claim_supersessions`
- `claim_evidence_links`

Raw evidence stores publication/origin time separately from observation/acquisition time. Build 2 does not reject strange source timestamps as “false”; the future Truth engine owns interpretation.

Claims have no truth state, probability or confidence column. They are immutable assertions linked to evidence categorically through `SUPPORTS` / `CONTRADICTS`, with a mandatory `dependence_family_key`.

Corrections are append-only through `claim_supersessions`; historical claim/evidence rows cannot be rewritten.

Private evidence scope is database-enforced:

- a global claim cannot consume tenant-private evidence;
- a tenant claim may consume global evidence or evidence from the same tenant;
- it cannot consume another tenant's private evidence;
- claim supersession cannot jump tenant, subject, or claim-key scope.

## Reasoning is explicitly non-authoritative

- `reasoning_runs`
- `reasoning_artifacts`

A reasoning artifact can contain deterministic or AI-assisted structured output, but its table contains no authority state, execution permission or viability field.

## Authority storage exists but authority capability does not

- `authority_writer_registry`
- `authority_records`
- `authority_events`

The registry is empty. `constitution/authority-manifest.json` also declares zero authority writers.

Direct DML on authority tables is revoked from `anon`, `authenticated`, and `service_role`.

Future authority writes must:

1. be registered by migration;
2. set the transaction-local `marketroute.authority_writer` identity;
3. match the registered authority stage and writer version;
4. reference a concrete persisted reasoning run and artifact;
5. match that reasoning run's organisation, campaign, and input fingerprint;
6. provide a finite `valid_until` timestamp;
7. later, in the build that owns the writer, have the persistence boundary recompute the authoritative fingerprint rather than trusting application input.

Authority snapshots and events are append-only.

## Workflow is physically separate

- `opportunities`
- `opportunity_human_reviews`

`opportunities` contains `workflow_state` only. It contains no commercial score, viability boolean, authority fingerprint or confidence field.

Build 2 deliberately grants **no direct INSERT/UPDATE/DELETE** on opportunity workflow to authenticated users or `service_role`. Later builds must introduce tested scoped transition functions rather than allowing arbitrary state changes.

Human review history is append-only.

## Scheduler / operational primitives

- `scheduler_runs`
- `scheduler_leases`
- `background_jobs`
- `background_job_attempts`

Jobs and attempts are separate, allowing resumability, retries, recovery and observability without overloading one state row. Tenant/campaign foreign keys are enforced where both scopes exist.

## Telemetry / audit

- `ai_usage_events`
- `audit_events`

AI token/cost/latency information is telemetry only and has no place in authority records. Both ledgers are append-only.

## V1 quarantine

The Build-2 migration surface contains no V1 runtime tables/RPCs and none of the historical authority fields such as weighted opportunity, route or confidence outputs.

There is no compatibility schema, adapter, old migration history, or runtime import.

## Verification

Latest certification:

- Architecture boundary: **8/8 PASS**
- AI boundary: **7/7 PASS**
- Legacy quarantine: **3/3 PASS**
- Authority manifest: **10/10 PASS**
- Constitutional schema: **44/44 PASS**
- SQL safety: **12/12 PASS**
- Build-1 architecture adversarial fixtures: **18/18 PASS**
- Build-2 database adversarial attacks: **22/22 PASS**
- Changed TS/TSX syntax transpilation: **3/3 PASS**

Constitutional assertions: **124**. With the 3 isolated TypeScript syntax checks, the Build-2 package exercised **127 checks** in total.

## Environment limits

The audit container has no PostgreSQL/Supabase server or parser available, so the SQL has been structurally and constitutionally audited but not executed against a local PostgreSQL instance. The new Supabase project's SQL editor/migration runner is therefore the final DDL compile/runtime gate.

The container also lacks the installed Next/React dependency tree. A dependency installation attempt timed out; therefore full `tsc --noEmit`/`next build` cannot be completed locally. The changed TS/TSX files pass isolated TypeScript transpilation, and Vercel remains the final full framework/dependency compile gate.

## Deployment order

1. Run `APPLY-IN-SUPABASE-MARKETROUTE-V2-BUILD2.sql` against the **fresh V2 Supabase project**.
2. Confirm the SQL transaction completes with no error.
3. Deploy the Build-2 repository to Vercel.
4. Run the constitutional gate in CI.

Do not introduce V1 data yet. V1 migration remains Build 17. Build 3 is the Evidence & Provenance Engine and will be the first build to define runtime persistence contracts over the evidence substrate created here.
