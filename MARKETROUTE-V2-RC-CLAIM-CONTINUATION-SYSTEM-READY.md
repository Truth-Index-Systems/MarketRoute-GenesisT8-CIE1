# MarketRoute V2 RC — Claimed Discovery Continuation + System-Owned Readiness

## Purpose

This RC hardening patch closes two launch-state gaps:

1. Creating an account must not strand a free Discovery run below its original bounded target before the paid teaser can naturally emerge.
2. A customer should not have to approve a commercial opportunity after MarketRoute's current R4/R5/R6 authority already deems it ready. Human approval belongs to the outbound message, not to the commercial conclusion.

## Discovery continuation

The original free-run envelope remains unchanged:

- maximum 10 scoped companies
- first 8 authority-ready opportunities permanently free
- maximum 2 locked server-redacted teasers before payment
- $1 lifetime anonymous research budget
- 12-hour research window
- one original organisation, seller and campaign

Account claim still changes the workspace to CUSTOMER and the anonymous run to CLAIMED, but the run remains eligible for its unused free Discovery envelope until expiry or payment.

### Initial activation

Anonymous activation now fills toward the full server-owned target count rather than stopping as soon as the minimum Genesis-bank threshold is satisfied.

### Continuation worker

Migration `0051_claimed_discovery_continuation_system_ready.sql` adds a service-role-only bounded continuation queue. The existing `/api/cron/bootstrap` worker:

1. finds ACTIVE or CLAIMED free Discovery runs below their original target;
2. reuses the existing ACTIVE campaign and current seller genome;
3. checks the Genesis intelligence bank first;
4. uses target discovery only for the remaining gap;
5. excludes seller and already-scoped domains;
6. links only into the original campaign;
7. stops at `anonymous_discovery_runs.target_count`;
8. stops immediately on paid entitlement or research-window expiry.

The continuation job has at most three total attempts. Provider-backed target discovery is allowed on at most the first two attempts; the third attempt is bank-only. A terminal FAILED job is not silently reclaimed.

No second activation job, organisation, campaign or free run is created.

Newly scoped companies enter the existing demand-driven research scheduler normally. Research remains governed by the original anonymous research budget/window.

## System-owned opportunity readiness

The historical database value `REVIEWABLE` is retained for compatibility. From this release its product meaning is **Ready**.

An opportunity is executable when:

- workflow storage is `REVIEWABLE` (system-ready) or legacy `APPROVED`; and
- the current R4/R5/R6 authority envelope is ready.

`RESEARCHING`, `REJECTED`, stale authority and incomplete route/contact authority remain non-executable.

No new authority writer is introduced. R4, R5 and R6 remain the sole authority chain.

### Customer workflow

Removed from the customer opportunity page:

- Approve opportunity
- Reject opportunity
- opportunity-level approval requirement

The existing review endpoint rejects APPROVE/REJECT. `RETURN_TO_RESEARCH` remains available to the structured Ask MarketRoute commands so a user can still request deeper checking.

### Engagement

Assisted Engagement now accepts a system-ready `REVIEWABLE` opportunity directly. Legacy `APPROVED` rows remain compatible.

Human approval is still mandatory for the **message** before a manual contact can be recorded. Current strategy, PASS AI review, exact authority fingerprint and current route authority are still revalidated.

Autonomous queue/delivery remains disabled.

## Additional correction

The assisted engagement generation API now checks the canonical `canGenerateDraft` read-model action. This aligns the API with the current assisted-engagement projection.

## Deployment

1. Apply `APPLY-IN-SUPABASE-MARKETROUTE-V2-CLAIM-CONTINUATION-SYSTEM-READY.sql` in Supabase.
2. Deploy the repository ZIP.
3. No new environment variables are required.
4. For an existing ACTIVE/CLAIMED free run below 10 scoped companies, observe the next `/api/cron/bootstrap` run. It should report `extensionProcessed` when a continuation job is claimed.
5. Then observe `/api/cron/research`; newly scoped companies should enter the existing research planner under the same free-run budget/window.

## Certification

- Claim continuation + system-ready static gate: 18/18
- Claim continuation + system-ready adversarial gate: 14/14
- Product Build 20 anonymous Discovery: 24/24 + 8/8
- Product Build 23 free eight/account claim: 17/17 + 9/9
- Product Build 24 commercial boundary: 20/20 + 11/11
- Product Build 26 experience: 20/20 + 12/12
- Assisted Engagement: 18/18 + 14/14
- Build 18 certification: 33/33
- Full red-team replay: 22/22
- TS/TSX syntax transpilation: 208/208
- Full `npm run production:check`: PASS

Vercel remains the final Next.js dependency/type compiler gate because the source handoff intentionally contains no installed `node_modules`.
