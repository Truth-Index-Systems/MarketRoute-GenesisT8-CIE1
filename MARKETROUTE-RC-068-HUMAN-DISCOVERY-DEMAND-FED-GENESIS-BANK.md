# MarketRoute RC 0.68 — Human Discovery + Demand-Fed Genesis Bank

## Purpose

Close three pre-launch product gaps without changing Truth, R4, R5, R6, opportunity authority, billing or commercial ceilings.

## 1. Human free-discovery language

The seven anonymous discovery stages now use deliberate customer-facing English rather than constructing first-person sentences from internal stage labels. The narrative header is `LIVE DISCOVERY`, and deterministic fallback narration remains readable even when AI narration is unavailable.

## 2. Demand-fed Genesis bank

MarketRoute already queried the Genesis intelligence bank before web discovery. RC 0.68 completes the loop: every company linked by initial activation, anonymous refill or paid refill is now registered back into the reusable Genesis company bank using the deterministic industry keys already derived for that market.

Registration is identity-only. It creates `genesis_growth_company_memberships` and an empty `genesis_growth_company_progress` row where needed. It never copies organisation-private campaign evidence into global Genesis completion fields and never writes Truth/R4/R5/R6 authority.

Bank selection now allows identity-known (20% density) companies to be reused rather than requiring global CORE completion. Denser globally researched companies continue to sort ahead of identity-only companies.

Migration 0065 also backfills already-scoped companies where modern campaign activation lineage contains deterministic `discovery.industryKeys`. Bootstrap then runs the same repair in bounded batches, so a transient bank-registration failure self-heals without blocking customer discovery.

## 3. Legacy onboarding removed from discovery-first launch flow

The free discovery already creates the organisation, seller and market context. Membership-less users are no longer sent to the legacy `Create your workspace` form and asked for organisation name / website again. Discovery claims either attach the existing anonymous workspace or fail explicitly; they cannot silently fall through to manual workspace creation.

## Deployment

1. Apply `0065_human_discovery_demand_fed_genesis_bank.sql` in Supabase.
2. Deploy the RC 0.68 application code.
3. Confirm `/api/cron/bootstrap` remains 200.
4. Start a fresh free discovery and verify human stage copy plus bank-first discovery telemetry.

## Authority statement

New authority writers: **0**.

Truth, R4, R5, R6, opportunity readiness, engagement authority, 8-free/2-locked entitlement and billing semantics are unchanged.
