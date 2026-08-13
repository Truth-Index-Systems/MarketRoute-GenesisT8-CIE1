# Truth Engine V2

Build 4 is MarketRoute V2's epistemic reasoning kernel.

The engine converts explicit claim/evidence links into categorical claim states:

- `KNOWN`
- `SUPPORTED`
- `UNRESOLVED`
- `CONTRADICTED`
- `STALE`

## Constitutional rules

1. Evidence strength is not probability.
2. `truthProbability` is `null` while the system is empirically uncalibrated.
3. Dependence families are collapsed before corroboration is counted.
4. One current independent supporting family may establish `SUPPORTED`.
5. A versioned policy defines how many independent supporting families are required for `KNOWN` (Build 4 policies require at least two).
6. Any current explicit contradiction makes the proposition `CONTRADICTED`; support cannot numerically outvote contradiction.
7. Missing evidence means `UNRESOLVED`, never false.
8. Evidence expires against the evaluation reference time, not the ingestion time.
9. Undated sources fall back to observation time and therefore still age.
10. Continuous support/balance/sufficiency metrics are diagnostics only. They do not decide the categorical state.
11. Entity `truthIndex` is a maximin epistemic-readiness measure, not a probability of truth.
