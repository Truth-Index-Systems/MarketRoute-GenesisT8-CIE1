# MarketRoute V2 campaign lifecycle controls — 0.18.3.10

This release adds owner/admin campaign controls to the campaign overview.

## Behaviour

- **Pause campaign** changes `ACTIVE` to `PAUSED`, disables the research policy and prevents Genesis from claiming new research work. A research task already in flight may finish safely.
- **Resume campaign** changes `PAUSED` to `ACTIVE` and restores the research-policy enabled state captured when the campaign was paused.
- **Delete campaign** requires the exact campaign name, GitHub-style. It performs an audited `ARCHIVED` transition rather than physical deletion.
- Archived campaigns disappear from normal campaign lists, while evidence, Truth snapshots, R4/R5/R6 authority, opportunities, engagement history and audit lineage remain retained.
- Pause and archive fail closed while an engagement delivery job is `RUNNING`.

Every lifecycle transition is recorded in the append-only `campaign_workflow_events` table with the acting user and prior/resulting state. The release adds no commercial-authority writer.

## Deployment

1. Apply `APPLY-IN-SUPABASE-MARKETROUTE-V2-0.18.3.10-CAMPAIGN-LIFECYCLE-CONTROLS.sql` in Supabase SQL Editor.
2. Deploy the application release.
3. Open an active campaign as a workspace owner or admin and verify pause, resume and typed-name delete.

The database migration must be applied before deploying the UI because the authenticated endpoint calls `marketroute_manage_campaign_v1`.
