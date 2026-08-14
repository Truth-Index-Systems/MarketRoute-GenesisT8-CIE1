# MarketRoute V2 — Genesis Database Growth 0.18.3

## Purpose

Make the shared Genesis intelligence bank the primary pre-launch workload. This activation is independent of customer campaigns and creates no new commercial-authority writer.

## Canonical industries

1. Software & SaaS
2. Professional Services
3. Marketing & Advertising
4. Recruitment & HR
5. Finance & FinTech
6. Healthcare & HealthTech
7. Retail & E-commerce
8. Manufacturing
9. Logistics & Supply Chain
10. Construction & PropTech

## Deterministic growth policy

- **SEED** — balance every industry to 50 companies.
- **BREADTH** — balance every industry toward 500 companies.
- **DEPTH** — once breadth reaches 5,000 companies, deepen core/profile, routes and contacts.
- **REFRESH** — when density is complete, revisit the oldest intelligence.

The database chooses what needs work. OpenAI does not rank industries, calculate Truth, create R4/R5/R6 authority, or grant execution permission.

## Research density telemetry

Density is operational completeness, not belief probability:

- 20% — company is in the canonical industry bank
- +20% — core company evidence complete
- +20% — wider company profile complete
- +20% — evidenced routes complete
- +20% — evidenced named-contact/channel binding complete

The founder dashboard therefore reports counts at >=80% and 100% without presenting those numbers as Truth probability.

## Runtime

`GET /api/cron/growth` runs every two minutes under the same `CRON_SECRET` protection as the other production crons.

Default controls (all optional Vercel overrides):

- `MARKETROUTE_GROWTH_ENABLED=true`
- `MARKETROUTE_GROWTH_DAILY_BUDGET_USD=100`
- `MARKETROUTE_GROWTH_MAX_ACTION_COST_USD=0.50`
- `MARKETROUTE_GROWTH_SEED_TARGET_PER_INDUSTRY=50`
- `MARKETROUTE_GROWTH_LAUNCH_TARGET_PER_INDUSTRY=500`
- `MARKETROUTE_GROWTH_DISCOVERY_BATCH=10`
- `MARKETROUTE_CRON_GROWTH_ACTIONS=1`
- `MARKETROUTE_GROWTH_RETRY_HOURS=24`
- `MARKETROUTE_GROWTH_REFRESH_DAYS=30`

Existing OpenAI, Supabase, cron and founder-dashboard environment variables remain unchanged.

## Data ownership

Growth writes global canonical companies, global evidence/claims/Truth snapshots, global relationship evidence and global contact evidence. Campaigns can later consume this shared factual substrate. R4/R5/R6 remain campaign-specific deterministic authorities.
