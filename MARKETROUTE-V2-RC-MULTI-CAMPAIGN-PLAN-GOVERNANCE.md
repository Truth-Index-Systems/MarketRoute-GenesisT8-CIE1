# MarketRoute V2 RC — Multi-Campaign Plan Governance

## Launch commercial policy

- Discovery: one original Discovery market only; additional campaigns require paid capacity.
- Starter (£99/mo): 1 live campaign.
- Growth (£249/mo): up to 3 live campaigns.
- Scale (£599/mo): up to 10 live campaigns.
- Paused campaigns consume an active-market slot. Archived campaigns do not.

## Add campaign experience

`Add campaign` is always visible to workspace owners/admins, regardless of plan or current campaign count.

Opening Add campaign always presents the full campaign configuration first. The customer configures the new market brief before MarketRoute applies the commercial capacity decision.

At submit time:

- If the current plan has room, MarketRoute starts a distinct new campaign.
- If the new campaign would exceed the plan allowance, MarketRoute shows the upgrade boundary.
- The upgrade surface only offers plans whose active-market limit can actually accommodate the additional campaign.
- Existing paid subscribers are sent to Stripe Customer Portal to change plan rather than creating a duplicate subscription.
- The configured draft remains locally preserved when the paywall opens.

Examples:

- Starter with one live market -> Add campaign remains visible -> configure market #2 -> Growth/Scale upgrade boundary.
- Growth with two live markets -> market #3 can start.
- Growth with three live markets -> configure market #4 -> Scale upgrade boundary.
- Scale with ten live markets -> archive an existing market or contact support.

## Campaign lifecycle correction

New campaigns no longer reuse or mutate an existing campaign record. Activation creates a distinct campaign row tied to the activation job.

A named additional campaign that needs more input remains inside the Campaigns experience and no longer redirects the entire workspace into initial setup.

## Immutable Discovery lineage

Anonymous Discovery now persists its original campaign ID and original objective/target-market brief on the Discovery run itself.

Continuation always follows that exact original campaign. It never searches for another currently active campaign and can never jump onto a later paid campaign.

If the original Discovery campaign is archived, any remaining free continuation is terminally closed. Starting a new paid campaign does not revive or inherit the free Discovery envelope.

Paid campaign activation is explicitly excluded from anonymous Discovery policy even if the workspace originated from a claimed Discovery run.

## Authority boundary

This release is commercial/product orchestration only.

It does not create a new authority writer and does not modify Truth, CIE/UDOSIB, R4, R5, R6, evidence authority, opportunity authority, or assisted-engagement authority semantics.

## Deployment

1. Apply `APPLY-IN-SUPABASE-MARKETROUTE-V2-RC-MULTI-CAMPAIGN-PLAN-GOVERNANCE.sql` in Supabase.
2. Deploy the aligned repository ZIP.
3. No new environment variables are required.
4. Stripe Customer Portal should continue to allow subscription changes between Starter, Growth and Scale.

## Certification

- Multi-campaign static gate: 21/21.
- Multi-campaign adversarial gate: 16/16.
- Build 18 release certification: 35/35.
- Full red-team replay: 22/22.
- TypeScript/TSX syntax transpilation: 208/208.
- Complete `npm run production:check`: PASS.
