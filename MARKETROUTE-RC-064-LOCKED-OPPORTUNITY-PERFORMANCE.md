# MarketRoute RC 0.64 — Locked Opportunity + Bootstrap Performance Hardening

## Why this patch exists

Production exposed `57014: canceling statement due to statement timeout` from `marketroute_workspace_commercial_access_v1`. The Discovery commercial-access RPC was recomputing the full R4/R5/R6 current-authority graph once per candidate opportunity while trying to build the two locked teasers after the permanent free eight. The same exact ready-count pattern was also used by anonymous and paid refill claim paths that run from `/api/cron/bootstrap`.

The result was two customer-visible symptoms from the same performance seam:

1. the two locked opportunities could fail to project after the free eight; and
2. bootstrap could fail while evaluating refill readiness as the candidate pool grew.

## What changed

Migration `0063_locked_opportunity_projection_bootstrap_performance_hardening.sql` adds a bounded commercial/orchestration readiness projection over the existing materialised list summary introduced by migration 0058.

The projection only accepts opportunities that:

- are `REVIEWABLE`, `APPROVED`, or `ENGAGED`;
- are projected `authorityReady` from current persisted R4/R5/R6 lineage; and
- have `materialisedSyncCurrent=true`, meaning the persisted opportunity sync came from an exact authority-ready envelope for the current R4/R5/R6 records and remains inside its revalidation window.

It does **not** create authority. Exact company/opportunity detail and engagement execution still use the canonical exact authority/currentness gates.

### Discovery commercial access

`marketroute_workspace_commercial_access_v1` no longer calls `marketroute_authority_ready_v1` once for every candidate. It uses the bounded materialised current-sync projection and returns at most two server-redacted locked teasers.

The free entitlement is also explicitly bound to `anonymous_discovery_runs.original_campaign_id`, rather than whichever campaign happens to be newest.

### Free-eight allocation

Claimed and browser Discovery unlock allocation now consumes the same bounded materialised current-sync proof rather than recursively recomputing the full authority graph during every entitlement read. The permanent limit remains eight.

### Refill / bootstrap

`marketroute_anonymous_discovery_ready_count_v1` and `marketroute_campaign_authority_ready_count_v1` now use the bounded current-sync projection. This removes the expensive per-row exact authority graph from the `/api/cron/bootstrap` refill claim path.

The three bootstrap workers also catch claim-time RPC failures and return a classified MarketRoute error instead of letting a claim exception escape unclassified from the worker function.

## Frozen boundaries

- Truth semantics unchanged.
- R4 writer unchanged.
- R5 writer unchanged.
- R6 writer unchanged.
- no fourth authority writer.
- free entitlement remains eight.
- locked teaser boundary remains two.
- locked payload exposes only opportunity/company identity metadata.
- exact detail reads remain fail-closed.
- engagement execution authority is unchanged.
- billing and Stripe logic are unchanged.
- UI from RC 0.63 is preserved.

## Deployment

Apply migration 0063 after 0060, 0061 and 0062, then deploy the application bundle.

No earlier migration should be edited or rerun in place.
