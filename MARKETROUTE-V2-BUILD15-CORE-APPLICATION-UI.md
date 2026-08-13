# MarketRoute V2 — Build 15
## Core Application UI

### Status

Build 15 converts the Build-14 design-system preview into the first live MarketRoute V2 application. It is built on the canonical Build-13 server-side read model and preserves the complete Builds 1–14 constitution.

No new commercial authority is introduced. The authority registry remains exactly:

1. `marketroute.r4.commercial-reality`
2. `marketroute.r5.relationship-graph`
3. `marketroute.r6.contact-truth`

The UI is a presentation and action-orchestration layer. It cannot derive Truth, recreate R4/R5/R6, rank opportunities with a weighted score, or grant execution permission.

---

## 1. Live product architecture

Build 15 replaces the sample `/app` preview with real authenticated application surfaces:

- `/app` — Founder Command Centre
- `/app/campaigns`
- `/app/campaigns/[campaignId]`
- `/app/companies`
- `/app/opportunities`
- `/app/opportunities/[campaignId]/[companyId]`
- `/app/research`
- `/app/engagement`
- `/login`
- `/onboarding`

The public root `/` remains reserved for Build 16's full MarketRoute acquisition experience.

Every intelligence page obtains state through `ApplicationReadService`; the React surface never directly calls Supabase or imports database/authority kernels.

---

## 2. Authentication and workspace boundary

Build 15 introduces server-mediated Supabase Auth without exposing the service-role key to the browser.

### Authentication flow

`platform/auth/supabase-auth.ts` talks to Supabase Auth from the server using the anon key. Access and refresh tokens are stored in HTTP-only cookies:

- `mr_access_token`
- `mr_refresh_token`
- `mr_org_id`

Cookies use `SameSite=Lax`; Secure is enabled on HTTPS deployments.

The server resolves the authenticated Supabase user, then loads active organisation memberships with the server-side workspace repository. A tampered workspace cookie cannot create access because the requested organisation must exist in the authenticated user's active membership set.

### Role boundary

`OWNER`, `ADMIN` and `MEMBER` can use operational mutation routes currently exposed by the UI.

`VIEWER` is strictly read-only. Build 15 enforces this twice:

1. mutation controls are hidden in the Opportunity Workspace;
2. server mutation routes call `assertOpportunityWriteScope`, which rejects `VIEWER` even if a request is manually forged.

### First workspace

An authenticated user with no organisation is sent to `/onboarding`. Workspace creation uses the authenticated user-token RPC `marketroute_create_organisation`, preserving `auth.uid()` ownership semantics rather than creating a workspace through the service role.

Build 15 does not add public account signup. An existing Supabase Auth user is required for this build; public signup/acquisition is reserved for Build 16.

---

## 3. Canonical application read extensions — migration 0017

Build 13 intentionally created point reads. A live multi-page product also needs safe list/index reads, so Build 15 adds five read-only RPCs:

### `marketroute_application_company_index_read_v1`

Lists all companies explicitly scoped to a campaign and obtains each company's state through the canonical Opportunity profile. It does not infer commercial status from historical table columns.

### `marketroute_application_research_activity_read_v1`

Returns current research policy and budget plus recent plans, work units, latest attempts and scheduler runs. It is observability only; it cannot create or mutate research work.

### `marketroute_application_engagement_index_read_v1`

Lists materialised campaign opportunities and uses the Build-13 canonical engagement read for each.

### `marketroute_application_provenance_claim_index_v1`

Discovers Truth snapshots present in the exact current authority lineage across:

- R4 core company Truth;
- R4 hard-constraint Truth;
- R5 relationship Truth;
- R6 Contact Truth.

It returns claim/snapshot metadata only. Raw evidence remains behind the existing Build-13 lineage-scoped provenance RPC.

### `marketroute_application_route_display_read_v1`

Maps current R5 path node IDs to canonical display labels and marks which paths are authorised by current R6. It does not create graph topology or decide path authority.

All five RPCs are:

- `SECURITY DEFINER`;
- service-role only;
- unavailable to `PUBLIC`, `anon` and `authenticated`;
- current-time bounded through the Build-13 read-time guard;
- read-only with respect to intelligence, workflow, research and engagement.

The browser never receives permission to call them directly.

---

## 4. Founder Command Centre

The Command Centre now renders the real canonical organisation/campaign read model.

It gives the founder a top-level view of:

- campaign population;
- current commercial state;
- actionable opportunities;
- research pressure;
- opportunity/workflow state;
- current intelligence health.

It deliberately does not create replacement dashboard scores.

---

## 5. Campaigns and Companies

### Campaign pages

Campaign screens expose the selected commercial context, population and current intelligence summary using the canonical campaign model.

### Companies index

The Companies workspace includes all explicit campaign company scopes, not only companies that have already become materialised opportunities. This matters because MarketRoute must make unresolved/researching companies visible rather than disappearing them from the product until they are actionable.

Each company row carries the canonical categorical disposition and current intelligence state.

---

## 6. Flagship Opportunity Workspace

