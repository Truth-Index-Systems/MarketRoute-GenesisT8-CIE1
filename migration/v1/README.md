# MarketRoute V2 Build 17 — V1 factual/evidence migration

This directory is the only supported bridge from MarketRoute V1 into V2.

## Constitutional rule

**V1 factual data/evidence → audited one-way migration → V2.**

The bundle may contain company identities, people, contact channels, seller configuration source material, campaign definitions/scopes, source provenance, evidence, factual claims and historical research text.

It must not contain or preserve V1 commercial authority. The validator and database reject fields representing old scores, confidence, viability, READY state, R4/R5/R6, Truth percentages, route quality, approval authority or workflow state.

Campaign definitions are always imported as `DRAFT`. V1 evidence is always persisted with `extraction_method = MIGRATED`. No Truth snapshot, R4 record, R5 record, R6 record, opportunity state or engagement authority is imported.

After import, V2 must recompute its own chain from the evidence:

`evidence → V2 Truth → V2 R4 → V2 R5 → V2 R6`

## Workflow

1. Export V1 into `MRV2-V1-FACTUAL-EXPORT-1.0.0` JSON. The source system remains read-only.
2. Validate and dry-run locally:

   `npm run migration:v1:validate -- migration/v1/example.bundle.json`

   `npm run migration:v1:dry-run -- migration/v1/example.bundle.json`

3. Apply `APPLY-IN-SUPABASE-MARKETROUTE-V2-BUILD17.sql` to V2.
4. Set the four execution-only environment variables:

   - `MR_V2_SUPABASE_URL`
   - `MR_V2_SUPABASE_SERVICE_ROLE_KEY`
   - `MR_V2_MIGRATION_ORGANISATION_ID`
   - `MR_V2_MIGRATION_CREATED_BY_USER_ID`

5. Execute explicitly:

   `node scripts/migration/import-v1-bundle.mjs /path/to/export.json --execute`

By default the importer stops at the first rejected record. Fix the export and rerun the exact bundle. Successful mappings are immutable and idempotent, so already imported identities are not duplicated. `--allow-rejections` exists for forensic trial runs only; it should not be used for production cutover without reviewing the rejection report.

## Mapping

`marketroute_v1_migration_id_map` is append-only and records the source table, V1 id, V2 id and a database-computed fingerprint of the factual payload. A V1 identity cannot later be silently remapped to a different V2 identity or changed payload.

## No live dependency

The importer reads a static export file. It does not import V1 code, call V1 RPCs, query the V1 database from the V2 runtime, or install compatibility adapters.

## Concrete V1 exporter — Forensic Build 8 source profile

Build 17 is bound to the actual pre-V2 MarketRoute / Genesis T8 schema through migration `0158_marketroute_forensic_build8_constitutional_hardening.sql`.

The exporter is deliberately **GET-only** and uses a static table whitelist. It never calls a V1 RPC and never reads legacy Truth snapshots, CIE R4/R5/R6 decision tables, opportunity state, engagement authority or route topology.

Set:

- `MR_V1_SUPABASE_URL`
- `MR_V1_SUPABASE_SERVICE_ROLE_KEY`
- `MR_V1_ORGANISATION_ID`

Then export a static factual bundle:

`npm run migration:v1:export -- /secure/path/marketroute-v1-factual-export.json`

The exporter reads only the whitelisted source tables in `source-profile.forensic-build8.json`. It retains campaign-scoped company/contact evidence and the dense shared Genesis G8 source-evidence store. Legacy Genesis numeric evidence assessment fields, Truth snapshots and claim weighting are discarded. Legacy route-source evidence is retained only as source evidence attached back to the target company; no V1 route topology crosses the bridge.

After export, validate/dry-run the file and only then execute it against V2 using the workflow above.
