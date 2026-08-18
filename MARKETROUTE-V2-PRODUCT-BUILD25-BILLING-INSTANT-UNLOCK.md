# MarketRoute V2 — Product Build 25
## Billing + Instant Unlock

**Release family:** `0.18.3`  
**Product build:** 25  
**Authority change:** None  
**Genesis Growth:** Paused  
**Billing provider:** Stripe  

## Purpose

Build 25 connects verified subscription state to the commercial entitlement boundary introduced in Product Build 24.

The product flow is now:

`Discovery Free → locked opportunity → choose MarketRoute plan → Stripe Checkout → verified subscription → MarketRoute entitlement → instant opportunity unlock`

Billing changes **product access and research capacity only**. It does not create, edit, rank, recalculate, or approve Truth, R4, R5, R6, evidence, contacts, routes, opportunities, or CIE/UDOSIB commercial authority.

## Customer experience

### New subscription

1. A Discovery user sees opportunity 9+ locked.
2. `Unlock opportunities` opens the in-product plan chooser.
3. The browser submits only `STARTER`, `GROWTH`, or `SCALE`.
4. MarketRoute resolves the Stripe Price server-side and verifies that it is active, GBP, monthly, and exactly matches the server-owned MarketRoute plan price.
5. The customer is redirected to Stripe-hosted Checkout.
6. After successful Checkout, MarketRoute retrieves the Checkout Session and Subscription directly from Stripe and reconciles the entitlement.
7. When Stripe reports an active/trialing subscription, MarketRoute immediately changes the workspace to paid access and redirects to the opportunities view.
8. Previously locked opportunity data becomes readable without rerunning Genesis or rebuilding the campaign.

### Subscription management

A paid workspace owner sees **Manage billing** in `Plan & billing`.

MarketRoute creates a Stripe Customer Portal session using the customer ID already bound to the workspace. Subscription changes then return through the signed subscription webhook and update MarketRoute's existing entitlement row.

### Billing failure / cancellation

- `active` / `trialing` → `ACTIVE`
- `incomplete_expired` → `EXPIRED`
- `canceled` / `unpaid` → `CANCELLED`
- `incomplete`, `past_due`, `paused`, and other non-active states → `PAST_DUE`

Only `ACTIVE` gives paid MarketRoute access.

A subscription set to cancel at period end stays active until Stripe's current billing period ends. The entitlement is then changed by the subsequent Stripe lifecycle event.

## Server-authoritative commercial rules

The browser cannot submit:

- price amount
- currency
- Stripe Price ID
- research capacity
- entitlement status
- subscription/customer ID
- opportunity unlock IDs

It can submit only a MarketRoute plan code.

MarketRoute then verifies the configured Stripe Price against `marketroute_plan_catalog` before Checkout can be created.

### Launch catalogue

| Plan | Monthly price | Internal research capacity |
|---|---:|---:|
| Starter | £99 | 100 work units |
| Growth | £249 | 400 work units |
| Scale | £599 | 1,200 work units |

Research units are internal product controls, not a public promise of a fixed number of companies. They can be tuned later from observed production unit economics.

## Stripe integration

Build 25 intentionally does **not** add the Stripe SDK. The provider adapter uses Stripe's HTTPS API directly, keeping the dependency surface unchanged.

New server modules:

- `platform/billing/stripe.ts`
- `platform/database/billing-repository.ts`
- `application/billing/service.ts`

New routes:

- `POST /api/billing/checkout`
- `POST /api/billing/portal`
- `POST /api/billing/webhook`
- `GET /api/billing/cancel`
- `/app/billing/success`

## Webhook security and idempotency

`/api/billing/webhook`:

- reads the untouched raw request body
- verifies `Stripe-Signature`
- HMAC-SHA256 verifies `timestamp.raw_body`
- accepts only a five-minute timestamp tolerance
- stores the Stripe Event ID and payload SHA-256
- treats processed events as idempotent duplicates
- rejects the same Event ID with a different payload hash
- allows failed/stale in-flight events to retry

Handled lifecycle events:

- `checkout.session.completed`
- `customer.subscription.created`
- `customer.subscription.updated`
- `customer.subscription.deleted`

For subscription lifecycle events, MarketRoute retrieves the **current Subscription from Stripe** before applying access. This makes the entitlement resilient to out-of-order webhook delivery.

## Instant unlock without trusting the browser

The Checkout success URL includes Stripe's `{CHECKOUT_SESSION_ID}` placeholder.

The returned ID is not treated as proof of payment. MarketRoute retrieves the session itself and verifies:

- Checkout status is complete
- `client_reference_id` matches the current organisation
- MarketRoute organisation metadata matches
- MarketRoute plan metadata is valid
- a Stripe Subscription exists
- Checkout Customer matches Subscription Customer
- the Subscription contains exactly one configured MarketRoute Price
- Subscription metadata does not point at another organisation

