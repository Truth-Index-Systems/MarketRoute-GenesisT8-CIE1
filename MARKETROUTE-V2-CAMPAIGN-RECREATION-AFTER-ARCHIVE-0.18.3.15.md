# MarketRoute V2 — Campaign recreation after archive 0.18.3.15

## Outcome

An owner or admin can now start a fresh campaign after the prior campaign has been deleted from normal views. Delete remains an audited archive operation: the old campaign, evidence and authority lineage are neither restored nor physically removed.

## Product flow

1. Archive the existing campaign using the exact-name confirmation.
2. Open **Campaigns** and choose **Start new campaign**.
3. Name the new campaign and submit its commercial brief.
4. Genesis prepares a separate campaign during the next bootstrap run.

The creation route is shown only when the workspace has no non-archived campaign. The database repeats this guard under an organisation-row lock, so a forged or racing request cannot create a second live campaign.

## Deployment order

1. Run `APPLY-IN-SUPABASE-MARKETROUTE-V2-0.18.3.15-CAMPAIGN-RECREATION-AFTER-ARCHIVE.sql` in Supabase.
2. Deploy this application build to Vercel.
3. Archive the old campaign if it is not already archived.
4. Submit the new campaign brief in the app.
5. Run or wait for `/api/cron/bootstrap`.

The SQL retains the V1 worker function during migration-first rollout. The updated worker uses the V3 activation claim and V2 campaign creator so the user-supplied campaign name crosses the queue boundary.

## Security and lineage

- Authenticated owner/admin required in both the route and PostgreSQL.
- Same-origin POST required.
- Zero live campaigns required.
- A non-expired running activation lease cannot be overwritten.
- Archived campaign rows are never updated or deleted.
- No Truth, R4, R5, R6, opportunity, engagement or execution authority writer is added.
