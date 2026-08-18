# MarketRoute V2 — Build 25 Icon Type Hotfix

## Issue
Vercel production compilation failed in `app/app/plans/page.tsx` because the billing alert UI used `Icon name="warning"`, while `warning` was not part of the frozen `IconName` union in `ui/icons.tsx`.

## Fix
- Added `warning` to `IconName`.
- Added a matching warning-triangle SVG path to the shared icon registry.
- Kept the billing page semantics unchanged.
- Scanned all literal `<Icon name="...">` uses against the union: zero invalid icon literals remain.

## Validation
- TS/TSX transpilation: 196/196
- Product Build 25 billing static gate: 17/17
- Product Build 24 commercial-boundary regression: 20/20

## Deployment
No Supabase SQL changes.
No environment-variable changes.
Redeploy this ZIP over the existing Build 25 deployment.
