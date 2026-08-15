# MarketRoute V2 — Production Activation Hardening 0.18.3.7

## Production evidence

The first real campaign activation returned `MARKETROUTE_SELLER_OFFERING_UNRESOLVED`. OpenAI completed the seller-genome request, but domain-filtered website search returned no supportable offering. Activation stopped before campaign creation, target discovery or Genesis research. The submitted row also contained contradictory constraint state (`hard_constraints_text` populated while `no_hard_constraints=true`), retained an accumulated retry count and was reported by `/api/cron/bootstrap` as HTTP 200.

## Hardening

1. Setup now captures a required first-party description of what the seller currently sells. Seller-genome extraction still freshly analyses the website, but a new or poorly indexed site can no longer erase an explicit seller declaration.
2. Hard-constraint mode is an explicit radio choice. Application and database boundaries reject written constraints combined with “no hard constraints”; retry persistence stores one canonical state only.
3. A corrected activation submission resets `attempt_count` to zero and clears the previous lease/error/result state.
4. Activation selects reusable, core-complete Genesis-bank identities first using explicit industry and country semantics. Research density only orders reusable work and does not calculate commercial fit or authority. Paid web discovery runs only when the matching bank population is below the configured minimum.
5. Bootstrap batches return `SUCCEEDED`, `PARTIAL`, `FAILED` or `IDLE`. Partial batches return HTTP 207; failed batches return HTTP 500; production observability records logical failures as `FAILED` with the activation error code.

## Constitutional boundary

The patch creates no Truth, R4, R5, R6, opportunity, engagement or execution authority writer. The seller declaration is first-party context. Bank selection is deterministic candidate retrieval only. Existing Truth evaluation and authority gates remain unchanged.

## Deployment

1. Apply `APPLY-IN-SUPABASE-MARKETROUTE-V2-0.18.3.7-ACTIVATION-HARDENING.sql` in Supabase.
2. Deploy this ZIP to Vercel.
3. Return to setup. Describe the current offering, objective and target market. Select “I have hard commercial limits” and enter `UK only; small organisations` for the original test.
4. Run or await `/api/cron/bootstrap`.
5. A successful logistics activation should report discovery strategy `GENESIS_BANK_ONLY` when at least five matching core-complete GB logistics companies exist, otherwise `GENESIS_BANK_PLUS_WEB` or `WEB_FALLBACK`.

## Validation

- `npm run validate:hotfix-01837`
- `npm run typecheck`
- `npm run build`
