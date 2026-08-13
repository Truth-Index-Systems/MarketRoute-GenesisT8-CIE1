# MarketRoute V2 — Build 14
## Design System + Application Shell

Status: **BUILD COMPLETE — PRESENTATION ONLY**

Build 14 establishes the visual and navigational foundation for MarketRoute V2. It changes no Truth rule, authority rule, workflow rule, research rule, engagement rule, database function, table, policy, or migration.

## Constitutional boundary

Build 14 introduces **zero new authority writers**. The only authority writers remain:

1. `marketroute.r4.commercial-reality`
2. `marketroute.r5.relationship-graph`
3. `marketroute.r6.contact-truth`

The UI cannot import `platform/database`, `platform/ai`, or `core/authority`. The Next.js route layer cannot import database or core authority code. Build 14 contains no Supabase client, service-role environment access, `.rpc(...)`, `.from(...)`, or direct evidence/authority query.

## Route architecture

- `/` — public acquisition/front-door route. Build 14 provides only a compact preview; the complete landing page is Build 16.
- `/app` — permanent product namespace and application shell.
- `/design-system` — temporary Build-14 component/brand reference.

Future product pages will live beneath `/app/...`.

## MarketRoute visual identity

The V2 product remains visually distinct from the Truth Index Systems corporate crimson brand.

Primary palette:

- MarketRoute blue — `#2F8CFF`
- Soft blue — `#76B6FF`
- Deep blue — `#0C65CF`
- Near-black workspace — `#05080D`

The interface uses restrained blue luminance, low-contrast intelligence grids, precise borders, compact categorical labels, large editorial headings and route-line visualisation. Status colours are presentation only and cannot create semantic state.

## Component foundation

### Brand
- `MarketRouteLogo`
- reusable route-mark SVG

### Shell
- `AppShell`
- desktop sidebar
- sticky product top bar
- mobile navigation
- permanent `/app` namespace
- future Build-15 navigation states

### Primitives
- `Panel`
- `SectionHeading`
- `StatusBadge`
- `MetricCard`
- `Button`
- `ButtonLink`
- shared icon library

### Intelligence presentation
- `TruthGauge`
- `AuthorityStack`
- `RoutePath`
- `ResearchPressure`
- `ProvenanceTrail`

These components display supplied values only. They do not calculate Truth, authority, workflow, research priority or execution permission.

## Product language

The first user-facing statement is deliberately commercial rather than architectural:

> Know who to target. Know why. Know the route in.

Supporting copy explains that MarketRoute researches a market, qualifies commercial reality and maps evidence-backed routes to people and channels worth pursuing.

Technical language remains available inside the product where it improves explainability, but it is not required to understand the product's value.

## Preview-data rule

The `/app` Build-14 screen uses representative sample values only to exercise the visual system. It is explicitly labelled:

**Design system preview — Non-authoritative sample data · Build 14**

Build 15 must replace this preview with the canonical Build-13 application read contract. It must not connect these UI components directly to Supabase or rebuild R4/R5/R6 logic in React.

## Responsive/accessibility foundation

Build 14 includes:

- desktop/sidebar layout;
- tablet layout;
- mobile product navigation;
- 390px small-screen handling;
- route-path vertical reflow on mobile;
- keyboard `:focus-visible` treatment;
- `prefers-reduced-motion` handling;
- accessible navigation labels;
- explicit disabled future navigation state.

## Database impact

**None.**

There is intentionally no `0017` migration in Build 14. The latest schema migration remains Build 13's `0016_canonical_application_read_model.sql`.

## Verification

Build-14-specific:

- Design-system/application-shell static gate: **37/37 PASS**
- Presentation-boundary adversarial gate: **23/23 PASS**

Full MarketRoute V2 constitutional regression:

- **1,537 / 1,537 PASS**
- **54 suites**

Compile/static gates:

- Strict changed presentation-module TypeScript compile with environment type shim: **PASS**
- Whole V2 TS/TSX syntax transpilation: **86/86 PASS**
- No new Supabase migration: **PASS**

A complete Next.js production build was not run locally because dependency installation is unavailable/timed out in the isolated build environment. Vercel remains the final full framework compile gate, consistent with previous builds.

## Build 15 handoff

Build 15 is **Core MarketRoute Application UI**.

It should:

1. replace all Build-14 preview data with authenticated server-side Build-13 canonical application reads;
2. enable navigation for Command Centre, Campaigns, Companies, Opportunities, Research and Engagement;
3. build the flagship Opportunity workspace;
4. add the bounded current-lineage Provenance Drawer;
5. preserve the Build-14 visual system rather than introducing a second component language;
6. keep UI logic presentational and prohibit frontend authority reconstruction.
