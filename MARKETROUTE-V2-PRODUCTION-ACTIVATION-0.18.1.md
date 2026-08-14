# MarketRoute V2 / Genesis T8 — Production Activation 0.18.1

## Status

Post-freeze operational activation of the Build 18 production candidate. This is not Build 19 and creates no new commercial-authority writer.

## Activated runtime boundaries

- Real OpenAI Responses API provider.
- Hosted web search with strict source grounding and domain filtering where appropriate.
- Strict JSON-schema outputs for machine-consumed AI results.
- Seller-genome extraction and new-workspace market bootstrap.
- Target-company research hypotheses grounded to consulted company domains.
- Genesis autonomous research cron.
- Opportunity synchronization after deterministic authority recomputation.
- OpenAI engagement drafting and categorical PASS / REWRITE / BLOCK review.
- Resend EMAIL delivery adapter with idempotency and an environment kill switch.
- Vercel cron authentication and schedules.
- Environment preflight and real OpenAI/Supabase connectivity smoke endpoints.
- Current Supabase publishable/secret API-key support with legacy-key fallback.

## Dependency hardening

- Node pinned to `22.x`.
- Next pinned to `15.5.23`.
- React and React DOM pinned to `19.0.4`.

## Database

Migration `0020_production_activation_runtime.sql` adds only operational workspace-activation state and service/authenticated RPCs required to bootstrap a new workspace. It does not insert into R4, R5, R6, opportunity or engagement authority tables and does not create another authority writer.

## Production safety

Outbound email remains disabled until `MARKETROUTE_DELIVERY_ENABLED=true`. Research retains campaign-level budget governance, max-job spend, concurrency, resumability and backpressure. All OpenAI outputs remain non-authoritative inputs to the deterministic Genesis chain.
