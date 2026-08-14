# MarketRoute V2 — Production Hotfix 0.18.3.6

## Production symptom
Every `RESEARCH_ROUTES` action reached both graph-node writes, then failed in `marketroute_ensure_commercial_relationship_v1` with:

`null value in column "fingerprint_version" of relation "claims" violates not-null constraint`

## Root cause
Build 3 made `claims.fingerprint_version` mandatory. The Build 7 relationship RPC creates the canonical `relationship.exists` claim directly, but its insert still supplied only `claim_fingerprint` and omitted `fingerprint_version`. Core/company claims use `MRV2-CLAIM-FP-1.0.0`; the relationship claim must persist the same canonical claim-fingerprint semantics version.

## Fix
`marketroute_ensure_commercial_relationship_v1` now inserts:

`fingerprint_version = 'MRV2-CLAIM-FP-1.0.0'`

No relationship semantics, graph semantics, evidence semantics, Truth mathematics, planner policy, R4/R5/R6 authority, budgets, or cron cadence changed. No constraint was weakened.

## Deployment
1. Apply `APPLY-IN-SUPABASE-MARKETROUTE-V2-0.18.3.6-ROUTE-HOTFIX.sql`.
2. The database fix is live immediately; the next `RESEARCH_ROUTES` action can test it without waiting for a Vercel code change.
3. Deploy the 0.18.3.6 ZIP afterwards so the canonical repository/migration history matches production.
4. Verify `marketroute_ensure_commercial_relationship_v1` returns 2xx, followed by relationship evidence/Truth/stage-completion calls rather than `marketroute_growth_fail_action_v1`.

## Existing failed actions
No data cleanup is required. Failed route actions remain audit history and their paid costs remain accounted. The growth planner's retry/defer logic can revisit eligible companies after the repair.
