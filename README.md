# MarketRoute V2

Constitutional rebuild of MarketRoute.

## Current build

**Build 15 — Core Application UI**

Build 15 turns the Build-14 blue application shell into the first live MarketRoute product surface. The intelligence architecture remains unchanged: exactly three authority writers exist — **R4 Commercial Reality, R5 Route Authority and R6 Contact Authority**. The UI consumes the canonical Build-13 application read contract and does not reconstruct Truth, authority or execution state.

Live product routes:

- `/app` — Founder Command Centre
- `/app/campaigns` — campaign intelligence
- `/app/companies` — company intelligence index
- `/app/opportunities` — opportunity workspace index
- `/app/opportunities/[campaignId]/[companyId]` — flagship Opportunity Workspace
- `/app/research` — Genesis research operations
- `/app/engagement` — engagement state and delivery pipeline
- `/login` — server-mediated Supabase Auth sign-in
- `/onboarding` — first-workspace creation for authenticated users without an organisation

Build 15 adds migration `0017_core_application_ui_read_indexes.sql`. It introduces **read-only, service-role-only** application indexes for company lists, research activity, engagement lists, route display and provenance claim discovery. It does not add an authority writer or mutate Truth, R4/R5/R6, workflow, research or engagement.

### Required server environment

```text
SUPABASE_URL=
SUPABASE_SERVICE_ROLE_KEY=
SUPABASE_ANON_KEY=
```

`NEXT_PUBLIC_SUPABASE_ANON_KEY` may be used as the anon-key fallback, but the application itself keeps authentication server-mediated. The service-role key is never sent to browser code.

Build 15 expects an existing Supabase Auth user. Public signup/acquisition belongs to Build 16.

Primary MarketRoute colours remain `#2F8CFF` and `#76B6FF` on the near-black `#05080D` workspace.

## Build 17 — V1 evidence migration

Build 17 adds an offline, service-role-only V1 → V2 factual/evidence ETL. Use `migration/v1/README.md` for the export contract and migration workflow. No V1 authority, Truth state, scoring or workflow state is imported; V2 recomputes downstream intelligence from migrated evidence.

### Build 17 source export

For the pre-V2 Forensic Build 8 database, generate the static one-way factual export with `npm run migration:v1:export -- /secure/path/v1-export.json`. The exporter is GET-only and source-profile pinned; see `migration/v1/README.md`.
