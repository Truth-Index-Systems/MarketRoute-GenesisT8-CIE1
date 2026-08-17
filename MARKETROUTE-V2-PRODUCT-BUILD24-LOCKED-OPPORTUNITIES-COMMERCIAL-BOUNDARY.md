# MarketRoute V2 — Product Build 24
## Locked Opportunities + Commercial Boundary

**Release family:** 0.18.3  
**Productisation sequence:** Build 6 of 9  
**Authority status:** Truth / R4 / R5 / R6 / Opportunity semantics unchanged  
**Genesis Growth:** paused by design  
**Outbound autonomous delivery:** remains disabled by product policy

## Purpose

Product Build 24 creates the commercial access boundary that sits outside MarketRoute's intelligence authority.

The first eight authority-ready opportunities from a claimed anonymous discovery remain permanently accessible. Any additional authority-ready opportunities are represented to a Discovery workspace only by a server-generated safe teaser. Full company intelligence, reasoning, evidence, route data, contact data, exact emails, exact phone numbers, professional links and narration do not cross the boundary until the workspace has a paid/full entitlement.

This build deliberately does **not** connect a payment provider. Build 25 will attach billing lifecycle to the entitlement layer created here.

## Product behaviour

### Discovery workspace

- First eight persisted opportunity entitlements remain fully accessible.
- Opportunity 9+ may appear as `READY_LOCKED` teasers.
- The opportunities page shows how many additional routes are waiting.
- Clicking a locked card opens the in-product plan chooser.
- A guessed locked opportunity URL resolves to a locked safe preview before any canonical company/route/provenance read occurs.
- A hidden write/API call against a locked opportunity is denied by the same commercial access service.
- Free discovery cannot create another live market/campaign.

### Paid/full workspace

- `STARTER`, `GROWTH`, `SCALE` and grandfathered `LEGACY_FULL` entitlements receive full opportunity access.
- Paid research planning is constrained by server-side plan research capacity.
- Capacity exhaustion defers new expensive research work before provider execution.
- One active market remains the launch architecture.

### Existing pre-product workspaces

Existing CUSTOMER workspaces that were not created by claimed anonymous discovery are grandfathered into `LEGACY_FULL` so Product Build 24 does not unexpectedly lock existing production/founder data.

Claimed Discovery workspaces are explicitly excluded from this grandfathering path.

## Plan catalog

The database now owns the launch plan catalog:

| Plan | Monthly price | Launch role |
|---|---:|---|
| Starter | £99 | Founder-led sales |
| Growth | £249 | Recommended / active pipeline building |
| Scale | £599 | Higher-capacity teams |

The current internal research capacity values are **provisional server-side controls**:

- Starter: 100 research work units
- Growth: 400 research work units
- Scale: 1,200 research work units

These values are deliberately database-configurable and are not presented as customer-facing promises such as “100 companies”. They should be calibrated against observed unit economics before public launch.

## Commercial authority model

The payment provider will not own product semantics.

The intended Build 25 relationship is:

`billing event -> commercial entitlement -> MarketRoute access/research capacity`

Billing must never write:

- Truth snapshots
- R4 authority
- R5 authority
- R6 authority
- Opportunity commercial state
- Evidence/provenance

Plan selection in this build is presentation-only. It does not charge the user and cannot grant an entitlement.

## Database changes

Migration:

`0044_product_locked_opportunities_commercial_boundary.sql`

Adds:

- `marketroute_plan_catalog`
- `organisation_commercial_entitlements`
- `marketroute_paid_entitlement_active_v1`
- `marketroute_research_capacity_snapshot_v1`
- `marketroute_public_plan_catalog_v1`
- `marketroute_workspace_commercial_access_v1`

Also hardens:

- research planning targets
- research work claiming
- direct workspace activation
- replacement campaign creation

The migration registers:

`MARKETROUTE_V2_PRODUCT_BUILD24_LOCKED_OPPORTUNITIES_COMMERCIAL_BOUNDARY`

with `new_authority_writer=false`.

## Safe locked teaser contract

A Discovery browser may receive only a bounded safe teaser for a locked opportunity:

- opportunity ID
- company ID
- company name
- canonical public domain
- discovery timestamp
- `READY_LOCKED` state

It does **not** receive:

- email
- phone
- person/contact identity
- LinkedIn/professional URL
- contact-form/private route URL
- evidence payload
- provenance payload
- commercial reasoning
- conversational narration

CSS blur is therefore presentation only, never the entitlement/security boundary.

## Application changes

New commercial access layer:

- `platform/database/commercial-access-repository.ts`
- `application/commercial/service.ts`

Customer-facing commercial UI:

- `ui/application/commercial-upgrade.tsx`
- `/app/plans`
- Plan navigation entry
- Locked opportunity feed
- Locked opportunity detail/paywall
- Command Centre and campaign upgrade notices

Canonical read/write services now consult the same commercial access projection, preventing URL/API bypasses.

## Acquisition hardening

Generic self-serve signup is no longer a path to an empty unentitled workspace.

- `/signup` without a Discovery claim redirects to `/discover`.
- Signup requires the existing anonymous discovery claim context.
- `/preview` and login new-user CTAs route into Discovery.
- This preserves the agreed acquisition funnel: value first, account after contact intent, payment after continuing value.

## Validation

Product Build 24:

- Static: **20/20**
- Adversarial: **11/11**

Backwards product gates:

- Build 23: **17/17 + 9/9 adversarial**
- Build 22: **15/15 + 10/10 adversarial**
- Build 21: **16/16 + 9/9 adversarial**
- Build 20: **24/24 + 8/8 adversarial**
- Build 19: **21/21 + 4/4 adversarial**

Frozen intelligence/runtime gates:

- Architecture: **418/418**
- R5: **46/46 + 31/31 adversarial**
- R6: **27/27 + 25/25 adversarial**
- Research: **33/33 + 21/21 adversarial**
- Opportunity: **21/21 + 25/25 adversarial**
- Engagement: **27/27 + 26/26 adversarial**
- Production activation: **22/22**
- Release certification: **28/28**
- Full red-team replay: **22/22**
- TypeScript/TSX syntax transpilation: **154/154**

A full local Next.js typecheck cannot be honestly certified from this source bundle because the sandbox does not contain the installed Next/React/Node type dependencies. The remaining local `tsc` diagnostics are dependency/type-environment related; the production Vercel build remains the compile gate, as with preceding product builds.

## Deployment

1. Run `APPLY-IN-SUPABASE-MARKETROUTE-V2-PRODUCT-BUILD24.sql` in the current Supabase project.
2. Confirm the migration succeeds completely.
3. Deploy the Build 24 ZIP to Vercel.
4. Verify existing founder/pre-product workspaces still show full access.
5. Verify a claimed Discovery workspace still shows its first eight and locked teasers for later ready opportunities.
6. Click a locked opportunity and confirm plans open but **no access is granted and no charge occurs**.
7. Confirm Growth remains paused and outbound delivery remains disabled.

## Environment

No new Vercel environment variable is required by Build 24.

Existing Product Build 20 requirement remains:

`MARKETROUTE_ANONYMOUS_SESSION_SECRET`

## Next build

**Product Build 25 — Billing + Instant Unlock**

Build 25 should connect the chosen payment provider to the commercial entitlement layer, implement secure checkout + webhook reconciliation + subscription lifecycle, and make successful payment activate access without restarting research or changing any intelligence authority.
