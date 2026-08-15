# MarketRoute V2 — Seller-Genome JSON Hotfix 0.18.3.8

## Production evidence

The hardened activation reached `marketroute_persist_seller_genome_v1` and PostgreSQL returned SQLSTATE `22P02`, `invalid input syntax for type json`. A PostgreSQL-compatible reproduction exposed the suppressed detail: `Token "offerings" is invalid`, inside the first dimension exact-key expression in `marketroute_seller_genome_validate_v1`.

The canonical genome was valid JSON. The defect was SQL operator binding: `v_semantic->'offerings' - ARRAY[...]` was not explicitly grouping the JSON extraction before JSONB key removal. PostgreSQL attempted to interpret the key token as JSON before validation could continue.

## Repair

Migration `0028_seller_genome_json_operator_hotfix.sql` replaces the existing validator at the same signature and parenthesises all eight dimension extractions before applying JSONB key removal. Validation policy, canonical fingerprints, permissions and downstream authority boundaries are unchanged.

Activation diagnostics now retain the failed RPC name, PostgreSQL SQLSTATE and bounded PostgREST detail. Future database failures therefore produce an actionable `last_error_code` rather than only the generic database message.

## Deployment and recovery

1. Apply `APPLY-IN-SUPABASE-MARKETROUTE-V2-0.18.3.8-SELLER-GENOME-JSON-HOTFIX.sql` in Supabase.
2. Deploy this package to Vercel so the improved diagnostics are active.
3. Run or await `/api/cron/bootstrap`. The existing job is already `FAILED`, remains retryable and has only used two of five attempts, so no setup resubmission or manual row edit is required.
4. Confirm the activation job becomes `SUCCEEDED`. If it fails elsewhere, the new `last_error_code` will identify the RPC and SQLSTATE.

The retry performs one new seller-genome extraction because the failed canonical result was never persisted. The previously recorded source material is deduplicated; do not start a second campaign while this activation job is pending.

## Validation

- PostgreSQL-compatible regression: the original validator reproduced SQLSTATE `22P02`; the replacement accepted the same canonical genome.
- `npm run validate:hotfix-01838`
- `npm run typecheck`
- `npm run build`
- `npm run constitution:check`
