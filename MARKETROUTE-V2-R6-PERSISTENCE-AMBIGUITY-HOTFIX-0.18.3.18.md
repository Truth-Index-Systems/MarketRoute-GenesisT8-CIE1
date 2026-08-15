# MarketRoute V2 — R6 persistence ambiguity hotfix 0.18.3.18

## Production fault

`marketroute_persist_contact_authority_r6_v1` returns a table containing a field named `authority_record_id`. Its lookup of the parent R5 authority used the same name without a table alias, so PostgreSQL could not distinguish the return variable from the database column.

Production error:

`column reference "authority_record_id" is ambiguous`

## Repair

- Qualifies the parent R5 lookup as `r.authority_record_id`.
- Replaces the existing R6 authority writer in place; it does not create another authority writer.
- Fails closed if the deployed function differs from the expected source.
- Preserves all R6 decisions, fingerprints, validity, Truth checks, and parent-authority checks.
- Requeues only `REVALIDATE_R6` jobs whose last error exactly matches this ambiguity, including jobs that had exhausted five attempts.

## Deployment order

1. Run `APPLY-IN-SUPABASE-MARKETROUTE-V2-0.18.3.18-R6-PERSISTENCE-AMBIGUITY-HOTFIX.sql` in Supabase.
2. Deploy the matching Vercel package.
3. Allow the next `/api/cron/research` run to process the requeued R6 work.
