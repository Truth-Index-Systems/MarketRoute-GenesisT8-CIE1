# MarketRoute V2 — Product Build 26
## Full Product Experience

**Release family:** 0.18.3 (source-frozen intelligence constitution retained)  
**Productisation sequence:** Build 8 of 9  
**Migration:** `0046_product_experience_convergence.sql`

## Objective

Turn the already-working MarketRoute engine into one coherent customer product without altering Genesis/Truth/CIE commercial authority.

The customer experience is now organised around one visible progressive pipeline:

**Understand → Map → Discover → Research → Evaluate → Route → Ready**

The governing product rule remains:

> The engine determines reality. MarketRoute explains it. The customer experiences the intelligence rather than operating the intelligence engine.

Genesis Growth remains paused. Autonomous outbound delivery remains off.

---

## 1. Progressive authenticated Command Centre

The authenticated home is now pipeline-first rather than dashboard-first.

The customer sees:

- the market MarketRoute is currently working;
- the seven canonical stages;
- real persisted stage state rather than decorative percentages;
- MarketRoute's current explanation;
- current focus / what is happening now;
- ready opportunities;
- decisions requiring the customer;
- customer-facing market and research metrics.

Provider spend and low-level engine controls are not part of the default customer view.

---

## 2. One seven-stage product language

The same product progression is used across anonymous discovery and the signed-in product:

1. **Understand** — understand the seller and offering;
2. **Map** — establish the commercial market;
3. **Discover** — identify relevant organisations;
4. **Research** — establish commercial reality;
5. **Evaluate** — determine opportunity;
6. **Route** — establish viable people/channels into the organisation;
7. **Ready** — surface actionable opportunities.

Progress is derived from canonical activation/campaign/read-model state. Build 26 does not fabricate progress from timers or random percentages.

---

## 3. Conversational opportunity experience

Opportunity detail is now deliberately ordered:

1. MarketRoute explanation;
2. Ask MarketRoute;
3. ready actionable contact routes;
4. decision / next action;
5. engagement preparation;
6. advanced evidence and reasoning.

The default product therefore answers the customer's commercial questions before exposing internal mechanics.

### Ask MarketRoute

Authenticated users can ask contextual questions such as:

- Why is this worth pursuing?
- What are you still unsure about?
- Why this contact?
- What should I do next?

Free-text questions are also supported.

The Q&A layer:

- reads canonical opportunity and route state only;
- cannot independently browse for new commercial facts;
- cannot calculate or override CIE/Truth authority;
- cannot mutate evidence, routes, scores or workflow;
- accepts only evidence references already present in the supplied canonical state;
- uses the existing narration cache with the new `OPPORTUNITY_QA` scope;
- falls back to deterministic grounded explanation if narration fails.

### Safe conversational commands

Build 26 introduces only two bounded product commands from opportunity context:

- **Research this further**
- **Find another route**

These do not give the LLM write authority. They resolve into the existing server-validated `RETURN_TO_RESEARCH` workflow path and are rechecked against the existing entitlement and workflow boundaries.

---

## 4. Routes and contacts remain actionable

Build 22's route/contact authority is preserved and visually promoted.

For authorised routes MarketRoute continues to show:

- named contact and current role;
- plain-English route explanation;
- copyable email + email action;
- phone row always present;
- copy/call when a supported phone exists;
- explicit `Phone not found yet` when it does not;
- professional profile/direct route links where supported;
- company website;
- evidence and freshness.

Still-verifying routes remain separated and redacted.

---

## 5. Advanced evidence remains available

Build 26 simplifies the default product without deleting the intelligence system.

R4/R5/R6, Truth dimensions, fingerprints, provenance and structural route detail remain available inside an explicit **Evidence & reasoning** disclosure on opportunity detail.

The public site and default customer journey no longer lead with internal authority shorthand.

---

## 6. Customer research abstraction

The research page is now customer-facing.

Customers see concepts such as:

- research capacity;
- checks in progress;
- completed research;
- current research focus;
- why MarketRoute is checking something;
- decision blockers.

Customers no longer operate provider-dollar controls or see OpenAI budget mechanics as the primary product abstraction.

The server-side spend/capacity controls from Product Builds 19, 20 and 24 remain unchanged and authoritative.

---

## 7. Premium application visual system

Build 26 converges the authenticated application into a deeper MarketRoute dark/blue experience with:

- stronger command hierarchy;
- glass/depth surfaces;
- progressive pipeline as the visual spine;
- richer MarketRoute narrator treatment;
- opportunity spotlight cards;
- high-clarity upgrade surfaces;
- premium ready-route/contact presentation;
- responsive treatment for smaller screens.

The public acquisition site retains the lighter MarketRoute commercial identity so website → application feels like a deliberate transition rather than an unrelated redesign.

---

## 8. Public acquisition + pricing funnel

The homepage now presents the real product journey rather than internal architecture.

Primary proposition:

> Tell MarketRoute what you sell. It researches the market, identifies worthwhile opportunities and finds the routes into them.

The public product communicates:

