# MarketRoute V2 — Persistent campaign activation progress UI 0.18.3.16

## Outcome

Campaign preparation no longer looks as though it vanished when the user leaves or refreshes the page. Its state is persisted on the workspace activation job, read through an authenticated RPC and rendered on both the Command Centre and Campaigns pages.

## Visible preparation stages

1. Brief saved
2. Seller context
3. Campaign structure
4. Genesis targets
5. Company scope
6. Ready for research

The UI automatically refreshes while work is queued or running. Detailed worker stages include seller analysis, campaign creation, bank selection, optional web discovery, company-link progress and finalisation. A retryable failure remains visible as a scheduled retry instead of reverting to an empty campaign screen.

## Draft persistence

The new-campaign form saves its draft on the current device. Navigating away and returning restores the campaign name, offering, objective, target market and constraint choice. The draft is cleared once the server confirms that campaign preparation is persisted.

## Deployment order

1. Ensure migration `0035_campaign_recreation_after_archive.sql` is already applied.
2. Run `APPLY-IN-SUPABASE-MARKETROUTE-V2-0.18.3.16-CAMPAIGN-ACTIVATION-PROGRESS-UI.sql` in Supabase.
3. Deploy this application build to Vercel.
4. Submit a campaign brief and revisit either `/app` or `/app/campaigns` to verify persistent progress.

## Boundaries

- Intermediate stages can be written only by the service-role worker holding the live activation lease.
- Status can be read only by authenticated members of the matching workspace.
- Campaign, evidence and authority semantics are unchanged.
- No Truth, R4, R5, R6, opportunity, engagement or execution authority writer is added.
