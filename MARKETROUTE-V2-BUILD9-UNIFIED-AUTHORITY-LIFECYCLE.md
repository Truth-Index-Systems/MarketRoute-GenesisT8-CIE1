# MarketRoute V2 — Build 9
## Unified Authority Lifecycle

Status: **BUILD COMPLETE — DEPLOYMENT CANDIDATE**

Migration: `0012_unified_authority_lifecycle.sql`
Constitution: `MRV2-CONSTITUTION-1.0.0`
Lifecycle version: `MRV2-AUTHORITY-LIFECYCLE-1.0.0`

## Purpose

Build 9 closes the lifecycle defect discovered in MarketRoute V1: human workflow state and evidence-qualified authority state must never be the same state machine.

The R4, R5 and R6 kernels from Builds 6–8 are unchanged. Build 9 introduces a derived lifecycle over their existing currentness predicates and an audited founder-review boundary.

## Constitutional invariant

An opportunity can validly be:

`workflow = APPROVED`

while:

`authority = R4_REVALIDATION_REQUIRED / R5_REVALIDATION_REQUIRED / R6_REVALIDATION_REQUIRED`

This does not erase approval. It makes the opportunity non-executable until authority is current again.

## Authority writer count

Build 9 registers **no new authority writer**.

The complete writer set remains:

1. `marketroute.r4.commercial-reality`
2. `marketroute.r5.relationship-graph`
3. `marketroute.r6.contact-truth`

`EXECUTION_PERMISSION` remains future-only.

## Derived authority envelope

New RPC:

`marketroute_authority_envelope_v1(organisation, campaign, company, at)`

The database selects only authorities for which the existing R4/R5/R6 `*_authority_current_v1` predicates return true at the requested instant.

Possible lifecycle states:

- `R4_REVALIDATION_REQUIRED`
- `COMMERCIAL_RESEARCH_REQUIRED`
- `NOT_ADMISSIBLE`
- `R5_REVALIDATION_REQUIRED`
- `ROUTE_RESEARCH_REQUIRED`
- `ROUTE_NOT_APPLICABLE`
- `R6_REVALIDATION_REQUIRED`
- `CONTACT_RESEARCH_REQUIRED`
- `CONTACT_NOT_APPLICABLE`
- `AUTHORITY_READY`

Only the exact chain:

`COMMERCIAL_CANDIDATE → ROUTE_STRUCTURALLY_OPEN → CONTACT_AUTHORISED`

with all three parents current produces `AUTHORITY_READY`.

No score, confidence, rank, probability or cached `authority_status` is consulted.

## Exact review provenance

Founder reviews now record:

- request ID;
- prior workflow state;
- resulting workflow state;
- exact authority envelope;
- SHA-256 authority-envelope fingerprint;
- reviewer;
- review timestamp;
- review decision and note.

A separate append-only `opportunity_workflow_events` ledger records the same transition boundary for future system transitions.

## Approval semantics

`APPROVE` requires:

1. opportunity workflow is currently `REVIEWABLE`;
2. the reviewer is an active OWNER/ADMIN/MEMBER of the organisation;
3. R4/R5/R6 are `AUTHORITY_READY` at the review instant.

The approval is then persisted as human history.

If Truth, a relationship, a contact, the seller genome or any authority validity boundary later changes, R4/R5/R6 can become non-current. The opportunity remains `APPROVED`.

## Human override semantics

`REJECT` is a legitimate human decision and does not require current positive authority. A founder may reject a mathematically admissible opportunity.

`RETURN_TO_RESEARCH` explicitly changes human intent back to `RESEARCHING`.

Build 9 never automatically rewrites human workflow because authority changed.

## Derived execution predicate

New RPC:

`marketroute_opportunity_executable_now_v1(opportunity_id, at)`

It is true only when:

- workflow state is `APPROVED`; and
- the authority envelope is currently `AUTHORITY_READY`.

This is deliberately **not** a fourth authority writer. It creates no authority record and sends nothing. Build 12 will consume this boundary when engagement execution exists.

## Idempotency

Founder reviews are keyed by `(opportunity_id, review_request_id)`.

- same request ID + same semantic request → deduplicated;
- same request ID + changed reviewer/decision/note → fail closed;
- a legitimate retry may arrive after the five-minute fresh-review window and still deduplicate safely;
- only a new review action must carry a near-current review timestamp.

This ordering was hardened during Build 9 after identifying that checking review-time freshness before idempotency would incorrectly reject delayed network retries.

## Direct DML

Direct application mutations remain revoked for:

- `opportunities`
- `opportunity_human_reviews`
- `opportunity_workflow_events`

The service role may mutate founder review/workflow only through the scoped Build-9 RPC.

## Revalidation independence

Forensic checks explicitly prove the Build 6/7/8 authority migrations contain no dependency on:

- `opportunities`
- `workflow_state`

Therefore R4/R5/R6 may be regenerated while workflow remains `APPROVED`, `REJECTED`, or otherwise historically correct.

## Application boundary

New modules:

- `core/authority/lifecycle.ts`
- `platform/database/authority-lifecycle-repository.ts`
- `application/opportunities/lifecycle-service.ts`

The application layer consumes the repository; it does not call PostgREST directly.

## Database additions

- extended `opportunity_human_reviews` forensic columns;
- new append-only `opportunity_workflow_events`;
- `marketroute_authority_envelope_v1`;
- `marketroute_authority_envelope_fingerprint_v1` (internal);
- `marketroute_authority_ready_v1`;
- `marketroute_opportunity_executable_now_v1`;
- `marketroute_record_opportunity_review_v1`.

## Validation

Full V2 constitutional regression:

**966 / 966 PASS across 36 suites**

Build 9 specific:

- 35/35 lifecycle static checks
- 13/13 SQL safety checks
- 21/21 pure lifecycle adversarial tests
- 36/36 database lifecycle attacks

Additional gates:

- strict changed-module TypeScript compile: PASS
- whole V2 TS/TSX transpilation: 43/43 PASS
- standalone SQL equals canonical migration `0012`: PASS
- no changed PostgreSQL return signatures: PASS
- no new authority writer: PASS

## Deployment order

1. Run `APPLY-IN-SUPABASE-MARKETROUTE-V2-BUILD9.sql`.
2. Deploy the Build-9 repository ZIP to Vercel.
3. Do not manually create opportunity rows yet. Opportunity creation and prioritisation remain Build 11 responsibilities.

## Next build

Build 10 — Genesis Autonomous Research Engine.

It will consume unresolved Truth/R4/R5/R6 states as research pressure and decide *what evidence to acquire next*, with budget, concurrency, resumability and counterfactual value controls. It will not create new commercial authority mathematics.