- seven-stage workflow;
- one anonymous discovery;
- first eight opportunities free;
- direct route/contact outcome;
- Starter / Growth / Scale pricing from the server-owned product catalogue.

The public site includes direct links to:

- `/discover`
- `/pricing`
- `/privacy`
- `/terms`
- `/support`

No browser-owned price values were introduced.

---

## 9. Public support and legal shell

Build 26 adds first-class Privacy, Terms and Support pages so unrestricted acquisition has a visible product perimeter.

These documents are a product-ready baseline, not a legal certification. They should receive appropriate legal review before unrestricted live commercial launch, especially around B2B prospecting/contact data, privacy, electronic marketing and tax/payment configuration.

---

## 10. Founder product economics

A new service-role-only, read-only RPC:

`marketroute_product_economics_snapshot_v1`

adds product/economic visibility to the founder dashboard.

It exposes aggregate operational metrics including:

- anonymous discovery runs;
- claimed runs;
- claim rate;
- checkout attempts;
- checkout completions;
- checkout completion rate;
- active paid workspaces;
- plan mix;
- MRR in GBP;
- anonymous AI spend;
- average anonymous discovery AI cost;
- 30-day AI spend;
- 30-day paid-workspace AI spend.

This RPC is service-role only and has no intelligence or entitlement write path.

---

## 11. Constitutional boundaries unchanged

Build 26 does **not** add an intelligence authority writer.

The authority writer set remains frozen.

Build 26 does not:

- reactivate Genesis Growth;
- enable autonomous outbound delivery;
- allow AI to calculate commercial authority;
- allow Q&A to browse independently;
- allow customer commands to choose arbitrary workflow mutations;
- weaken paid/free opportunity redaction;
- expose exact locked contacts;
- move billing into the intelligence architecture.

---

## Deployment

### 1. Apply SQL first

Run:

`APPLY-IN-SUPABASE-MARKETROUTE-V2-PRODUCT-BUILD26.sql`

This:

- admits `OPPORTUNITY_QA` into the existing non-authoritative narration cache;
- installs the founder-only product economics snapshot;
- records Product Build 26 as a non-authoritative schema release.

### 2. Environment

**No new Vercel environment variables are required by Build 26.**

All previously required Product Build 20/25 environment remains required, including the anonymous-session secret and Stripe configuration where billing is enabled.

### 3. Deploy the Build 26 ZIP

Deploy the supplied Build 26 source ZIP to the existing Vercel project.

### 4. Smoke test

Before proceeding to Product Build 27 certification, verify:

1. Public homepage loads and `/discover` is the primary acquisition CTA.
2. Public pricing shows Discovery + £99 / £249 / £599 plans.
3. Privacy, Terms and Support pages load.
4. Anonymous discovery still progresses through persisted stages.
5. Signup/claim retains the same run and first-eight entitlement.
6. Signed-in home shows the seven-stage product pipeline.
7. Research page shows capacity rather than provider-dollar controls.
8. An unlocked opportunity shows explanation → Ask MarketRoute → ready routes.
9. Email/phone/contact actions remain R6-authorised only.
10. Contextual Q&A returns a grounded answer and cannot expose unsupported contact data.
11. `Research this further` and `Find another route` enter the existing bounded workflow.
12. Opportunity #9+ remains server-redacted for Discovery access.
13. Paid workspace remains unlocked after Build 25 Stripe reconciliation.
14. Founder dashboard loads the Product Economics section after migration.
15. Genesis Growth remains paused.
16. Autonomous delivery remains disabled.

---

## Validation status

Build 26 dedicated gates:

- Product Build 26 static: **20/20 PASS**
- Product Build 26 adversarial: **12/12 PASS**

Key retained gates after the experience rewrite:

- Architecture: **468/468 PASS**
- Build 25 billing: **17/17 + 12/12 PASS**
- Build 24 commercial boundary: **20/20 + 11/11 PASS**
- Build 23 free-eight/account claim: **17/17 + 9/9 PASS**
- Build 22 routes/contacts: **15/15 + 10/10 PASS**
- Build 21 conversation: **16/16 + 9/9 PASS**
- Build 20 discovery: **24/24 + 8/8 PASS**
- Build 19 demand-driven Genesis: **21/21 + 4/4 PASS**
- Build 18 release certification: **28/28 PASS**
- Full frozen red-team replay: **22/22 PASS**
- Founder dashboard validator: PASS
- Whole-source TS/TSX syntax transpilation: PASS
- Literal typed-icon scan: PASS
- CSS brace sanity: PASS

A genuine local Next.js production build could not be completed in this sandbox because dependency installation did not complete reliably. The Vercel production compile therefore remains the final compiler gate, as in the preceding product builds.

---

## Next build

**Product Build 27 — Production Certification & Hardening**

Build 27 should be feature-negative wherever possible. Its purpose is to attack the complete product end-to-end: unknown-business discovery, persistence, free-eight conversion, tenant isolation, contact authority, locked-data leakage, Stripe lifecycle, narrator hallucination, spend abuse, recovery and clean production compile/smoke certification.
