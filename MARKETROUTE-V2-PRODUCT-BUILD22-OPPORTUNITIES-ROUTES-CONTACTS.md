# MarketRoute V2 — Product Build 22: Opportunities, Routes & Contacts

## Purpose

Product Build 22 turns an authorised opportunity into something a customer can actually use.

The governing rule is:

**Only current R5/R6-authorised routes are presented as ready contact routes.**

This build does not rank routes, create contact authority, infer missing contact details, or change Truth/CIE/R4/R5/R6 semantics.

## What changed

### 1. Enriched read-only route projection

Migration `0042_product_opportunity_routes_contacts.sql` extends the existing service-role-only route display read with:

- company website/domain;
- route ordinal and mode;
- R6-backed named person identity;
- current supported role titles;
- terminal access-point kind/value;
- route/contact revalidation timestamps;
- current identity, employment, role and channel Truth snapshot references.

The RPC remains service-role only and writes no authority table.

### 2. Ready contact panels

The signed-in opportunity page now puts actionable routes above advanced engine mechanics.

For each authorised contact/organisational route MarketRoute shows:

- person name and current role when R6 supports them;
- a plain-English explanation of why the route is usable;
- email in a copyable panel;
- phone in a dedicated row **at all times** (`Phone not found yet` when absent);
- click-to-email and click-to-call actions;
- LinkedIn/professional profile link when present;
- contact form/direct web route when present;
- company website link;
- route/contact freshness;
- identity/employment/role/channel evidence links into the existing provenance drawer.

Multiple channels for the same authorised named contact are grouped into one contact card.

### 3. Authority-safe grouping

Ready and still-verifying paths are grouped separately.

A verified email route therefore cannot accidentally expose an unverified phone number belonging to a sibling path for the same person.

### 4. Structural-path redaction

The advanced route-structure panel still exists for auditability, but unauthorised paths now render:

- `Named contact under verification`
- `Contact route under verification`

instead of exposing unverified identity/channel values as usable contact data.

### 5. Conversational grounding improved

The existing Build 21 opportunity narrator now receives the names/roles and **channel kinds** of ready routes so it can explain that a verified route exists.

It is deliberately not supplied raw email/phone values for narration. Exact contact values stay in deterministic contact panels sourced from the canonical route read.

## Deliberately deferred

Product Build 22 does **not** implement:

- anonymous opportunity cards;
- the free eight entitlement;
- anonymous-to-account claiming;
- contact-action signup gate;
- locked opportunities;
- plans/billing;
- route commercial ranking;
- autonomous outbound delivery.

Those remain later product builds.

## Deployment

1. Run `APPLY-IN-SUPABASE-MARKETROUTE-V2-PRODUCT-BUILD22.sql` in the existing V2 Supabase project.
2. Deploy the Product Build 22 ZIP to Vercel.
3. Open a signed-in opportunity with current R5/R6 authority.
4. Confirm authorised email/phone/profile/form routes render correctly.
5. Confirm a missing phone displays `Phone not found yet` rather than disappearing.
6. Confirm evidence links open the canonical provenance drawer.
7. Confirm unauthorised structural paths redact person/channel values.

No new Vercel environment variable is required.

## Product state after Build 22

The signed-in opportunity journey is now:

**MarketRoute explains the opportunity → ready contact routes are immediately actionable → exact email/phone/direct links are usable → evidence remains one click away → advanced engine structure remains available below.**

The next planned build is Product Build 23: **Free Eight + Account Claim**.
