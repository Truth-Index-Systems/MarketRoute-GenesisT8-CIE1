# MarketRoute V2 — Build 11: Opportunity Engine

## Status

Build 11 adds the product-layer Opportunity Engine on top of the frozen Build 9 R4→R5→R6 lifecycle and Build 10 Genesis research loop. It introduces **no new authority writer**. The constitutional writer set remains exactly R4, R5 and R6.

## Purpose

An opportunity is the product interpretation of current commercial authority. It is not a weighted score and does not grant authority. Build 11 answers:

- Is the company currently actionable, research-blocked, stale, not admissible, or not applicable?
- Is it reviewable by a founder now?
- Is an already-approved opportunity executable now?
- How strong is the underlying epistemic coverage across separate dimensions?
- How many structurally reachable and contact-authorised access points exist?
- Which already-actionable opportunities Pareto-dominate others without collapsing dimensions into one number?

## Opportunity dispositions

The pure engine maps the Build 9 lifecycle into:

- `ACTIONABLE`
- `RESEARCH_REQUIRED`
- `REVALIDATION_REQUIRED`
- `NOT_ADMISSIBLE`
- `NOT_APPLICABLE`

Unknown future lifecycle values fail closed rather than silently being reclassified.

## No opportunity score

The engine exposes independent dimensions:

- current Truth coverage
- evidence sufficiency
- freshness coverage
- coherence
- Truth Index (diagnostic only)
- structurally open access-point count
- authorised access-point count
- route redundancy (`NONE`, `SINGLE`, `MULTIPLE`)

It does not persist or calculate a weighted opportunity score, fit score, priority score, route score, or contact score.

`Truth Index` is not used in Pareto comparison because it already contains a maximin aggregation. Reusing it alongside its component dimensions would double-count the same epistemic information.

## Pareto product ordering

Pareto comparison is available only among profiles that are already `ACTIONABLE`. An opportunity dominates another only if it is at least as strong on every comparison dimension and strictly stronger on at least one. Trade-offs remain `INCOMPARABLE`.

The comparison dimensions are:

- current coverage
- evidence sufficiency
- freshness coverage
- coherence
- number of authorised access points

There are no weights and no additive total. Pareto output is product ordering only; it cannot change R4, R5, R6, workflow state or execution permission.

## Opportunity materialisation

A new `opportunities` row may be created only when the database-derived authority envelope is currently `AUTHORITY_READY`.

Materialisation is performed exclusively through:

`marketroute_sync_opportunity_v1`

The RPC:

1. requires service-role execution;
2. validates exact organisation/campaign/company scope;
3. requires an ACTIVE campaign;
4. requires explicit `CAMPAIGN` company scope;
5. re-derives the current authority envelope in PostgreSQL;
6. fingerprints that exact envelope;
7. refuses to materialise a new opportunity if authority is not ready;
8. creates a new row through `RESEARCHING → REVIEWABLE` and records the system workflow event.

Direct application DML on `opportunities` remains revoked.

## Workflow separation

Build 11 distinguishes system-managed pre-human states from human decisions.

The system may perform only:

- `RESEARCHING → REVIEWABLE` when authority becomes ready;
- `REVIEWABLE → RESEARCHING` when authority ceases to be ready.

It never automatically rewrites:

- `APPROVED`
- `REJECTED`
- `ENGAGED`
- `ARCHIVED`

Therefore `APPROVED + stale authority` remains a valid state exactly as established in Build 9. `executableNow` becomes false while founder intent remains intact.

## Founder return-to-research protection

A founder may explicitly select `RETURN_TO_RESEARCH`. Build 11 records a `FOUNDER_RESEARCH_HOLD` if the same unchanged authority-envelope fingerprint is still present. The opportunity cannot bounce straight back to REVIEWABLE merely because the old authority still happens to be ready.

A changed authority envelope permits reviewability again.

## Idempotency and forensic history

`opportunity_sync_events` is a new append-only ledger. Each sync has a globally unique request UUID and records:

- organisation/campaign/company
- opportunity if one exists
- outcome
- previous/resulting workflow state
- exact authority envelope
- envelope fingerprint
- timestamp

Retrying the same request safely returns the original result. Reusing a request ID for another scope fails closed.

## Current opportunity profile

`marketroute_opportunity_profile_v1` derives a profile directly from:

- current Build 9 authority envelope;
- the exact current R4 target Truth snapshot;
- current R5 structural route count;
- current R6 authorised route count;
- opportunity workflow state.

If the envelope claims `AUTHORITY_READY`, the profile independently requires the exact decisions:

- R4 `COMMERCIAL_CANDIDATE`
- R5 `ROUTE_STRUCTURALLY_OPEN`
- R6 `CONTACT_AUTHORISED`

and requires at least one structural and one authorised access point plus a current target Truth snapshot. Inconsistent actionable profiles fail closed.

## Genesis integration

Build 10's existing `GENESIS_RESEARCH_V1` scheduler remains the single autonomous owner. Build 11 does not create another scheduler.

At the end of a Genesis research cycle, the Opportunity Engine synchronises only:

- companies with current `AUTHORITY_READY`; or
- companies that already have opportunity history and may need pre-human reviewability refreshed.

Opportunity projection failure cannot erase completed research. Synchronisation is per-company; failures are recorded and the research scheduler may finish `PARTIAL` rather than incorrectly treating completed research as failed.

## Database objects

Migration `0014_opportunity_engine.sql` adds:

- `opportunity_sync_events`
- `marketroute_opportunity_disposition_v1`
- `marketroute_opportunity_research_pressure_v1`
- `marketroute_opportunity_profile_v1`
- `marketroute_sync_opportunity_v1`
- `marketroute_opportunity_sync_targets_v1`
- `marketroute_list_opportunity_profiles_v1`

No authority table or authority writer is added.

## Application modules

New modules:

- `core/opportunities/contracts.ts`
- `core/opportunities/engine.ts`
- `core/opportunities/index.ts`
- `platform/database/opportunity-repository.ts`
- `application/opportunities/opportunity-service.ts`

The product remains layered: core semantics → database adapter → application service. UI/API exposure remains Build 13+ work.

## Certification

Final Build 11 certification:

- Opportunity static gate: 21/21
- Opportunity SQL safety: 13/13
- Opportunity semantic adversarial: 25/25
- Opportunity database adversarial: 32/32
- Full Builds 1–11 constitutional regression: 1,212/1,212 across 44 suites
- Strict changed-module TypeScript compile: PASS
- Whole V2 TS/TSX transpilation: 56/56 PASS
- standalone Build 11 SQL = canonical `0014`: PASS

The final PostgreSQL runtime/parser gate remains the deployed Supabase project, and the final framework compilation gate remains Vercel.
