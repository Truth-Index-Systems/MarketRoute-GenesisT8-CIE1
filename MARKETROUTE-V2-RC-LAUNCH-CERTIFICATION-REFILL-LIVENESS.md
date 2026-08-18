# MarketRoute V2 RC — Launch Certification & Refill Liveness

## Purpose
Close the four Truth Index audit findings from the Launch-Ready Quota / SSR RC without changing R4/R5/R6 authority semantics or the 8-free / 2-locked commercial boundary.

## Changes
- Added migration `0061_anonymous_discovery_refill_liveness_launch_certification.sql`.
- Anonymous refill jobs are now seeded as tracking jobs before `COMPANY_CORE_V1` completion so an exhausted research envelope can terminate truthfully instead of deadlocking behind the research-cycle gate.
- Added server-side budget-state functions that respect committed spend, active reservations, active research, zero-cost waiting work, and the minimum positive queued work cost.
- Refill claims and extension-company linking are blocked once the immutable anonymous research envelope can no longer progress.
- Terminal states now persist explicit reasons such as research capacity exhausted, window closed, attempt ceiling, candidate ceiling, or paid conversion.
- Public plan catalogue validation is all-or-nothing: exactly Starter, Growth and Scale must be present with valid positive pricing and structural limits. Any partial/malformed catalogue falls back to the frozen launch catalogue.
- SSR fallback now emits a structured server log (`MARKETROUTE_PUBLIC_PLAN_CATALOG_FALLBACK`).
- Release certification now truthfully declares post-freeze operational migrations through 0061 and certifies both 0060 and 0061 as non-authoritative.
- `production:check` now includes both the ready-quota SSR gate and this launch-certification/liveness gate.
- Added a deterministic end-to-end orchestration integration model for `10 scoped / 5 ready -> refill -> 10 ready -> 8 free + 2 locked`, plus budget-exhaustion and paid-conversion terminal scenarios.

## Deployment order
1. Apply any unapplied migrations through 0060.
2. Apply `0061_anonymous_discovery_refill_liveness_launch_certification.sql`.
3. Deploy the application build.
4. Run `npm run production:check`.
5. Run Vercel production compilation and the live lineage/cutover checks before launch.

## Authority statement
Migration 0061 introduces no authority writer and does not insert into R4, R5, R6 or canonical authority records. It changes orchestration/liveness only.
