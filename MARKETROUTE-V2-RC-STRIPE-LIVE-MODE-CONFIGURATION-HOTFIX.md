# MarketRoute V2 RC — Stripe Live-Mode Configuration Hotfix

## Diagnosis
Production checkout is using a live Stripe API key with test-mode Stripe Price IDs. Stripe correctly rejects those objects before Checkout Session creation.

Observed production symptom:
- `STRIPE_SECRET_KEY` is live-mode.
- `GET /v1/prices/price_...` returns 404 with Stripe's live/test object mismatch message.
- No Checkout Session and no subscription are created.

## Required production configuration
No Supabase migration is required.

In Stripe LIVE mode, create or select recurring monthly GBP Prices matching MarketRoute's canonical plan catalogue:
- Starter: £99/month
- Growth: £249/month
- Scale: £599/month

Update Vercel Production environment variables:
- `STRIPE_PRICE_STARTER=<LIVE price id for £99/month>`
- `STRIPE_PRICE_GROWTH=<LIVE price id for £249/month>`
- `STRIPE_PRICE_SCALE=<LIVE price id for £599/month>`

Keep `STRIPE_SECRET_KEY` as the live key. Verify `STRIPE_WEBHOOK_SECRET` belongs to the LIVE webhook endpoint for MarketRoute, not the test endpoint.

Redeploy production after changing the environment variables.

## Code hardening in this RC
- Detects Stripe's live-key/test-object and test-key/live-object mismatch responses explicitly.
- Converts them to `MARKETROUTE_BILLING_STRIPE_MODE_MISMATCH`.
- Stops raw Stripe provider messages from being copied into browser query parameters.
- Presents a safe customer message confirming no charge was created.
- Keeps server-side Price verification before checkout reservation: active, GBP, expected amount, monthly recurrence.
- Does not create Products or Prices dynamically.
- Does not alter commercial entitlement unless normal Stripe reconciliation succeeds.

## Expected production test
1. Change all three Vercel `STRIPE_PRICE_*` values to LIVE Price IDs.
2. Redeploy.
3. Open Plan & Billing.
4. Choose Starter, Growth or Scale.
5. The price lookup should return 200.
6. MarketRoute should POST `/v1/checkout/sessions` and redirect to Stripe-hosted Checkout.
7. After successful payment, Checkout return/webhook reconciliation should activate the selected plan.

## Validation
- Stripe hotfix static gate: 7/7 PASS
- Stripe hotfix adversarial gate: 8/8 PASS
- Product Build 25 Billing: 17/17 + 12/12 PASS
- Engagement/Billing transition: 9/9 + 10/10 PASS
- Multi-campaign governance: 21/21 + 16/16 PASS
- Campaign activation lineage: 18/18 + 13/13 PASS
- Complete `npm run production:check`: PASS

No new environment variables. No SQL migration.
