# MarketRoute V2

Constitutional rebuild of MarketRoute.

## Current release

**Build 3 — Evidence & Provenance Engine**

Build 3 introduces the first runtime data path: canonical source normalisation, immutable source identities, deterministic evidence/claim fingerprints, evidence-owned dependence families, transactional RPC-only persistence, duplicate handling and explicit claim supersession.

It still creates **zero commercial authority** and calculates **no Truth state**.

## Deploy Build 3

The fresh Supabase project already has Builds 1–2. Run only:

`APPLY-IN-SUPABASE-MARKETROUTE-V2-BUILD3.sql`

Then deploy this repository revision.

## Constitutional gate

```bash
npm run constitution:check
npm run typecheck
npm run build
```
