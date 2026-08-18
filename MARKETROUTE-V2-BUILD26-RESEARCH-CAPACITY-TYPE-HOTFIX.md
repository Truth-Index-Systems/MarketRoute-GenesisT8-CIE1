# MarketRoute V2 — Build 26 Research Capacity Type Hotfix

## Scope
Narrow compile hotfix for the Build 26 premium Research page.

## Vercel failure
`ResearchCapacityRecord.reservedUnits` is optional at the repository boundary, while the customer-facing `capacity(...)` formatter required it as a mandatory number.

## Fix
- Updated the formatter input contract to accept `reservedUnits?: number`.
- Normalise a missing reservation value to `0` before rendering.
- No billing, entitlement, research, Truth, CIE, R4/R5/R6 or database semantics changed.
- No SQL migration required.
- No environment changes required.

## Verification
- Original `reservedUnits` assignment error is absent from targeted `tsc --noEmit` output.
- Build 26: 20/20 static, 12/12 adversarial.
- Build 25: 17/17 static, 12/12 adversarial.
- Build 24: 20/20 static, 11/11 adversarial.
- Architecture: 468/468.

Local source ZIP has no installed React/Next type dependencies, so Vercel remains the full production compiler gate.
