# MarketRoute V2 — R6 reasoning-kind hotfix 0.18.3.19

## Production fault

The R6 persistence writer attempted to insert the undeclared reasoning kind `CONTACT_TRUTH_AUTHORITY`. The finite `reasoning_runs` constraint correctly permits the canonical Build 8 kind `CONTACT_TRUTH`, so the insert failed before any R6 authority record was created.

## Repair

- Changes only the R6 reasoning-run classification from `CONTACT_TRUTH_AUTHORITY` to `CONTACT_TRUTH`.
- Leaves the finite database constraint unchanged and verifies that it still permits `CONTACT_TRUTH` but not the redundant value.
- Preserves R6 decisions, evidence, fingerprints, validity, parent R5 authority checks, and the sole R6 authority writer.
- Requeues only `REVALIDATE_R6` work carrying this exact constraint failure.

## Deployment order

1. Run `APPLY-IN-SUPABASE-MARKETROUTE-V2-0.18.3.19-R6-REASONING-KIND-HOTFIX.sql` in Supabase.
2. Deploy the matching Vercel package to keep the source release aligned.
3. Allow the next research cron to retry the repaired R6 work automatically.
