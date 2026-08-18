# MarketRoute RC 0.63 — Launch Experience Pass

## Purpose

RC 0.63 is a presentation-only launch pass. It changes how MarketRoute looks, reads and explains itself without changing the commercial engine underneath.

The design direction is: **premium commercial intelligence, not an intelligence terminal**.

## What changed

- Rebuilt the public homepage around the customer outcome: know who to target, why they matter, and how to reach them.
- Moved Genesis / Truth Index detail deeper into the trust story instead of making technical architecture the first thing a prospect sees.
- Reworked the authenticated application into a brighter, warmer premium workspace with a navy MarketRoute rail, larger typography, clearer spacing, stronger cards and more obvious actions.
- Raised customer-facing typography substantially across navigation, tables, forms, cards, discovery and opportunity pages.
- Replaced internal/technical language with plain commercial language wherever the user does not need to understand implementation detail.
- Simplified the product journey into human outcomes while retaining the canonical seven-stage pipeline underneath.
- Reworked opportunity pages so the customer sees the answer first: why the company matters, a usable route in, the right person, contact routes and research strength.
- Kept deeper authority, provenance and Truth detail available in a collapsed advanced research section rather than placing it at the centre of the product.
- Simplified Discovery, market creation, activation, campaign controls, outreach, plan/billing and upgrade language.
- Preserved the commercial distinction between free unlocked opportunities and paid intelligence.

## Behaviour preserved

This release does **not** change:

- Truth / evidence semantics
- R4 Commercial Reality authority
- R5 relationship / route authority
- R6 contact authority
- CIE / opportunity mathematics
- research orchestration
- company discovery/refill behaviour
- billing, Stripe or entitlement logic
- subscription lifecycle behaviour
- Supabase schema or migrations

No Supabase migration is required for RC 0.63.

## Validation note

A small number of presentation-specific validators were updated because they previously asserted exact legacy UI wording. Those updates only align the tests with the new customer-facing copy. Constitutional, authority, billing, entitlement, security and commercial-boundary assertions were retained.

## Deployment

Deploy application code only. Do not run SQL for this release.

Vercel production compilation remains the final framework integration gate because this audit environment does not contain the project's installed `node_modules` tree.
