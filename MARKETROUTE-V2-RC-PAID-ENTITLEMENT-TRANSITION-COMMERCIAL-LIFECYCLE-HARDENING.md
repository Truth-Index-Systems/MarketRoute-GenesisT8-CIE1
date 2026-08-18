# MarketRoute V2 RC — Paid Entitlement Transition & Commercial Lifecycle Hardening

## Purpose

This release candidate hardens MarketRoute's behaviour across the full commercial lifecycle: Discovery Free → paid subscription → plan change/downgrade → billing interruption → cancellation/reactivation.

The patch is deliberately orchestration-only. It does not add or modify any Truth, R4, R5, R6, authority or opportunity-ranking writer.

## Migration

- Operational migration: `0062_paid_entitlement_transition_commercial_lifecycle_hardening.sql`
- Build number: `62`
- Authority writer introduced: **No**
- Authority semantics changed: **No**

The root `APPLY-IN-SUPABASE-MARKETROUTE-V2-RC-PAID-ENTITLEMENT-TRANSITION-COMMERCIAL-LIFECYCLE-HARDENING.sql` is byte-for-byte identical to migration 0062.

## Behaviour after subscribing

### Discovery → paid

A verified Stripe `active` or `trialing` subscription now atomically promotes the immutable original Discovery campaign from the bounded anonymous research profile to the standard paid research profile. The previous `$1` Discovery research policy therefore cannot continue throttling the customer's original market after payment.

The original campaign is not recreated and no authority is manufactured. Existing evidence and authority lineage remain intact.

### Paid opportunity refill

Anonymous refill correctly stops after paid conversion. A separate paid, demand-driven refill controller now takes over when a paid campaign has fewer than 10 authority-ready opportunities.

The controller:

- measures completion using `marketroute_authority_ready_v1`;
- searches wider only when the campaign remains below 10 authority-ready opportunities;
- waits for campaign-specific research work to settle before widening again;
- uses the Genesis intelligence bank before paid web discovery;
- is bounded to a lifetime candidate ceiling of 60 companies per campaign;
- is bounded to six attempts per refill episode;
- starts a fresh six-attempt episode if a previously successful campaign later falls below the ready target because evidence/currentness decays, without resetting the 60-company lifetime ceiling;
- cannot operate when the campaign is outside current paid plan research entitlement or plan research capacity.

### Plan downgrade / upgrade

Stripe plan reconciliation now enforces the server-owned active-market allowance against research execution.

If a customer downgrades below their existing number of non-archived markets:

- MarketRoute does **not** delete or archive customer campaigns;
- campaigns retain their data;
- research is enabled only for the deterministic first N market slots allowed by the plan;
- over-capacity campaigns are research-suspended;
- the Plans UI explains the over-capacity state;
- upgrading restores research eligibility to the additional slots.

The latest research claimant independently re-checks campaign research entitlement, so a stale `enabled=true` policy cannot bypass a downgrade.

### Billing interruption / cancellation

Provider states fail closed:

- `active` / `trialing` → paid ACTIVE;
- `canceled` / `unpaid` → CANCELLED;
- `incomplete_expired` → EXPIRED;
- other non-active provider states, including `past_due`, → PAST_DUE.

`cancel_at_period_end` does not terminate paid access while Stripe still reports the subscription as active. When Stripe actually leaves the active/trialing state, paid research is disabled.

If the original Discovery window and budget are still legitimately available after paid access ends, bounded free research may be restored **only** to the immutable original Discovery campaign. Later paid-created campaigns cannot inherit or mint another anonymous research envelope.

Campaign RESUME also re-checks current research entitlement before turning research back on.

## Commercial read boundary

Discovery Free company access is now campaign-scoped as well as company-scoped. A company that was free in the original Discovery campaign cannot expose richer intelligence from a later paid-created campaign after cancellation.

The Discovery command centre is likewise restricted to the immutable original Discovery campaign.

## Billing recovery

Stripe webhooks remain the primary billing lifecycle signal. A bounded recovery loop now periodically re-fetches subscriptions that are due for reconciliation and feeds them through the same verified reconciliation path. Recovery attempts are throttled server-side.

This protects against a missed or delayed lifecycle webhook without weakening the fail-closed entitlement model.

## Certification

Release certification is advanced through operational migration 0062. Migration 0062 is explicitly certified as non-authoritative and included in `production:check` through `validate:paid-entitlement-lifecycle`.

Final local validation for this artifact:

- `npm run production:check`: **2700 PASS / 0 FAIL**
- paid-entitlement static gate: **13/13 PASS**
- paid-entitlement adversarial gate: **12/12 PASS**
- paid-entitlement lifecycle model: **14/14 PASS**
- changed TypeScript source syntax/transpile check: **9/9 PASS**
- deploy SQL equals migration 0062: **PASS**

A complete Next/Vercel production compilation was not run in this container because project dependencies are not installed. Vercel compilation remains the final build-system integration gate.

## Deployment order

If migrations 0060 and 0061 are already live:

1. Apply migration 0062 / the root apply SQL in Supabase.
2. Deploy this RC to Vercel.
3. Confirm Vercel production compile.
4. Exercise one Stripe test/live subscription transition and inspect the original campaign policy plus paid-refill state.

If 0060/0061 have not yet been applied, apply `0060 → 0061 → 0062` in order before deploying the application code.
