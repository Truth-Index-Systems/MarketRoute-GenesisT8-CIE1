# MarketRoute V2 — Product Build 20
## Anonymous Discovery + Progressive Pipeline

**Baseline:** Product Build 19 — Demand-Driven Genesis (`0.18.3` lineage)

## Purpose
Build 20 creates the first real product acquisition journey without changing Truth, CIE/UDOSIB, R4/R5/R6 authority, opportunity mathematics, or engagement authority.

A visitor can now enter a company and offering without an account. MarketRoute creates an isolated pre-auth discovery workspace, runs the existing bank-first customer activation path, and displays persisted progress through the canonical product stages:

1. Understand your business
2. Map your market
3. Find relevant organisations
4. Research the strongest companies
5. Evaluate opportunities
6. Find routes in
7. Ready to pursue

This build deliberately does **not** expose contact details, implement the free-eight entitlement, claim a run into an account, or add billing. Those remain later product builds.

## Product behaviour
- Landing-page primary CTAs now enter `/discover`.
- No account is required to start one free discovery run.
- The run is persisted server-side and resumes after refresh/navigation using an HttpOnly browser token.
- Progress is derived from persisted activation, research, opportunity, R5, and R6 state. There are no decorative/fake progress percentages in the new pipeline UI.
- Existing Genesis intelligence is checked first; web discovery is used only where the business-specific market requires it.
- Growth remains paused and unscheduled.
- Bootstrap cadence is now every minute and research cadence every two minutes for a viable interactive discovery experience.

## Security / cost boundary
- Anonymous workspaces are explicitly marked `ANONYMOUS_DISCOVERY` and have no fabricated authenticated user.
- Anonymous rows receive no browser database grants; public status is server-mediated through `/api/discovery/status`.
- Browser and coarse network identifiers are stored only as keyed HMAC hashes; raw IP addresses are not persisted.
- One run is canonical per browser identity, with an additional coarse network-rate ceiling.
- Research has an all-time anonymous budget. It does not reset at midnight.
- Research is time-bounded and expired runs cannot plan or claim new research work.
- Anonymous jobs are concurrency-limited and have a lower per-job ceiling.
- Public progress payloads intentionally omit emails, phone numbers, contact data, AI spend, reservations, and internal budget values.
- No new commercial authority writer exists in this build.

## Deployment order
### 1. Add required Vercel environment variable
Before testing `/discover`, add:

`MARKETROUTE_ANONYMOUS_SESSION_SECRET=<at least 32 random characters>`

A 64-character random hex secret is appropriate. Keep it stable after launch; changing it invalidates existing anonymous browser identities.

Optional anonymous policy values are documented in `.env.example`. Defaults are:
- research lifetime budget: `$3`
- research window: `24h`
- initial target count: `12`
- max research job cost: `$0.35`
- max concurrent anonymous research jobs: `1` (hard-coded product policy)
- work units per plan: `3`

### 2. Apply Supabase migration
Run the root file:

`APPLY-IN-SUPABASE-MARKETROUTE-V2-PRODUCT-BUILD20.sql`

This is migration `0040_product_anonymous_discovery_pipeline.sql`.

### 3. Deploy the application ZIP to Vercel
The Vercel schedules become:
- bootstrap: every minute
- research: every two minutes
- delivery: every two minutes (delivery kill-switch behaviour unchanged)
- Growth: not scheduled

### 4. Smoke test
Use a business not already present in Genesis where possible:
1. Open `/discover` in a fresh browser.
2. Enter company name, website, and offering; leave target market blank once to test inference/default targeting.
3. Confirm the same run survives refresh and navigation.
4. Confirm the pipeline progresses from real engine state.
5. Confirm the founder dashboard shows the activation/research activity.
6. Confirm a second submission in the same browser reuses the run rather than creating new paid research.
7. Confirm no contact data is returned by `/api/discovery/status`.

## Validation
Passed locally in the supplied sandbox:
- Product Build 19 static: **21/21**
- Product Build 19 adversarial: **4/4**
- Product Build 20 static: **24/24**
- Product Build 20 adversarial: **8/8**
- Architecture boundary: **363/363**
- Production activation: **22/22**
- Core UI: **29/29**
- Core UI adversarial: **18/18**
- Public website: **11/11**
- Public website adversarial: **7/7**
- Build 18 release certification: **28/28**
- Build 18 full red-team replay: **22/22**
- Research engine static: **33/33**
- Research adversarial: **21/21**
- Opportunity engine static: **21/21**
- Engagement engine static: **27/27**

Changed TypeScript/TSX files pass TypeScript transpilation/syntax diagnostics. A complete local `tsc --noEmit` cannot be certified in this sandbox because the provided ZIP contains no installed Next/React/Node type packages; the only remaining local diagnostics on Build 20 files are missing dependency typings/JSX typings. Vercel compilation is the authoritative compile gate, as with Product Build 19.

## Deferred by design
Build 20 does not implement:
- AI conversational narrator (Build 21)
- opportunity/contact panels (Build 22)
- first-eight free entitlement and anonymous-run account claim (Build 23)
- locked opportunity feed / plans (Build 24)
- billing (Build 25)

Outbound autonomous delivery remains off.
