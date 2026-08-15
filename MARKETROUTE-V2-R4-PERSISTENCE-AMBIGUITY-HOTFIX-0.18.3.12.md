# MarketRoute V2 R4 persistence ambiguity hotfix — 0.18.3.12

The first live research run after `0.18.3.11` successfully persisted 12 plans, claimed a work unit, selected the seller context and persisted current entity Truth. It then reached the existing R4 authority writer and failed at its deduplication lookup.

## Root cause

`marketroute_persist_commercial_reality_r4_v1` returns a table column named `input_fingerprint`. Its existing-record query referenced the `commercial_reality_r4_records.input_fingerprint` column without a table alias. In PL/pgSQL, the output variable and stored column therefore had the same identifier, and PostgreSQL failed closed with an ambiguous-column error.

## Repair

- Replace the existing R4 writer in place.
- Qualify the R4 record table and every predicate in its input-fingerprint lookup.
- Preserve the function signature, deterministic context recomputation, boundary validation, fingerprints, validity window, reasoning lineage, authority events and writer identity exactly.
- R5 and R6 persistence were audited and already qualify their equivalent deduplication columns.
- Register no new authority writer.

The failed `REVALIDATE_R4` work unit was returned to `PENDING` with its normal retry delay and zero provider cost. No manual reset is required.

## Deployment

1. Apply `APPLY-IN-SUPABASE-MARKETROUTE-V2-0.18.3.12-R4-PERSISTENCE-AMBIGUITY-HOTFIX.sql` in Supabase SQL Editor.
2. Deploy the accompanying application ZIP.
3. Allow the next `/api/cron/research` run to retry the existing work unit.
