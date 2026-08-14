# MarketRoute V2

Constitutional rebuild of MarketRoute.

## Current release

**Build 18 — Red-Team Certification & Production Cutover + Production Activation 0.18.1**

MarketRoute V2 / Genesis T8 remains a **source-frozen production candidate**. Production Activation 0.18.1 wires the already-frozen provider/runtime boundaries to OpenAI Responses + web search, Vercel Cron and optional Resend delivery. It adds one isolated operational migration (`0020_production_activation_runtime.sql`) for new-workspace activation and adds no commercial-authority writer.

The authority writer set remains exactly three: **R4 Commercial Reality, R5 Route Authority and R6 Contact Authority**. AI owns semantics and language, not authority. The UI consumes canonical application reads and never reconstructs commercial decisions.

Run:

```text
npm run constitution:check
npm run certification:cutover-preflight
npm run production:check
```

After the Build 17 evidence migration and V2 recomputation, run the real-company proof with `npm run certification:live-lineage`. See `MARKETROUTE-V2-BUILD18-RED-TEAM-CERTIFICATION.md` and `PRODUCTION-CUTOVER-BUILD18.md`.

### Required server environment

Prefer current Supabase keys:

```text
SUPABASE_URL=
SUPABASE_SECRET_KEY=
SUPABASE_PUBLISHABLE_KEY=
OPENAI_API_KEY=
OPENAI_MODEL=gpt-5.6-luna
CRON_SECRET=
```

Legacy `SUPABASE_SERVICE_ROLE_KEY` + `SUPABASE_ANON_KEY` remain supported. No secret is exposed through `NEXT_PUBLIC_*`. See `PRODUCTION-ACTIVATION.md` for the complete Vercel, cron, OpenAI, Resend and smoke-test procedure.

## Build 17 — V1 evidence migration

Build 17 adds an offline, service-role-only V1 → V2 factual/evidence ETL. Use `migration/v1/README.md` for the export contract and migration workflow. No V1 authority, Truth state, scoring or workflow state is imported; V2 recomputes downstream intelligence from migrated evidence.

### Build 17 source export

For the pre-V2 Forensic Build 8 database, generate the static one-way factual export with `npm run migration:v1:export -- /secure/path/v1-export.json`. The exporter is GET-only and source-profile pinned; see `migration/v1/README.md`.


## Production growth activation

0.18.3 adds the V2-native Genesis Database Growth worker. It builds the shared global intelligence bank across the ten canonical industries independently of customer campaigns. See `MARKETROUTE-V2-GENESIS-DATABASE-GROWTH-0.18.3.md`.
