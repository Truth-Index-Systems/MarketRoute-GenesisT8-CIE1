# MarketRoute V2 RC — Engagement Currentness + Billing Legacy UX Hotfix

## Fixes

### Engagement
`evaluatedAt` was part of the generation-context fingerprint. A strategy created at time A
was therefore considered stale when the message was persisted/reviewed at time B, even
when R4/R5/R6, the route, access point and seller context were unchanged.

Migration 0054 removes only `evaluatedAt` from the generation-context fingerprint.
Authority/currentness inputs remain enforced.

Existing strategies created with the old fingerprint are intentionally allowed to become
stale; pressing Prepare message creates a fresh strategy under the corrected fingerprint.

### Plan & Billing
A dark commercial-modal style override leaked onto the light billing page, making
`Legacy full access` almost unreadable. The override is now scoped to the modal.

Migration-only `LEGACY_FULL` workspaces now see the public Starter/Growth/Scale catalogue
as well as their current-access card. Grandfathered access remains active unless checkout
completes. Completing checkout replaces the legacy entitlement through the existing
signed Stripe reconciliation path.

The server rejects a selected plan if its active-market allowance is below the
workspace's current non-archived campaign count.

## No new environment variables
Engagement continues to use `OPENAI_API_KEY` and `OPENAI_MODEL`. Autonomous delivery
remains disabled.

## Deployment
1. Run `APPLY-IN-SUPABASE-MARKETROUTE-V2-RC-ENGAGEMENT-CURRENTNESS-BILLING-LEGACY-HOTFIX.sql`.
2. Deploy this repository.
3. Retry Prepare message. A new strategy should remain current across generation/review.
4. Visit Plan & Billing. Legacy full access should be readable and standard plans visible.
