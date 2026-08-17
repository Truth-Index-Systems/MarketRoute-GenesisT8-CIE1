# MarketRoute V2 — Product Build 21: Conversational Intelligence

## Purpose

Product Build 21 gives MarketRoute a customer-facing voice without giving AI any commercial authority.

The governing rule is:

**Engine determines reality → AI explains reality → UI guides the customer through reality.**

Genesis, Truth Index, R4/R5/R6 and CIE/UDOSIB remain the authority-owning layers. The narrator receives bounded structured state, cannot browse for new evidence, cannot invent evidence references, cannot change scores/decisions/permissions, and cannot write authority tables.

## What changed

### 1. Conversation contract

Added `MRV2-CONVERSATION-1.0.0` with structured output fields:

- headline
- summary
- why it matters
- known facts
- uncertainties
- recommendation
- next action
- evidence references
- source fingerprint

The contract explicitly distinguishes AI generation from deterministic fallback.

### 2. Grounded narrator service

Added `application/conversation/service.ts`.

The service:

- builds a compact fact set from canonical/persisted engine state;
- hashes that fact set to a deterministic source fingerprint;
- checks the persistent narration cache first;
- calls OpenAI Structured Outputs only on cache miss;
- never enables web search for narration;
- rejects evidence references not supplied by the engine;
- rejects internal implementation language such as R4/R5/R6, UDOSIB, fingerprints and epistemic terminology from customer narration;
- records narration AI usage as `CUSTOMER_EXPLANATION`;
- falls back to deterministic plain-English copy if AI fails or violates the contract;
- briefly caches fallback output so an outage cannot cause repeated model calls on every poll.

### 3. Persistent server-only narration cache

Migration `0041_product_conversational_intelligence.sql` adds a service-role-only cache keyed by:

`scope + scope key + source fingerprint + conversation contract version`

The cache:

- has RLS enabled;
- is inaccessible to `anon` and `authenticated` roles;
- validates payload lineage before persistence;
- limits payload size;
- expires stale explanations;
- creates no authority writer.

### 4. Customer surfaces now narrated

Grounded MarketRoute narration is now shown on:

- anonymous discovery progress;
- signed-in Command Centre;
- campaign overview;
- opportunity detail.

The deterministic progressive pipeline and existing intelligence views remain beneath the conversational explanation. Build 21 does not remove advanced evidence/audit surfaces; later product-language builds will continue moving internal mechanics behind progressive disclosure.

### 5. Dedicated narrator model support

Optional environment variable:

`OPENAI_NARRATOR_MODEL`

If omitted, narration uses `OPENAI_MODEL`.

This does not change the model used by Genesis research or other AI providers.

## Deliberately deferred

Product Build 21 does **not** implement:

- route/contact presentation redesign;
- free-eight entitlement;
- anonymous-to-account claiming;
- locked opportunities;
- billing;
- contextual free-form chat/commands;
- autonomous outbound delivery.

Those remain later product builds.

## Deployment

1. Run `APPLY-IN-SUPABASE-MARKETROUTE-V2-PRODUCT-BUILD21.sql` in the same V2 Supabase project.
2. Optional: add `OPENAI_NARRATOR_MODEL` in Vercel. If omitted, the current `OPENAI_MODEL` is used.
3. Deploy the Build 21 ZIP to Vercel.
4. Confirm `/discover` shows a MarketRoute conversational brief as the pipeline advances.
5. Sign in and confirm the Command Centre, campaign overview and opportunity detail show grounded narrative cards.

There is **no new required Vercel secret** in Build 21 beyond the Build 20 environment contract already deployed.

## Validation

- Product Build 21 static: **16/16 PASS**
- Product Build 21 adversarial: **9/9 PASS**
- Architecture boundary: **379/379 PASS**
- Build 18 release certification: **28/28 PASS**
- Build 18 full red-team replay: **22/22 PASS**
- Build 20 anonymous discovery: **24/24 + 8/8 PASS**
- Build 19 demand-driven Genesis: **21/21 + 4/4 PASS**
- AI boundary: **7/7 PASS**
- Canonical read model: **21/21 PASS**
- Core application UI: **29/29 PASS**
- Opportunity engine: **21/21 PASS**
- Research engine: **33/33 PASS**
- Changed TypeScript/TSX syntax transpile: **10/10 PASS**

A full local Next.js production compile was not available in the sandbox because the ZIP intentionally has no installed dependencies and dependency installation was unavailable. The user-verified Vercel compile remains the production compile gate.

## Product state after Build 21

MarketRoute now has the beginning of the intended experience:

**customer input → progressive engine work → grounded MarketRoute explanation → canonical evidence/authority underneath**

The next planned build is Product Build 22: **Opportunities, Routes & Contacts** — turning ready outputs into immediately usable commercial routes with visible/copyable email, always-present phone state, direct external links, best-route reasoning, alternatives and evidence/freshness.
