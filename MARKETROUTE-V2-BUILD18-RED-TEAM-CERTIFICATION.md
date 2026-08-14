# MarketRoute V2 / Genesis T8 — Build 18 Red-Team Certification & Production Cutover

## Status

**SOURCE FROZEN PRODUCTION CANDIDATE**

Build 18 is deliberately not a feature release. It certifies the exact compiled Build 17 candidate and adds no commercial reasoning, authority writer, application feature, presentation change, or database migration.

Source candidate SHA-256:

`c5dd0cc7950b1be8824c24b40f4c9b9c4bc5cb74d206e44bf823d0804fab4e5e`

## Frozen constitutional state

- Authority writers: exactly **3**.
  - R4 Commercial Reality
  - R5 Route Authority
  - R6 Contact Authority
- Schema owner: **Build 17** / migration `0019_v1_evidence_migration.sql`.
- Presentation owner: **Build 16** public acquisition experience, with the Build 15 application UI and later UI polish retained.
- Build 18 database migration: **none**.
- V1 runtime compatibility: **none**.
- AI commercial authority: **forbidden**.
- Weighted opportunity authority: **forbidden**.
- Send permission: derived only after a live send-time authority recheck.

## Certification attack families

### Architecture

The final repository is searched for prohibited imports, undeclared authority writers, browser/database coupling, frontend authority reconstruction, V1 compatibility paths and direct runtime authority bypasses.

### Epistemics

The full Truth attack suite is replayed, including weak support, dependence-family collapse, contradiction, stale evidence, undated evidence and categorical state integrity. Evidence strength remains distinct from probability.

### Relationship and contact truth

The final R5/R6 suites replay reversed directed edges, unsupported graph premises, wrong-company contact identity, stale employment/role, channel ownership mismatch, personal-route requirements and organisational routes that require no invented person.

### Authority lifecycle and workflow

The final state-machine suite replays stale authority after approval, revalidation without workflow erasure, current-envelope checks and the rule that `APPROVED` alone never means executable.

### Research and AI

Provider output resembling score, confidence, probability, rank, weight, viability or authority is rejected recursively. Research result text has no privileged code-execution path. Provider output must return through evidence/relationship/contact ingestion before deterministic authority can change.

### Opportunity

Opportunity remains a projection of the current R4 → R5 → R6 chain. Numeric metadata cannot create or reorder authority. Pareto comparison remains product ordering only among already-actionable opportunities.

### Engagement

Queueing requires current approved authority. Delivery claims execute the send-time gate again. Stale queued work becomes `BLOCKED_STALE`. Unknown or abandoned delivery state becomes `RECONCILIATION_REQUIRED`, never an unsafe automatic resend.

### V1 migration

The Build 17 bridge remains offline and factual-only. Legacy READY state, fit/confidence/score fields, Truth Index, R4/R5/R6, opportunity authority, approvals and engagement/workflow decisions fail closed rather than crossing into V2.

### Database

All existing database adversarial gates are replayed. Authority remains append-only, time-bound, RPC-controlled, database-recomputed and structurally separate from Truth/reasoning/workflow.

## End-to-end trace requirement

Source certification does **not** fabricate a live production proof. Final operational cutover requires one real migrated V2 company to demonstrate:

`SOURCE → ACQUISITION → EVIDENCE → CLAIM → TRUTH → R4 → R5 → R6 → OPPORTUNITY → ENGAGEMENT → UI`

Use:

`npm run certification:live-lineage`

with:

- `SUPABASE_URL`
- `SUPABASE_SERVICE_ROLE_KEY`
- `MARKETROUTE_CERT_ORGANISATION_ID`
- `MARKETROUTE_CERT_CAMPAIGN_ID`
- `MARKETROUTE_CERT_COMPANY_ID`

The tracer is GET/read-RPC only. It prints identifiers and fingerprints, never the service-role secret.

## Production cutover sequence

1. Apply all V2 migrations through Build 17 (`0019`).
2. Complete the Build 17 factual/evidence migration from V1.
3. Allow V2 to recompute Truth, R4, R5 and R6 from first principles.
4. Run `npm run constitution:check`.
5. Run `npm run certification:cutover-preflight`.
6. Choose a real migrated company with current V2 intelligence and run `npm run certification:live-lineage`.
7. Manually inspect the sampled source/evidence provenance against the original V1 source record.
8. Verify a stale/changed authority condition blocks any queued engagement before delivery.
9. Freeze the deployed commit and Supabase migration history.

Only after steps 1–9 is the operational release state:

# MarketRoute V2 / Genesis T8 — FROZEN

## Change policy after freeze

Post-freeze changes require a new explicit release. The frozen V2 theory/authority contract must not be modified casually. Critical defects include data corruption, authority-boundary failure, security failure, state-machine/recovery failure, or another production-blocking defect. Product/UI evolution may proceed in later releases without rewriting the constitutional authority model.
