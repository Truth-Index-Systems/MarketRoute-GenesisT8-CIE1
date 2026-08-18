# Validation Record — Paid Entitlement Transition & Commercial Lifecycle Hardening

## Scope

Artifact base: `MarketRoute-V2-RC-Launch-Certification-Refill-Liveness`

New operational migration: `0062_paid_entitlement_transition_commercial_lifecycle_hardening.sql`

Audit focus: behaviour before, during and after subscription; plan changes; downgrade capacity; cancellation; anonymous-envelope isolation; commercial read isolation; billing recovery; Truth/authority sovereignty.

## Canonical production gate

Command:

```text
npm run production:check
```

Result:

```text
2700 PASS
0 FAIL
exit code 0
```

## New paid-entitlement gate

Command:

```text
npm run validate:paid-entitlement-lifecycle
```

Results:

- Static contract checks: **13/13 PASS**
- Adversarial checks: **12/12 PASS**
- Deterministic lifecycle model: **14/14 PASS**

Covered transitions/invariants include:

- Discovery original campaign retains only bounded free research before payment.
- Verified subscription promotes the original campaign to paid research policy.
- `10 scoped / 5 authority-ready` after payment triggers paid refill rather than stopping.
- Paid refill waits for campaign-specific research plans/jobs to settle before widening again.
- 10 authority-ready opportunities terminates the refill episode.
- A later evidence/currentness drop can open a fresh bounded refill episode while preserving the lifetime 60-candidate ceiling.
- Scale → Starter suspends research beyond the first allowed market without deleting campaign data.
- Starter → Growth restores research for the first three non-archived market slots.
- PAST_DUE disables paid research until Stripe returns ACTIVE/trialing.
- Cancel-at-period-end preserves paid state while Stripe still reports active/trialing.
- Cancellation can restore the residual Discovery envelope only to the immutable original campaign and only while its original window/budget remains valid.
- Paid-created campaigns cannot inherit anonymous research after cancellation.
- Free company access cannot cross into a later paid-created campaign containing the same company.
- Over-limit campaigns cannot claim paid refill work.
- Exhausted plan research capacity defers paid refill.
- Stale research policy enablement cannot bypass current plan entitlement.
- Migration 0062 cannot write Truth/R4/R5/R6/authority records.

## SQL deployment identity

The following files were compared byte-for-byte and match:

- `supabase/migrations/0062_paid_entitlement_transition_commercial_lifecycle_hardening.sql`
- `APPLY-IN-SUPABASE-MARKETROUTE-V2-RC-PAID-ENTITLEMENT-TRANSITION-COMMERCIAL-LIFECYCLE-HARDENING.sql`

Result: **PASS**

## TypeScript source parse/transpile gate

Nine changed TypeScript/TSX application files were parsed/transpiled with TypeScript 5.8.3 without module resolution:

- opportunities detail page
- plans page
- billing service
- commercial service
- production bootstrap
- production runtime
- application read-model service
- billing repository
- production activation repository

Result: **9/9 PASS**

This proves source syntax for the changed TypeScript files; it is not a substitute for a full Next build because `node_modules` are not installed in the audit container.

## Truth Index sovereignty result

- New authority writer: **No**
- R4 writer changed: **No**
- R5 writer changed: **No**
- R6 writer changed: **No**
- Truth calculation semantics changed: **No**
- Opportunity readiness fabricated by refill controller: **No**
- Paid refill observes existing authority readiness only: **Yes**

## Remaining external gate

**Vercel production compile** remains required after deployment. This validation record does not claim a complete Next production build in the local container.
