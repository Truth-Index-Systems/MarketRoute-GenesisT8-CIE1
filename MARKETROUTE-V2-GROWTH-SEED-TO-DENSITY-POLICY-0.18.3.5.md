# MarketRoute V2 — Growth Seed-to-Density Policy 0.18.3.5

## Scope
This is a production-policy correction only. It does not change the constitutional architecture, Truth mathematics, evidence semantics, OpenAI provider contracts, R4/R5/R6 authority, budgets, or cron cadence.

## Why it exists
Production demonstrated that the previous deterministic planner stayed breadth-first until all 10 industries reached 500 companies. That meant PROFILE, ROUTES, and CONTACTS would normally not run until roughly 5,000 companies existed.

## New deterministic policy
1. **SEED** — continue balanced discovery until every enabled industry reaches its configured seed floor (default 50).
2. **DEPTH** — once every industry reaches the seed floor, eligible incomplete companies outrank additional breadth.
3. Companies advance in prerequisite order: **CORE/PROFILE → ROUTES → CONTACTS**.
4. Within DEPTH, the most advanced eligible company is selected first so later stages become observable quickly and a company can reach 100% density before moving on.
5. If incomplete work is deferred by `retry_after`, it does not block expansion.
6. **BREADTH** — when all currently eligible companies are dense or deferred, Genesis buys the next balanced discovery batch toward 500 per industry.
7. The new batch is then deepened before the next breadth batch.
8. **REFRESH** remains unchanged after launch breadth and current depth are complete/deferred.

## Expected production effect
At the current pre-launch trajectory, Routes and Contacts should begin shortly after all ten industries reach 50 companies each (about 500 shared companies total), rather than waiting for the full 5,000-company launch breadth target.

After that, expansion becomes a rolling dense-bank loop:

`discover batch → profile → routes → contacts → next discovery batch`

Retries remain fail-closed and budget-governed.

## Files
- `supabase/migrations/0025_growth_seed_to_density_policy.sql`
- `APPLY-IN-SUPABASE-MARKETROUTE-V2-0.18.3.5-SEED-TO-DENSITY.sql`
- `scripts/validate-growth-seed-to-density-policy-01835.mjs`

## Deployment
Apply the SQL migration to the V2 Supabase project first. The planner and dashboard read model change immediately. Deploy the ZIP afterwards so the canonical repository matches production.

## Rollback
If production selection behaves unexpectedly, run `ROLLBACK-MARKETROUTE-V2-0.18.3.5-SEED-TO-DENSITY.sql`. It restores the exact previous planner/read-model functions without deleting or mutating accumulated intelligence.
