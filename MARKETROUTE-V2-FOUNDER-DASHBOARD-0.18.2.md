# MarketRoute V2 — Founder Operations Dashboard 0.18.2

Private production observability surface at `/dashboard`.

## Purpose

Answer, from persisted production state:

1. Is every MarketRoute stage alive?
2. How much data has each stage produced?
3. Where is work queued, blocked or failing?
4. What is Genesis/OpenAI spending?
5. Are Vercel cron workers actually firing?

## Security

The founder dashboard is separate from customer authentication. It requires:

- `FOUNDER_DASHBOARD_PASSWORD` — minimum 12 characters; use a long unique password.
- `FOUNDER_DASHBOARD_SESSION_SECRET` — minimum 32 random characters.

Authentication uses timing-safe password comparison and an HMAC-signed, HTTP-only, SameSite=Strict session cookie. The dashboard data is rendered server-side. No Supabase service key or dashboard dataset is exposed to browser JavaScript.

## Observability

Migration `0021_founder_dashboard_observability.sql` adds an append-only production runtime event ledger and a service-role-only aggregate snapshot RPC. It is observability only and adds no authority writer.

The scheduled Vercel runtimes record STARTED and SUCCEEDED/FAILED/DISABLED events for:

- Bootstrap — every 10 minutes
- Research — every 5 minutes
- Delivery — every 2 minutes

Preflight and smoke calls are also observed.

## Dashboard stages

Workspace activation → Company discovery → Genesis research → Evidence → Truth → R4 → R5 → R6 → Opportunity → Engagement → Delivery.

Each stage shows a persisted output count, supporting data volume, last activity and an operational state. A zero does not automatically mean failure; the dashboard distinguishes waiting-for-upstream-data from persisted failure.

## Production deployment

Apply `APPLY-IN-SUPABASE-MARKETROUTE-V2-FOUNDER-DASHBOARD.sql`, add the two founder environment variables, then deploy package 0.18.2.
