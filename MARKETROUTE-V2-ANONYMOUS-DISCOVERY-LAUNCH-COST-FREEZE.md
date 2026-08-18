# MarketRoute V2 — Anonymous Discovery Launch Cost Freeze

Date: 2026-08-18
Baseline: Build 26 Full Product Experience + Research Capacity Type Hotfix + Research Queue Fairness Hotfix
Migration: `0048_anonymous_discovery_launch_cost_freeze.sql`

## Frozen launch policy

Anonymous Discovery is now bounded by a defence-in-depth server policy:

- Permanent free opportunity unlocks: **8**
- Anonymous target-company ceiling: **10**
- Maximum locked teasers before payment: **2**
- Lifetime anonymous AI research budget: **USD 1.00**
- Anonymous research window: **12 hours**
- Anonymous research concurrency remains **1**
- Existing one-run-per-browser and coarse network abuse controls remain unchanged

The application and database both enforce the ceilings. Vercel environment values may lower the limits for an emergency cost reduction, but cannot raise them above 10 / USD 1 / 12h.

## Existing runs

Applying the migration tightens `ACTIVE` and `CLAIMED` anonymous runs to the new ceilings. Existing evidence, company scope, opportunities and lineage are preserved; the patch does not delete acquired intelligence.

For historical runs that already scoped more than ten companies, the Discovery-free commercial projection returns at most two locked teasers. A verified paid entitlement still unlocks all legitimately ready opportunities.

## Authority boundary

This patch is product-cost and access orchestration only. It does not create or modify Truth, R4, R5, R6, CIE, opportunity authority, claims or evidence semantics. Growth remains paused and autonomous delivery remains off.

## Environment

Recommended production values:

```text
MARKETROUTE_ANONYMOUS_RESEARCH_BUDGET_USD=1
MARKETROUTE_ANONYMOUS_RESEARCH_WINDOW_HOURS=12
MARKETROUTE_ANONYMOUS_TARGET_COUNT=10
```

No new environment variables are introduced. Higher stale values are still clamped by application code and Supabase after this patch, but updating Vercel keeps configuration truthful.

## Deployment

1. Apply `APPLY-IN-SUPABASE-MARKETROUTE-V2-ANONYMOUS-DISCOVERY-LAUNCH-COST-FREEZE.sql` in Supabase.
2. Deploy the repository ZIP.
3. Update the three Vercel values above if they still contain the prior 3 / 24 / 12 configuration.
4. Start one fresh anonymous Discovery in a new browser identity and verify its persisted policy is 1 / 12h / 10.
5. Verify the claimed free workspace never exposes more than two locked teasers.

## Validation

- Anonymous launch freeze static: 10/10
- Anonymous launch freeze adversarial: 10/10
- Product Build 20 anonymous Discovery: 24/24 + 8/8
- Product Build 23 free eight/account claim: 17/17 + 9/9
- Product Build 24 commercial boundary: 20/20 + 11/11
- Research queue fairness: 15/15 + 9/9
- Build 18 release certification: 30/30
- Full `npm run production:check`: PASS
