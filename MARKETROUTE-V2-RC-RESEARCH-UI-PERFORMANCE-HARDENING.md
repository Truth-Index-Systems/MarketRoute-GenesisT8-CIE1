# MarketRoute V2 — RC Research / UI / Performance Hardening

Date: 2026-08-18
Baseline: Anonymous Discovery Launch Cost Freeze on top of Research Queue Fairness Hotfix / Product Build 26

## Purpose

This pass addresses three production observations together:

1. `/api/cron/research` could complete planning and opportunity sync with `executedWorkUnits = 0` and no provider call, while the reason remained opaque.
2. The standalone customer Research console exposed implementation detail that is not needed in the product navigation.
3. Authenticated navigation and passive conversational narration were adding avoidable page latency.

No Truth, R4, R5, R6, evidence, opportunity authority, commercial ranking or delivery semantics are changed.

## Research execution hardening

Migration `0049_research_execution_recovery_observability.sql`:

- Replaces `marketroute_recover_abandoned_research_work_v1` so a RUNNING research job is recoverable as soon as its owning scheduler lease no longer exists or is expired. The old 30-minute age delay is removed.
- Preserves the existing conservative abandoned-attempt budget accounting and lineage.
- Replaces `marketroute_claim_research_work_v1` using the queue-fairness implementation from 0047.
- Paid research-capacity exhaustion applies only to cost-bearing/provider-backed work. Zero-cost deterministic `REVALIDATE_R4/R5/R6` can continue because they do not consume paid AI capacity.
- Adds explicit defer/error reasons for concurrency, plan capacity, per-job cost and daily-budget deferral.
- Adds service-role-only `marketroute_research_queue_diagnostics_v1`.
- When a scheduler cycle executes zero work, the application fetches queue diagnostics and persists them in scheduler-run metadata and returns them in the cron JSON.

Expected next-run behavior:

- If provider-backed work is claimable: Vercel should show an OpenAI request plus persistence/complete RPCs.
- If no work is claimable: Vercel should show `marketroute_research_queue_diagnostics_v1`, and the endpoint response/scheduler metadata will explain the front of queue instead of silently returning zero execution.

## Customer UI simplification

- Removed `Research` from desktop/mobile primary navigation.
- `/app/research` is retained only as a safe redirect to `/app` so old bookmarks do not 404.
- The seven-stage MarketRoute pipeline still includes **Research** as a real persisted progress stage.
- Clicking the Research pipeline stage now opens **Market map**, where the customer sees the companies being evaluated rather than an engine console.
- Removed customer-facing `Research capacity` dashboard cards from Overview and Market pages; replaced with decision/current-work signals.
- Founder research observability remains unchanged.

## Performance hardening

- Primary app navigation now uses Next.js `Link` client navigation instead of full-document `<a href>` reloads.
- Product pipeline navigation also uses Next.js `Link`.
- Sidebar brand returns to `/app` using client navigation.
- Passive MarketRoute narration on Discovery / Overview / Campaign / Opportunity is now cache-first with deterministic conversational fallback and **does not block page render on an OpenAI request**.
- Explicit **Ask MarketRoute** opportunity Q&A still uses OpenAI and remains grounded/read-only.
- Application read service now exposes its internal commercial-access promise so Overview/Campaign/Opportunities can reuse the same entitlement projection instead of issuing duplicate commercial-access RPCs during one render.

## Validation

- RC hardening static: 12/12
- RC hardening adversarial: 9/9
- Build 15 core UI: 30/30
- Build 21 conversational intelligence: 16/16 + 9/9 adversarial
- Build 26 full product experience: 20/20 + 12/12 adversarial
- Build 18 release certification: 31/31
- Full red-team replay: 22/22
- Full `npm run production:check`: PASS
- TS/TSX syntax transpile: 206/206

## Deployment

1. Run `APPLY-IN-SUPABASE-MARKETROUTE-V2-RC-RESEARCH-EXECUTION-RECOVERY-OBSERVABILITY.sql` in Supabase.
2. Deploy the accompanying ZIP to Vercel.
3. No new environment variables are required.
4. Inspect the next `/api/cron/research` call. If it executes zero work, capture the JSON response or scheduler metadata including `queueDiagnostics`.
