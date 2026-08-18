# MarketRoute V2 RC — Anonymous Discovery Quota Refill Cycle

## Problem
The anonymous Discovery extension had a three-attempt lifetime ceiling, but those attempts could be consumed by consecutive bootstrap runs before the currently scoped companies finished their first research pass. A run could therefore reach `EXHAUSTED` below the frozen 10-company target, then never refill after research completed.

## Fix
Continuation is now research-cycle gated. Bootstrap may claim an anonymous Discovery extension only when every company currently scoped to the original Discovery campaign has at least one `COMPANY_CORE_V1` Truth entity snapshot — the same marker already used by the customer-facing `researchedCompanies` metric.

The resulting flow is:

`scope current batch -> research current batch -> refill remaining quota -> research newly scoped companies -> refill again if required -> stop at 10`.

## Cost and authority boundaries retained
- 10-company target ceiling unchanged.
- USD 1 anonymous lifetime research budget unchanged.
- 12-hour anonymous research window unchanged.
- Three extension attempts remain the hard ceiling.
- Application provider discovery remains available only on attempts 1 and 2; attempt 3 remains bank-only.
- Paid conversion stops anonymous refill.
- The immutable original Discovery campaign remains the only campaign eligible for refill.
- R4/R5/R6 and Truth authority semantics are untouched.
- Autonomous delivery remains disabled.

## Existing runs
Pre-fix extension jobs that already reached `EXHAUSTED` can be re-armed once under cycle policy v2, but only after their current scoped batch is research-cycle ready and only while the original free run is otherwise eligible. Once migrated to policy v2, a future exhausted job cannot be reset again by bootstrap.

## Deployment
Run `APPLY-IN-SUPABASE-MARKETROUTE-V2-RC-ANONYMOUS-DISCOVERY-QUOTA-REFILL-CYCLE.sql`, then deploy the aligned repository.

No new environment variables are required.
