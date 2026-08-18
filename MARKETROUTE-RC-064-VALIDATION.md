# MarketRoute RC 0.64 — Validation Record

## Canonical certification

`npm run production:check`

- exit code: 0
- PASS assertions: 2,723
- FAIL assertions: 0

## RC 0.64 dedicated gates

Static hardening gate: **13 / 13 PASS**

Adversarial hardening gate: **10 / 10 PASS**

Covered invariants include:

- 8 unlocked + 2 current ready opportunities -> exactly 2 locked teasers;
- stale materialised authority sync cannot become a locked teaser;
- research/non-ready rows cannot become locked teasers;
- the commercial teaser boundary cannot exceed two;
- commercial/refill list projections do not invoke the exact per-row authority graph;
- R4/R5/R6 lineage and revocation checks remain inherited from the migration-0058 materialised projection;
- migration 0063 cannot write authority or grant engagement execution;
- Discovery commercial visibility remains original-campaign scoped;
- bootstrap claim-time failures are classified;
- release certification advances explicitly through migration 0063.

## TypeScript syntax/transpile check

Changed `application/production/bootstrap.ts` was transpiled with TypeScript 5.8.3 using `transpileModule`.

- syntax/transpile errors: 0

## SQL limitation

The validation environment does not contain the production Supabase database, so migration 0063 has not been executed here against the live schema. The canonical source/adversarial gates pass and the deployable SQL is byte-for-byte identical to the migration. Supabase execution remains the database integration gate.

## Next production observation

After deployment, verify:

1. `/api/cron/bootstrap` completes without `57014` during Discovery/refill checks;
2. `marketroute_workspace_commercial_access_v1` no longer produces statement-timeout logs;
3. once eight free opportunities are unlocked and two additional current ready opportunities exist, `lockedCount=2` and two `READY_LOCKED` teaser records are returned;
4. opening a locked teaser still shows only the locked commercial page and cannot reach full company/route/contact intelligence;
5. after payment, the same opportunities become readable through the existing paid entitlement path without rerunning authority.
