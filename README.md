# MarketRoute V2

Constitutional rebuild of MarketRoute.

## Current release

**Build 6 — Commercial Reality / R4**

Build 6 introduces the first commercial authority writer in MarketRoute V2: `marketroute.r4.commercial-reality`.

R4 consumes an exact current campaign seller-context selection, a reference-time `COMPANY_CORE_V1` Truth snapshot, and Truth snapshots for any supported HARD seller constraints. It emits only `COMMERCIAL_CANDIDATE`, `RESEARCH_REQUIRED`, or `NOT_ADMISSIBLE`.

No probability, confidence, weighted score, fit score, Truth Index threshold, support-strength threshold, or AI output may grant R4 authority. PostgreSQL independently reconstructs the R4 context, validates complete premise inclusion, re-derives all boundaries and the categorical decision, and computes both the reasoning input fingerprint and authority fingerprint.

R4 authority is time-bound to at most 24 hours and fails currentness immediately when its current seller selection changes or a consumed target claim receives a new claim, evidence link, or supersession.

Route authority (R5), contact authority (R6), opportunity workflow mutation, and execution permission still do not exist.

## Deploy Build 6

The fresh Supabase project already has Builds 1–5. Run only:

`APPLY-IN-SUPABASE-MARKETROUTE-V2-BUILD6.sql`

Then deploy this repository revision.

## Constitutional gate

```bash
npm run constitution:check
npm run typecheck
npm run build
```

## Next build

Build 7 introduces Relationship Truth + the canonical commercial graph / R5. Business-relationship premises must themselves become Truth-qualified before they can form a live route path.
