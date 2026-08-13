# MarketRoute V2 — Build 13
## Canonical Application API + Authoritative Read Model

Status: **BUILD COMPLETE — DEPLOYMENT CANDIDATE**  
Schema migration: `0016_canonical_application_read_model.sql`  
Application contract: `MRV2-APPLICATION-READ-1.0.0`

## Purpose

Build 13 creates the single server-side read contract that future MarketRoute UI surfaces consume. It does not add intelligence, authority, workflow transitions, engagement mutation, ranking, or execution permission.

The authority writer set remains exactly:

1. `marketroute.r4.commercial-reality`
2. `marketroute.r5.relationship-graph`
3. `marketroute.r6.contact-truth`

The application read model composes those existing current outputs and the already-authoritative lifecycle/opportunity/engagement predicates. It never reconstructs commercial authority from historical tables.

## Constitutional boundary

The required direction is:

```text
Evidence → Truth → R4 → R5 → R6
                         ↓
                Authority Lifecycle
                         ↓
                    Opportunity
                         ↓
                    Engagement
                         ↓
             Canonical Application Read
                         ↓
                    Future UI
```

The final arrow is presentation only.

Build 13 therefore enforces:

- no fourth authority writer;
- no database mutation in canonical read functions;
- no browser-direct authority/read-model RPC grant;
- no UI-side reconstruction of readiness;
- no weighted opportunity/route/contact score;
- no historical read masquerading as current state;
- no raw evidence embedded into broad command-centre/campaign/company payloads.

## New canonical server-side read resources

### `COMMAND_CENTRE`
RPC: `marketroute_application_command_centre_read_v1`

Returns the organisation and campaign-level canonical state by composing campaign reads. It does not independently infer opportunity readiness.

### `CAMPAIGN`
RPC: `marketroute_application_campaign_read_v1`

Returns:

- campaign identity/workflow;
- seller and selected Seller Genome context;
- scoped-company count;
- materialised-opportunity count;
- categorical lifecycle/disposition/workflow counts;
- current research policy/budget;
- engagement policy;
- canonical opportunity profiles.

Lifecycle/disposition metrics are derived across every explicit `CAMPAIGN` company scope rather than only materialised opportunities.

### `COMPANY_INTELLIGENCE`
RPC: `marketroute_application_company_read_v1`

Returns the complete product-facing current intelligence state:

- canonical opportunity profile;
- exact authority envelope and envelope fingerprint;
- current R4 record, boundary constitution, satisfied/unresolved boundaries and fingerprints;
- current R5 graph paths, structural access points and relationship-universe fingerprint;
- current R6 contact bindings, authorised paths/access points and contact-claim-universe fingerprint;
- the exact company Truth snapshot consumed by current R4;
- categorical Genesis research pressure and current research policy/budget;
- opportunity workflow history, human reviews and sync history;
- current engagement state;
- UI action predicates (`canReview`, `canGenerateEngagement`, `canExecute`, `requiresResearch`).

The Truth section is deliberately the exact Truth snapshot in current R4 lineage. Build 13 does not invent a weaker notion of "latest current Truth" when no current R4 exists.

### Engagement read
RPC: `marketroute_application_engagement_read_v1`

Composes current engagement state from Build 12 while delegating execution/currentness to existing predicates such as:

- `marketroute_opportunity_executable_now_v1`
- `marketroute_engagement_strategy_current_v1`

It exposes generation/review/approval/queue/delivery state without turning delivery state into commercial authority.

### `CLAIM_PROVENANCE`
RPC: `marketroute_application_claim_provenance_read_v1`

This is the bounded, on-demand evidence trace for the future provenance drawer.

The caller supplies an exact Truth claim snapshot ID. PostgreSQL first proves that the snapshot belongs to the **current authority lineage for the exact organisation + campaign + company**. Accepted locations are:

- R4 target company Truth entity claim map;
- R4 hard-constraint Truth snapshot map;
- R5 relationship Truth snapshot map;
- R6 Contact Truth snapshot map.

A guessed, unrelated, tenant-mismatched or historical snapshot outside the current lineage fails with:

`MARKETROUTE_APPLICATION_PROVENANCE_NOT_IN_CURRENT_LINEAGE`

Only after that proof does the read return the claim, Truth state and evidence/source provenance. Evidence is capped at 50 rows and reports truncation explicitly.

