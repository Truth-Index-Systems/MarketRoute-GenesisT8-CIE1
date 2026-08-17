# MarketRoute V2 — Product Build 23: Free Eight + Account Claim

## Purpose

Product Build 23 turns anonymous discovery into the first real conversion boundary.

The governing flow is:

**Anonymous discovery → first eight authority-ready opportunities become permanently free → contact action asks the visitor to create an account → the existing discovery is claimed into that account → no research restarts.**

This build creates product entitlement only. It does not create Truth, R4, R5, R6 or opportunity authority and it does not add billing.

## What changed

### 1. Permanent Free Eight entitlement

Migration `0043_product_free_eight_account_claim.sql` adds `anonymous_discovery_opportunity_unlocks`.

The entitlement is persisted by exact opportunity ID and ordinal 1–8.

An opportunity can enter the free set only when:

- it belongs to the anonymous campaign;
- its workflow state is reviewable/approved/engaged; and
- the existing `marketroute_authority_ready_v1(...)` boundary says the opportunity is currently ready.

Allocation uses stable arrival order (`opportunity.created_at`, then ID). Build 23 deliberately does **not** invent a scalar commercial ranking that CIE does not own.

Once an opportunity receives a free slot, that exact opportunity remains part of the customer's permanent free eight even if later research changes ordering.

If the account is created before all eight are ready, authenticated access keeps filling the remaining slots as the already-authorised discovery work completes. The customer does not need to revisit the anonymous page.

### 2. Safe anonymous opportunity previews

The public discovery experience now displays the opportunities that have earned free slots.

Anonymous users can see safe previews including:

- company;
- named person/current role when the authorised route supports it;
- plain-English route explanation;
- whether an email route exists;
- whether a phone route exists;
- whether a professional/direct web route exists.

Exact channel values and hrefs are **not** sent to the anonymous browser. No email address, phone number, `mailto:`, `tel:` or private route URL is leaked before the account boundary.

The phone row remains explicit: if no authorised phone exists, the preview says `Phone not found yet`.

### 3. Contact-action signup gate

Attempting an anonymous contact action opens:

**Save your MarketRoute**

The customer is told that:

- the routes already found are theirs;
- creating a free account saves the existing MarketRoute;
- the first eight stay free;
- MarketRoute will not restart the research.

The CTA carries a server-safe discovery-claim intent into signup/login. The anonymous browser identity itself is never accepted from form input.

### 4. Transactional anonymous-run claim

`marketroute_claim_anonymous_discovery_v1(...)` claims the existing anonymous organisation using `auth.uid()`.

The claim:

- creates/updates the authenticated owner membership;
- promotes the same organisation from anonymous discovery to customer workspace;
- associates existing seller/campaign records with the authenticated user;
- marks the anonymous run `CLAIMED`;
- creates **no second organisation**;
- creates **no second activation job**;
- performs **no research rerun**.

If Supabase creates a session immediately, claim happens during signup.

If email confirmation is required, the claim intent survives to login and is completed on the first authenticated sign-in.

### 5. Existing research may finish, but cannot expand into a second free market

Claiming does not kill work that was already authorised by the anonymous run.

The original campaign can finish only inside its existing:

- anonymous lifetime research budget; and
- anonymous research-expiry window.

The discovery-free workspace is blocked from creating a replacement campaign until a later paid entitlement permits it.

### 6. Server-side free access enforcement

The free-eight boundary is not cosmetic.

For a claimed discovery workspace, canonical application reads are filtered to the persisted free company/opportunity IDs.

Direct reads of hidden company/opportunity intelligence return `MARKETROUTE_DISCOVERY_UPGRADE_REQUIRED`.

Opportunity write actions perform the same server-side entitlement check, preventing a customer from bypassing the UI by manually calling an endpoint or constructing a hidden URL.

Normal existing customer workspaces retain `FULL` access and are unchanged.

### 7. Password recovery

Build 23 adds:

- `/forgot-password`;
- reset-email request route;
- `/reset-password`;
- password update route;
- login link to password recovery.

The reset-request response is intentionally generic so account existence is not disclosed.

## Deliberately deferred

Product Build 23 does **not** implement:

- opportunity 9+ locked/blurred cards;
- upgrade-plan modal;
- plan entitlements;
- checkout/subscriptions;
- paid opportunity unlocks;
- customer research-capacity plans;
- autonomous outbound delivery.

These belong to Product Build 24 and later.

## Deployment

1. Run `APPLY-IN-SUPABASE-MARKETROUTE-V2-PRODUCT-BUILD23.sql` in the existing V2 Supabase project.
2. In Supabase Auth URL configuration, allow the production reset destination: `https://<your-marketroute-domain>/reset-password` (and the matching preview/local URL only where required for testing).
3. Deploy the Product Build 23 ZIP to Vercel.
4. Start a fresh anonymous discovery.
5. Confirm authority-ready opportunities progressively enter `YOUR FIRST 8`.
6. Confirm the anonymous browser can see route availability but cannot inspect exact email/phone values.
7. Click `Access email`, `Access phone` or `Open contact route` and confirm the account gate opens.
8. Create an account and confirm the same MarketRoute is claimed with no second activation/research run.
9. Confirm the signed-in opportunity page exposes the exact Build 22 contact panels for entitled opportunities.
10. If fewer than eight were ready at claim time, allow research to progress and confirm later authority-ready opportunities fill the remaining free slots automatically.
11. Confirm attempting a replacement campaign returns the upgrade-required boundary.
12. Test password-reset email and recovery on the production domain.

No new Vercel environment variable is required by Build 23. Build 20's existing `MARKETROUTE_ANONYMOUS_SESSION_SECRET` remains required.

## Product state after Build 23

The acquisition journey is now:

**Visitor enters business → MarketRoute researches progressively → authority-ready opportunities appear → first eight are permanently free → visitor attempts a contact action → account gate appears → signup claims the existing run → customer immediately receives the exact authorised contact routes without MarketRoute starting again.**

The next planned build is Product Build 24: **Locked Opportunities + Commercial Boundary**.
