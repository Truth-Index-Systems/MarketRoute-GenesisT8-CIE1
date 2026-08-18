# MarketRoute V2 RC — Ready Quota + Public SSR Hardening

## What was wrong
Two launch-blocking behaviours were present in the RC ZIP.

1. Anonymous Discovery treated `target_count = 10` as a **scoped-company ceiling**. Once 10 companies were linked, the continuation job could report success even if only five of those companies ever became current, authority-ready opportunities. That directly conflicts with the product promise: the first 8 qualifying opportunities are free and the next 2 are the locked commercial teaser.
2. The public home page and `/pricing` synchronously depended on the Supabase public-plan RPC during server rendering. A transient RPC/configuration failure therefore escaped the React server component and produced the generic Next.js “Application error: a server-side exception has occurred” page.

## What changed
### Anonymous Discovery completion semantics
The Discovery target is now interpreted as **10 authority-ready opportunities**, using the same predicate already used by free unlock allocation:

- opportunity state is `REVIEWABLE`, `APPROVED`, or `ENGAGED`; and
- `marketroute_authority_ready_v1(...)` is true at the current time.

If 10 companies were researched and only 5 became ready, the remaining ready deficit is 5 and the bootstrap extension becomes eligible after the current research cycle gate is satisfied.

The extension deliberately oversamples the deficit (up to one additional 10-company batch at a time) because candidate attrition is expected. The candidate pool is hard-capped at 40 scoped companies, extension attempts remain capped at 3, the 12-hour run window remains in force, and the existing anonymous research budget remains authoritative.

Pre-v3 extension jobs that were incorrectly marked `SUCCEEDED` or `EXHAUSTED` under the old scoped-count completion rule can be re-armed once.

### Public server-render fail-soft behaviour
The public plan catalogue still comes from Supabase when available. If that read fails, public acquisition pages render the frozen launch catalogue server-side instead of throwing a whole-page 500.

This fallback is **not** used for authenticated commercial entitlement checks. Paid/free access control continues to fail closed against the database.

## Authority boundaries retained
- No Truth writer added.
- No R4 writer added.
- No R5 writer added.
- No R6 writer added.
- No opportunity-ranking rule added.
- Paid conversion still stops the anonymous refill loop.
- Original anonymous campaign lineage remains mandatory.
- Autonomous delivery remains disabled.

## Deployment order
1. Apply `APPLY-IN-SUPABASE-MARKETROUTE-V2-RC-ANONYMOUS-DISCOVERY-READY-QUOTA-SSR-HARDENING.sql` in Supabase.
2. Deploy the aligned repository ZIP to Vercel.
3. Trigger/allow `/api/cron/bootstrap` and `/api/cron/research` to continue normally.
4. Re-test an anonymous run where the first 10 scoped companies produce fewer than 10 ready opportunities. The extension should refill after the first research pass until the ready target is met or the existing hard safety bounds are reached.

No new environment variables are required.
