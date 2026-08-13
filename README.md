# MarketRoute V2

Constitutional rebuild of MarketRoute.

## Current release

**Build 4 — Truth Engine V2**

Build 4 converts the evidence/provenance substrate into non-authoritative epistemic state. It introduces versioned Truth policies, independent-family corroboration, contradiction precedence, temporal freshness, claim Truth snapshots, explicit entity Truth profiles and the Truth Index as a maximin epistemic-readiness measure.

It still creates **zero commercial authority**. `truthProbability` remains `NULL` and `UNCALIBRATED`; no Truth metric grants commercial viability, route authority, contact authority or execution permission.

## Deploy Build 4

The fresh Supabase project already has Builds 1–3. Run only:

`APPLY-IN-SUPABASE-MARKETROUTE-V2-BUILD4.sql`

Then deploy this repository revision.

## Constitutional gate

```bash
npm run constitution:check
npm run typecheck
npm run build
```