The provenance payload includes:

- polarity (`SUPPORTS` / `CONTRADICTS`);
- dependence-family key;
- evidence kind;
- excerpt/structured value;
- observed/origin publication times;
- extraction method/version;
- evidence fingerprint;
- source URL/domain/title/publication time;
- acquisition metadata;
- whether the item was a temporal anomaly relative to the exact Truth snapshot reference time.

Raw evidence is intentionally absent from broad read payloads and available only through this lineage-scoped endpoint.

## Current-time contract

All canonical reads call:

`marketroute_application_require_current_read_time_v1`

A read presented as current must be within five minutes of PostgreSQL `now()`. This prevents a client from replaying an old timestamp and presenting a historically valid authority envelope as present-tense product state.

Historical forensic records remain stored, but Build 13's application contract is a current-state contract.

## Server-side only

Canonical read functions are:

- `SECURITY DEFINER`;
- fixed `search_path=public,pg_temp`;
- `service_role` only;
- revoked from `PUBLIC`, `anon` and `authenticated`.

Build 13 deliberately does not introduce browser-to-Supabase authority access. Future Next.js UI/API transport must resolve the authenticated user/organisation scope server-side and then call `ApplicationReadService`.

## Application architecture

New application modules:

- `application/read-model/contracts.ts`
- `application/read-model/validation.ts`
- `application/read-model/service.ts`
- `application/read-model/index.ts`

New platform adapter:

- `platform/database/application-read-repository.ts`

The platform repository returns `unknown` JSON and has no dependency on the application layer. The application layer owns type validation. This preserves the Build-1 dependency constitution (`platform` may not import `application`).

## Legacy/scoring quarantine

The read validator recursively rejects fields whose normalised names correspond to historical authority/scoring concepts including:

- opportunity score;
- company/business fit;
- route quality/confidence;
- viability;
- overall confidence;
- engagement confidence;
- match labels / fit breakdowns.

This is recursive, so a forbidden score cannot be hidden inside an array, diagnostic object or provenance payload.

Legitimate epistemic diagnostics remain allowed, including:

- Truth Index;
- evidence sufficiency;
- freshness;
- coherence;
- categorical lifecycle state.

## UI implication

Build 14/15 should not query raw R4/R5/R6 tables or recompute READY states. The UI should render the canonical application contract.

This gives the future blue MarketRoute interface one stable source for components such as:

- AuthorityBadge;
- TruthGauge;
- RelationshipPath;
- ContactAuthority;
- ResearchPressure;
- Invalidation/Workflow timeline;
- ProvenanceDrawer;
- Engagement state.

## Database safety

Migration `0016`:

- creates no tables;
- drops no tables/views/functions/schemas;
- performs no authority DML;
- performs no opportunity/workflow DML;
- performs no engagement DML;
- only creates/replaces new Build-13 read functions and records the schema release.

No existing `RETURNS TABLE` signature is changed, so the Build-3 `42P13` class is not introduced here.

## Certification

Final Build-13-specific gates:

- static read-model checks: **21 / 21**
- SQL safety checks: **16 / 16**
- application contract adversarial checks: **17 / 17**
- database/read-boundary adversarial checks: **35 / 35**

Full Builds 1–13 constitutional regression:

**1,456 / 1,456 PASS across 52 suites**

Additional gates:

- strict changed-module TypeScript compile: **PASS**
- whole-source TS/TSX transpilation: **68 / 68 PASS**
- standalone SQL equals canonical migration `0016`: **PASS**

## Known intentional limits

1. Build 13 does not create public/authenticated HTTP routes. Authenticated transport belongs with the application shell/UI work; the canonical server contract is established first.
2. The broad company payload exposes the Truth snapshot used by current R4. When no current R4 exists, it does not label an arbitrary historical Truth snapshot as current.
3. Raw evidence is intentionally on-demand and capped at 50 rows per provenance request.
4. Build 13 changes no R4/R5/R6 semantics and adds no ranking.

## Deployment

1. Run `APPLY-IN-SUPABASE-MARKETROUTE-V2-BUILD13.sql` against the existing V2 Supabase project.
2. Deploy the Build-13 application ZIP to Vercel.
3. Confirm the Vercel compile and then proceed to Build 14 — MarketRoute Design System + Application Shell.
