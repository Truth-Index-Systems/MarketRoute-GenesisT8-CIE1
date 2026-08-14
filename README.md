# MarketRoute V2

Constitutional rebuild of MarketRoute.

## Current build

**Build 18 — Red-Team Certification & Production Cutover**

MarketRoute V2 / Genesis T8 is now a **source-frozen production candidate**. Build 18 adds no feature, authority writer or Supabase migration. It certifies the Build 17 repository, replays the complete Build 1–17 constitutional programme, adds a cross-cutting final red-team gate, and supplies the production lineage/cutover tools.

The authority writer set remains exactly three: **R4 Commercial Reality, R5 Route Authority and R6 Contact Authority**. AI owns semantics and language, not authority. The UI consumes canonical application reads and never reconstructs commercial decisions.

Run:

```text
npm run constitution:check
npm run certification:cutover-preflight
```

After the Build 17 evidence migration and V2 recomputation, run the real-company proof with `npm run certification:live-lineage`. See `MARKETROUTE-V2-BUILD18-RED-TEAM-CERTIFICATION.md` and `PRODUCTION-CUTOVER-BUILD18.md`.

### Required server environment

```text
SUPABASE_URL=
SUPABASE_SERVICE_ROLE_KEY=
SUPABASE_ANON_KEY=
```

The service-role key remains server-only.

## Build 17 — V1 evidence migration

Build 17 adds an offline, service-role-only V1 → V2 factual/evidence ETL. Use `migration/v1/README.md` for the export contract and migration workflow. No V1 authority, Truth state, scoring or workflow state is imported; V2 recomputes downstream intelligence from migrated evidence.

### Build 17 source export

For the pre-V2 Forensic Build 8 database, generate the static one-way factual export with `npm run migration:v1:export -- /secure/path/v1-export.json`. The exporter is GET-only and source-profile pinned; see `migration/v1/README.md`.
