# MarketRoute V2

Constitutional rebuild of MarketRoute.

## Current release

**Build 5 — Seller Commercial Genome**

Build 5 adds the canonical first-party seller semantic model. It represents offerings, capabilities, commercial objectives, delivery, service geography, target characteristics, buyer assumptions and constraints while preserving explicit unknowns.

Machine-semantic meaning is separated from explanatory prose. Supabase independently validates the canonical semantic payload and computes both exact-content and semantic fingerprints. Campaigns bind to an exact genome snapshot and selected commercial objective through append-only, request-idempotent selection events.

AI may extract seller semantics but may not emit confidence, probability, fit, score, priority, viability or authority fields. Build 5 still creates **zero commercial authority** and leaves the authority writer registry empty.

## Deploy Build 5

The fresh Supabase project already has Builds 1–4. Run only:

`APPLY-IN-SUPABASE-MARKETROUTE-V2-BUILD5.sql`

Then deploy this repository revision.

## Constitutional gate

```bash
npm run constitution:check
npm run typecheck
npm run build
```

## Next build

Build 6 introduces Commercial Reality / R4 and therefore must be the first build to register a commercial authority writer. It will consume exact campaign seller context, target Truth and a versioned mandatory-boundary constitution; AI will not own viability.