Only then can the existing commercial entitlement RPC be reconciled.

The signed webhook remains the durable subscription lifecycle source; success reconciliation exists to make the immediate post-payment customer experience fast.

## Database changes

Migration: `0045_product_billing_instant_unlock.sql`

Adds service-role-only:

### `marketroute_billing_checkout_attempts`
Tracks one bounded Checkout attempt and prevents concurrent duplicate Checkout creation.

### `marketroute_billing_events`
Provides Stripe Event idempotency, payload integrity tracking, retry state, and operational diagnostics.

Adds RPCs:

- `marketroute_billing_context_v1`
- `marketroute_begin_billing_checkout_v1`
- `marketroute_attach_billing_checkout_v1`
- `marketroute_terminate_billing_checkout_v1`
- `marketroute_begin_billing_event_v1`
- `marketroute_finish_billing_event_v1`
- `marketroute_reconcile_stripe_subscription_v1`

Every new table/RPC is denied to `anon` and `authenticated`; billing mutations are service-role only.

## Stripe setup before live charging

### 1. Create three Stripe recurring Prices

Create monthly recurring GBP Prices that exactly match:

- Starter — **£99/month**
- Growth — **£249/month**
- Scale — **£599/month**

Copy each `price_...` ID.

### 2. Configure Stripe Customer Portal

Enable only the subscription-management behaviour you want MarketRoute customers to have. If plan switching is enabled, expose only the three MarketRoute Prices above. MarketRoute deliberately refuses an unmapped Stripe Price.

### 3. Create the webhook endpoint

Endpoint:

`https://marketroute.co.uk/api/billing/webhook`

Subscribe it to:

- `checkout.session.completed`
- `customer.subscription.created`
- `customer.subscription.updated`
- `customer.subscription.deleted`

Copy the endpoint signing secret (`whsec_...`).

### 4. Add Vercel environment variables

```env
STRIPE_SECRET_KEY=sk_live_...
STRIPE_WEBHOOK_SECRET=whsec_...
STRIPE_PRICE_STARTER=price_...
STRIPE_PRICE_GROWTH=price_...
STRIPE_PRICE_SCALE=price_...
MARKETROUTE_APP_URL=https://marketroute.co.uk
```

For the first end-to-end checkout test, use Stripe **test-mode** keys and test-mode Prices rather than live values.

### 5. Tax / VAT

Build 25 does not enable Stripe Tax or make a tax-registration assumption. Tax/VAT configuration should be decided separately before live customer charging.

## Deployment order

1. Configure the three matching Stripe Prices.
2. Configure the Customer Portal.
3. Create the Stripe webhook endpoint and obtain its signing secret.
4. Add all Build 25 environment variables to Vercel.
5. Run `APPLY-IN-SUPABASE-MARKETROUTE-V2-PRODUCT-BUILD25.sql` in Supabase.
6. Deploy the Build 25 ZIP.
7. Run a Stripe test-mode purchase from a claimed Discovery workspace.
8. Verify the return lands on `/app/opportunities?billing=active` and previously locked opportunities are readable.
9. Verify `Plan & billing → Manage billing` opens the Stripe Customer Portal.
10. Test a subscription status change and confirm MarketRoute access follows the signed webhook state.

## Validation

Final Product Build 25 gates:

- Build 25 static: **17/17 PASS**
- Build 25 adversarial: **12/12 PASS**
- Build 24 static: **20/20 PASS**
- Build 24 adversarial: **11/11 PASS**
- Architecture: **438/438 PASS**
- Production Activation: **22/22 PASS**
- Release Certification: **28/28 PASS**
- TS/TSX parser pass: **196/196 PASS**

The final full red-team replay reached 13/22 before its compiler-backed engine tests were blocked by the sandbox's missing `@types/node`; every non-compiler-backed replay check passed. Those same frozen engine red-team suites were green before the final Build 25-only billing hardening, and no frozen engine file was changed by that hardening. A clean Vercel production compile remains the final compiler/runtime gate because this source bundle does not include a complete installed dependency tree in the working sandbox.

## Explicit non-goals

Build 25 does not:

- reactivate Genesis Growth
- modify Truth mathematics
- modify CIE/UDOSIB
- modify R4/R5/R6 authority
- introduce autonomous email delivery
- expose locked opportunity payloads before entitlement
- allow the browser to grant paid access
- implement annual billing
- automate tax/VAT

## Next build

**Product Build 26 — Full Product Experience**

Planned scope:

- conversational Command Centre
- progressive customer-language pass across the authenticated app
- contextual opportunity questions / structured commands
- website + pricing funnel completion
- Privacy / Terms / support surfaces
- product analytics and founder unit economics instrumentation
- outbound delivery remains OFF
