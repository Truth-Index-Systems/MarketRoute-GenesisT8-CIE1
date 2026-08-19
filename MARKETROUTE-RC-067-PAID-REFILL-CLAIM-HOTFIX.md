# MarketRoute RC 0.67 — Paid Refill Claim Ambiguity Hotfix

## Production symptom
`/api/cron/bootstrap` returned HTTP 500 while both calls to `marketroute_claim_paid_campaign_refill_v1` returned HTTP 400. Workspace activation and anonymous extension claims were not the failing calls.

## Root cause
Migration 0062 introduced `marketroute_claim_paid_campaign_refill_v1` as a PL/pgSQL `RETURNS TABLE` function whose output parameters include `organisation_id`, `campaign_id`, and `attempt_count`.

The function also used an unqualified composite conflict target and an unqualified attempt counter increment. In PL/pgSQL those identifiers can collide with the implicit output-parameter variables. This is the same class of PostgreSQL ambiguity previously hardened in the anonymous Discovery extension claimant.

## Fix
Migration 0064:
- replaces the composite inference target with the named database constraint `paid_campaign_refill_jobs_organisation_id_campaign_id_key`;
- qualifies the attempt increment as `prj.attempt_count + 1`;
- preserves the 10 authority-ready target, 60-company lifetime candidate ceiling, six-attempt episode ceiling, paid entitlement checks, research capacity checks, and materialised authority-ready projection;
- adds no Truth/R4/R5/R6 or authority writer.

## Deployment
Apply `0064_paid_campaign_refill_claim_ambiguity_hotfix.sql` after 0063, then deploy the RC 0.67 application bundle.

No rollback of 0063 is required. The earlier statement-timeout performance fix remains in place.
