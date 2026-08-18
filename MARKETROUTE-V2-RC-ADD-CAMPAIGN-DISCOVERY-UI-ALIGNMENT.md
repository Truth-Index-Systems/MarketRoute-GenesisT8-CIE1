# MarketRoute V2 RC — Add Campaign Discovery UI Alignment

## Purpose

Align authenticated **Add campaign** with the public MarketRoute Discovery entry experience while preserving the modern multi-campaign activation, plan gating, research and authority architecture.

## Product changes

- Replaces the legacy `mr-login__form` / generic setup-panel presentation on `/app/campaigns/new`.
- Uses the same light, focused MarketRoute brief-card language and visual treatment as `/discover`.
- Default campaign brief now asks:
  1. Campaign name
  2. What do you sell?
  3. Who do you want to sell to?
  4. What do you want MarketRoute to achieve?
- Hard commercial constraints are optional and hidden behind **Add hard limits** until needed.
- Constraint policy remains explicit: hidden `constraintMode=NONE` by default; enabling hard limits sends `DESCRIBED` and requires constraint text.
- Removes the customer-facing artificial `100 active-market slots` display for grandfathered FULL workspaces.
- Grandfathered workspaces instead receive deliberate full-access copy.
- Add Campaign still saves the brief locally and only enforces campaign capacity at the final start action.
- Paywall and existing Stripe / plan transition logic are unchanged.

## Architecture preserved

- Form still posts to `/api/campaigns`.
- Server still owns OWNER/ADMIN authorization.
- Server still owns plan/campaign-capacity enforcement.
- Campaign activation continues through the modern immutable activation-lineage architecture.
- No Truth, R4, R5, R6, opportunity-authority or Engagement changes.
- No autonomous delivery changes.

## Deployment

No Supabase migration is required.
No environment-variable changes are required.
Deploy the repository normally through Vercel.

## Validation

- Add Campaign UI static gate: 9/9
- Add Campaign adversarial gate: 10/10
- Multi-campaign governance: 21/21 + 16/16
- Campaign activation lineage: 18/18 + 13/13
- Build 15 live UI: 30/30 + 18/18
- Anonymous Discovery: 24/24 + 8/8
- Product Build 26: 20/20 + 12/12
- Stripe mode hotfix: 7/7 + 8/8
- TS/TSX syntax sweep: 175/175
- Full `npm run production:check`: PASS
