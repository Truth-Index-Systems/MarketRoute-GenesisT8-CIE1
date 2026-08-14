# MarketRoute V2 / Genesis T8 — Production Activation 0.18.1

This patch activates the frozen Build 18 architecture without adding a fourth commercial-authority writer. It is runtime/provider wiring, not a new reasoning build.

## What is now live-capable

- OpenAI Responses API is the production AI transport.
- Hosted OpenAI `web_search` is the research acquisition tool.
- Strict Structured Outputs are used for seller semantics, target hypotheses, research acquisition, outreach drafting and categorical self-review.
- Vercel Cron runs workspace bootstrap, Genesis research and optional engagement delivery.
- New workspace bootstrap collects an explicit commercial objective, target market and hard-constraint declaration before research begins.
- Resend is the initial EMAIL delivery adapter and has an explicit environment kill switch.
- A protected preflight endpoint checks environment readiness without returning secret values.
- A protected smoke endpoint performs a real V2 Supabase read and a minimal real OpenAI Responses request so deployed connectivity can be proven.

## Production deployment order

1. Apply `APPLY-IN-SUPABASE-MARKETROUTE-V2-PRODUCTION-ACTIVATION.sql` to the V2 Supabase project.
2. In Supabase Authentication, enable new-user signup and set the Site URL to the exact production MarketRoute URL. If confirmation emails are enabled, configure custom SMTP before launch.
3. In Vercel, add the environment contract from `.env.example`. Prefer current Supabase `sb_secret_*` and `sb_publishable_*` keys. Legacy `service_role` and `anon` keys remain supported as fallbacks.
4. Create a cryptographically random `CRON_SECRET` of at least 32 characters. Example: `openssl rand -hex 32`.
5. Add an OpenAI project API key with funded API access and set `OPENAI_MODEL=gpt-5.6-luna`.
6. Deploy on Vercel Pro or higher because this release schedules cron more frequently than once per day.
7. Keep `MARKETROUTE_DELIVERY_ENABLED=false` for the first deployment.
8. Call the protected environment preflight endpoint.
9. Call the protected live connectivity smoke endpoint. This incurs only a tiny OpenAI request and verifies that the production-activation SQL is present in V2 Supabase.
10. Create a brand-new test account and verify the complete bootstrap/research flow before enabling outbound delivery.
11. Verify the sending domain in Resend, set the Resend variables, send a controlled test, then change `MARKETROUTE_DELIVERY_ENABLED=true`.

## Required Vercel environment

Current Supabase key family, recommended:

```text
SUPABASE_URL=https://YOUR_V2_PROJECT_REF.supabase.co
SUPABASE_SECRET_KEY=sb_secret_...
SUPABASE_PUBLISHABLE_KEY=sb_publishable_...
OPENAI_API_KEY=sk-...
OPENAI_MODEL=gpt-5.6-luna
CRON_SECRET=<at-least-32-random-characters>
```

Legacy Supabase fallback, use instead of the two `sb_*` keys only if needed:

```text
SUPABASE_SERVICE_ROLE_KEY=eyJ...
SUPABASE_ANON_KEY=eyJ...
```

Do not expose the Supabase secret/service-role key or OpenAI key through `NEXT_PUBLIC_*` variables.

## Recommended explicit research governance

```text
MARKETROUTE_DEFAULT_DAILY_RESEARCH_BUDGET_USD=100
MARKETROUTE_DEFAULT_MAX_JOB_COST_USD=0.50
MARKETROUTE_DEFAULT_RESEARCH_CONCURRENCY=2
MARKETROUTE_DEFAULT_WORK_UNITS_PER_PLAN=4
MARKETROUTE_DEFAULT_REFRESH_HORIZON_HOURS=2
MARKETROUTE_BOOTSTRAP_TARGET_COUNT=12
MARKETROUTE_CRON_BOOTSTRAP_BATCH=2
MARKETROUTE_CRON_RESEARCH_PLANNING_TARGETS=50
MARKETROUTE_CRON_RESEARCH_WORK_EXECUTIONS=8
OPENAI_INPUT_USD_PER_MILLION=0.20
OPENAI_CACHED_INPUT_USD_PER_MILLION=0.02
OPENAI_OUTPUT_USD_PER_MILLION=1.20
OPENAI_WEB_SEARCH_USD_PER_CALL=0.01
OPENAI_REASONING_EFFORT=low
OPENAI_WEB_SEARCH_CONTEXT=medium
```

These values are already code defaults, but setting them explicitly in Vercel makes production behaviour visible and auditable.

## Optional outbound email

Keep disabled until domain verification and a controlled send test are complete:

```text
MARKETROUTE_DELIVERY_ENABLED=false
RESEND_API_KEY=re_...
MARKETROUTE_EMAIL_FROM=MarketRoute <outreach@YOUR-VERIFIED-DOMAIN>
MARKETROUTE_EMAIL_REPLY_TO=
MARKETROUTE_CRON_DELIVERY_BATCH=10
```

When ready, change only:

```text
MARKETROUTE_DELIVERY_ENABLED=true
```

## Cron schedule

`vercel.json` contains:

```text
/api/cron/bootstrap  */10 * * * *
/api/cron/research   */5 * * * *
/api/cron/delivery   */2 * * * *
```

Vercel supplies `Authorization: Bearer <CRON_SECRET>` to configured cron invocations. The application independently verifies that bearer value with a timing-safe comparison. Delivery cron is harmless while the delivery kill switch is false.

## Production verification endpoints

Environment-only preflight:

```bash
curl -sS -H "Authorization: Bearer $CRON_SECRET" \
  https://YOUR-PRODUCTION-DOMAIN/api/cron/preflight
```

Expected shape:

```json
{"ok":true,"missing":[],"deliveryEnabled":false,"openAIModel":"gpt-5.6-luna","supabaseKeyMode":"CURRENT"}
```

Real connectivity smoke:

```bash
curl -sS -H "Authorization: Bearer $CRON_SECRET" \
  https://YOUR-PRODUCTION-DOMAIN/api/cron/smoke
```

This proves two things from the deployed Vercel function: the V2 database contains the production-activation release marker, and the configured OpenAI key/model can successfully complete a strict Responses API request. It returns only non-secret status metadata.

## New-user operational flow

Public website → product example → signup → organisation + company website → commercial brief → workspace activation queue → seller genome → initial active campaign → target hypotheses → Genesis research cron → evidence → Truth → R4 → R5 → R6 → opportunity → human review → OpenAI outreach draft → human message approval → queue → send-time authority recheck → optional Resend delivery.

## Offline-only variables

Build 17 migration and Build 18 live-certification variables are intentionally not part of the Vercel runtime. Variables beginning with `MR_V1_`, `MR_V2_MIGRATION_` and `MARKETROUTE_CERT_` belong only in the controlled migration/certification shell when those procedures are run.

## Constitutional boundary

OpenAI produces semantics, evidence candidates, research hypotheses and language. It never grants Truth probability, R4/R5/R6 authority, opportunity authority, workflow approval or execution permission. Web content is explicitly treated as untrusted evidence rather than model instructions. Every discovered company/domain and evidence URL must be grounded to sources actually returned by the hosted search call before persistence. Engagement delivery remains behind both the deterministic send-time authority check and the environment kill switch.