The Opportunity Workspace is the centrepiece of Build 15.

For one company it presents, without frontend inference:

### Truth

- entity state;
- Truth Index;
- current coverage;
- evidence sufficiency;
- freshness;
- coherence;
- probability calibration state.

The screen explicitly labels this as epistemic quality rather than probability.

### Authority chain

- R4 Commercial Reality;
- R5 Route Authority;
- R6 Contact Authority;
- current envelope fingerprint;
- next revalidation boundary.

### Route intelligence

Current R5 paths are rendered as actual canonical graph nodes — company, organisational unit, person and channel — with current R6 authorisation shown separately.

The UI does not infer that a path is authorised merely because it contains a person or channel.

### Research pressure

Current Genesis gap candidates are shown categorically from the canonical research context.

### Human workflow

Founder workflow remains visibly separate from authority. When the canonical application model permits review, OWNER/ADMIN/MEMBER users can:

- APPROVE;
- REJECT;
- RETURN TO RESEARCH.

The server action authenticates the user, verifies workspace + opportunity scope, rereads the canonical company model and then calls the Build-9 lifecycle service.

### Engagement

Existing strategy/message/review/delivery state is shown from Build 13. Where permitted by the canonical engagement actions, authorised non-viewer users can approve/reject the current message or queue it.

The server rereads the exact current message/action state before mutating anything. Queueing is not reconstructed in React.

---

## 7. Provenance Drawer

Build 15 adds the first live forensic evidence experience.

The Opportunity Workspace first discovers only claim snapshots that belong to the current R4/R5/R6 lineage. Selecting one calls the Build-13 `CLAIM_PROVENANCE` read for the exact snapshot.

The drawer can show:

- Truth state;
- snapshot and proposition fingerprints;
- support/contradiction polarity;
- evidence/source identity;
- dependence family;
- observation/publication time;
- source URL/domain;
- bounded excerpts/structured evidence.

The broad application model still does not carry raw evidence. Provenance is fetched only on explicit drill-down and remains lineage-scoped and bounded.

---

## 8. Research workspace

The Research page exposes the real autonomous Genesis operating state:

- campaign research policy;
- daily budget state;
- recent research plans;
- work units;
- current job states;
- latest attempts;
- scheduler runs.

This is observability, not a second research scheduler. Build 10 remains the sole autonomous research owner.

---

## 9. Engagement workspace

The Engagement workspace shows the actual Build-12 pipeline across opportunities:

- policy mode;
- strategy;
- categorical AI review;
- human/autopilot approval;
- queue state;
- delivery state.

No numeric language-quality value can become execution permission in the UI.

---

## 10. Presentation constitution

Build 15 preserves these boundaries:

- browser code cannot use the Supabase service-role key;
- UI cannot call PostgREST directly;
- UI cannot import `core/authority` or database repositories;
- application pages consume the canonical Build-13 contract;
- service-role read RPCs remain server-only;
- frontend code contains no numeric commercial authority threshold;
- no legacy opportunity/fit/route confidence score can enter the live UI contract;
- mutation routes authenticate, scope-check and reread canonical state;
- VIEWER memberships are read-only;
- no fourth authority writer is introduced.

---

## 11. Environment

Required on Vercel/server runtime:

```text
SUPABASE_URL=
SUPABASE_SERVICE_ROLE_KEY=
SUPABASE_ANON_KEY=
```

`NEXT_PUBLIC_SUPABASE_ANON_KEY` is accepted as an anon-key fallback. The implementation nevertheless keeps auth calls server-mediated in Build 15.

The service-role key must remain server-only.

---

## 12. Validation

Final full constitutional regression:

**1,678 / 1,678 PASS across 56 suites.**

Build-15-specific gates:

- **29/29** core application UI static checks;
- **18/18** live UI adversarial/security checks.

Additional release gates:

- strict TypeScript check with temporary Next/React environment shims: **PASS**;
- whole V2 TypeScript/TSX syntax/transpilation: **117/117 PASS**;
- standalone Build-15 installer equals canonical migration `0017`: **PASS**;
- authority writer count remains **3**;
- Build-15 SQL introduces no authority/workflow/research/engagement mutation.

A full local `next build` could not be executed because dependency installation timed out in the isolated build environment. Vercel therefore remains the final framework/dependency compilation gate, as in prior UI builds.

---

## 13. Deployment order

1. Apply `APPLY-IN-SUPABASE-MARKETROUTE-V2-BUILD15.sql` / migration `0017_core_application_ui_read_indexes.sql`.
2. Ensure the three required Supabase environment variables are configured in Vercel.
3. Ensure at least one Supabase Auth user exists for testing.
4. Deploy the Build-15 ZIP.
5. Sign in at `/login`; a user with no organisation will be taken through `/onboarding`.

---

## 14. Build 16 boundary

Build 16 owns the full public MarketRoute website and acquisition flow. It should preserve the Build-14/15 blue visual system and make the commercial proposition immediately obvious before introducing Genesis technical depth.

Build 15 intentionally stops at the authenticated product boundary.
