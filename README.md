# MarketRoute V2

MarketRoute V2 is a constitutional rebuild of MarketRoute: evidence-qualified commercial intelligence with no V1 runtime dependency and no compatibility layer.

## Current state — Build 2

Build 1 established repository and dependency law. Build 2 establishes the fresh Supabase persistence boundary.

- Evidence, reasoning, authority and workflow are separate storage domains.
- Canonical research data is backend-owned.
- Evidence and claim history are append-only.
- Authority storage exists but has **zero registered writers**.
- Direct authority DML is revoked from both clients and `service_role`.
- Opportunity workflow cannot be directly mutated yet.
- Scheduler leases, resumable jobs, job attempts, AI-cost telemetry and audit events exist as platform primitives.
- V1 runtime names and weighted commercial-authority columns are absent.

### Apply Build 2

Run `APPLY-IN-SUPABASE-MARKETROUTE-V2-BUILD2.sql` against the new Supabase project, then deploy the repository.

### Verify

```bash
npm run constitution:check
npm run typecheck
npm run build
```

The local audit environment may not have the installed Next/React dependency tree; Vercel is the final full framework compile gate when dependencies are unavailable locally.

Technical report: `MARKETROUTE-V2-BUILD2-CONSTITUTIONAL-SCHEMA.md`
