# MarketRoute V2

Constitutional rebuild of MarketRoute.

## Current release

**Build 18 — Red-Team Certification & Production Cutover + Production Activation 0.18.1**

MarketRoute V2 / Genesis T8 remains a **source-frozen production candidate**. Production Activation 0.18.1 wires the already-frozen provider/runtime boundaries to OpenAI Responses + web search, Vercel Cron and optional Resend delivery. It adds one isolated operational migration (`0020_production_activation_runtime.sql`) for new-workspace activation and adds no commercial-authority writer.

The authority writer set remains exactly three: **R4 Commercial Reality, R5 Route Authority and R6 Contact Authority**. AI owns semantics and language, not authority. The UI consumes canonical application reads and never reconstructs commercial decisions.

Run:

```text
npm run constitution:check
npm run certification:cutover-preflight
npm run production:check
```

After the Build 17 evidence migration and V2 recomputation, run the real-company proof with `npm run certification:live-lineage`. See `MARKETROUTE-V2-BUILD18-RED-TEAM-CERTIFICATION.md` and `PRODUCTION-CUTOVER-BUILD18.md`.

### Required server environment

Prefer current Supabase keys:

```text
SUPABASE_URL=
SUPABASE_SECRET_KEY=
SUPABASE_PUBLISHABLE_KEY=
OPENAI_API_KEY=
OPENAI_MODEL=gpt-5.6-luna
CRON_SECRET=
```

Legacy `SUPABASE_SERVICE_ROLE_KEY` + `SUPABASE_ANON_KEY` remain supported. No secret is exposed through `NEXT_PUBLIC_*`. See `PRODUCTION-ACTIVATION.md` for the complete Vercel, cron, OpenAI, Resend and smoke-test procedure.

## Build 17 — V1 evidence migration

Build 17 adds an offline, service-role-only V1 → V2 factual/evidence ETL. Use `migration/v1/README.md` for the export contract and migration workflow. No V1 authority, Truth state, scoring or workflow state is imported; V2 recomputes downstream intelligence from migrated evidence.

### Build 17 source export

For the pre-V2 Forensic Build 8 database, generate the static one-way factual export with `npm run migration:v1:export -- /secure/path/v1-export.json`. The exporter is GET-only and source-profile pinned; see `migration/v1/README.md`.


## Production growth activation

0.18.3 adds the V2-native Genesis Database Growth worker. It builds the shared global intelligence bank across the ten canonical industries independently of customer campaigns. See `MARKETROUTE-V2-GENESIS-DATABASE-GROWTH-0.18.3.md`.


## Production route hotfix 0.18.3.6

Repairs the Build 7 relationship-claim insert so `claims.fingerprint_version` is populated with the canonical `MRV2-CLAIM-FP-1.0.0` value. See `MARKETROUTE-V2-PRODUCTION-HOTFIX-0.18.3.6.md`.

## Product Build 21 — Conversational Intelligence

MarketRoute now narrates anonymous discovery, Command Centre, campaign and opportunity state through a grounded, cached AI explanation layer over canonical engine outputs. AI remains non-authoritative and cannot browse, invent evidence, or mutate Truth/R4/R5/R6/opportunity state. See `MARKETROUTE-V2-PRODUCT-BUILD21-CONVERSATIONAL-INTELLIGENCE.md`.

## Product Build 22 — Opportunities, Routes & Contacts

Authorised opportunities now expose actionable contact-route cards backed only by current R5/R6 state: named contacts and current roles, copyable email, an always-present phone row, click-to-call/email, professional/contact/company links, freshness and direct evidence links. Still-verifying paths are separated and redacted. See `MARKETROUTE-V2-PRODUCT-BUILD22-OPPORTUNITIES-ROUTES-CONTACTS.md`.

**Genesis Growth remains paused by Product Build 19.** Customer-demand research is the active product policy.

## Product Build 23 — Free Eight + Account Claim

Anonymous discovery now converts into a persistent free customer workspace without rerunning research. The first eight authority-ready opportunities are stored as permanent entitlements; exact contact values remain server-side until account claim, hidden opportunities are enforced server-side, and claimed discovery work may only finish within its original anonymous budget/window. Password recovery is also included. See `MARKETROUTE-V2-PRODUCT-BUILD23-FREE-EIGHT-ACCOUNT-CLAIM.md`.

## Product Build 24 — Locked Opportunities + Commercial Boundary

Discovery workspaces keep their first eight authority-ready opportunities while additional ready opportunities are exposed only as server-redacted locked teasers. Starter (£99), Growth (£249) and Scale (£599) now exist in a server-owned plan catalog, canonical reads/writes enforce the same commercial boundary, paid research capacity is enforced before new AI work is claimed, and existing pre-product customer workspaces are grandfathered. Billing is deliberately not connected yet; selecting a plan cannot grant access. See `MARKETROUTE-V2-PRODUCT-BUILD24-LOCKED-OPPORTUNITIES-COMMERCIAL-BOUNDARY.md`.

## Product Build 25 — Billing + Instant Unlock

Product Build 25 connects Stripe-hosted monthly subscriptions to the server-authoritative commercial entitlement layer. Run `APPLY-IN-SUPABASE-MARKETROUTE-V2-PRODUCT-BUILD25.sql`, configure the Build 25 Stripe environment variables from `.env.example`, and deploy. See `MARKETROUTE-V2-PRODUCT-BUILD25-BILLING-INSTANT-UNLOCK.md` for Stripe setup, webhook events, Customer Portal configuration, and test-mode verification.

## Product Build 26 — Full Product Experience

Product Build 26 converges the customer experience around a seven-stage progressive MarketRoute pipeline: Understand → Map → Discover → Research → Evaluate → Route → Ready. The authenticated Command Centre is pipeline/narrative-first, opportunity pages lead with explanation and actionable routes, contextual Q&A is grounded and read-only, customer research is expressed as capacity rather than provider spend, and the public site now carries the full discovery/pricing/support/legal funnel. Founder-only product economics add acquisition, MRR and AI-cost visibility without creating a new commercial-authority writer. Genesis Growth remains paused and autonomous outbound delivery remains off. See `MARKETROUTE-V2-PRODUCT-BUILD26-FULL-PRODUCT-EXPERIENCE.md`.
