# MarketRoute V2 — Build 10
## Genesis Autonomous Research Engine

**Status:** Release candidate for deployment  
**Schema migration:** `0013_genesis_autonomous_research_engine.sql`  
**Planner:** `MRV2-RESEARCH-PLANNER-1.0.0`  
**Semantics:** `MRV2-RESEARCH-SEMANTICS-1.0.0`

## 1. Constitutional scope

Build 10 adds autonomous research planning and execution plumbing only. It creates **no new authority writer**. The declared authority writer set remains:

1. `marketroute.r4.commercial-reality`
2. `marketroute.r5.relationship-graph`
3. `marketroute.r6.contact-truth`

Research cannot grant commercial viability, route authority, contact authority, workflow state, opportunity ranking, or execution permission. Its meaningful output is either:

- new evidence persisted through the Build-3 evidence boundary; or
- deterministic revalidation work delegated to the existing R4/R5/R6 owners.

## 2. Research pressure derives from current authority

The database derives the research gap universe from the Build-9 current authority envelope. Research does not invent a parallel scoring model.

Current categorical priority order:

1. `DECISION_BLOCKER`
2. `CURRENTNESS_REPAIR`
3. `EXPIRING_SOON`
4. `ENRICHMENT`

Within a category, ordering is deterministic and stable. No continuous research score is used.

Lifecycle mappings include:

- `R4_REVALIDATION_REQUIRED` → `REVALIDATE_R4`
- `COMMERCIAL_RESEARCH_REQUIRED` → exact unresolved/contradicted/stale R4 boundary evidence
- `R5_REVALIDATION_REQUIRED` → `REVALIDATE_R5`
- `ROUTE_RESEARCH_REQUIRED` → `DISCOVER_ROUTE_STRUCTURE`
- `R6_REVALIDATION_REQUIRED` → `REVALIDATE_R6`
- `CONTACT_RESEARCH_REQUIRED` → exact unresolved R6 binding path
- `AUTHORITY_READY` → proactive deterministic refresh only when authority is within the configured refresh horizon
- terminal `NOT_ADMISSIBLE`, `ROUTE_NOT_APPLICABLE`, and `CONTACT_NOT_APPLICABLE` → no autonomous research

## 3. Numeric budgets are resource governance only

Default campaign policy:

- daily research budget: **$5.00**
- maximum paid work-unit ceiling: **$0.50**
- maximum concurrent research jobs: **2**
- maximum work units per plan: **4**
- proactive authority refresh horizon: **2 hours**

These numbers control spend and compute capacity. They do not alter commercial truth, route authority, contact authority, opportunity ordering, or workflow.

`REVALIDATE_R4`, `REVALIDATE_R5`, and `REVALIDATE_R6` are explicitly **zero-cost deterministic work**. They remain schedulable when the paid research budget is exhausted or has been conservatively exceeded.

## 4. Append-only research provenance

Build 10 adds:

- `research_budget_policies`
- `research_plan_runs`
- `research_work_units`
- `research_budget_events`

Plans, work units, and budget events are append-only. Direct application DML is revoked. Mutable `background_jobs` remain execution plumbing only.

Every persisted plan snapshots:

- organisation/campaign/company
- evaluation reference time
- current lifecycle state
- exact authority-envelope fingerprint
- exact gap-set fingerprint
- categorical work set
- budget policy snapshot
- budget state snapshot
- database-computed plan fingerprint

PostgreSQL independently recomputes the current context and rejects stale/tampered plan payloads.

## 5. Paid evidence and deterministic revalidation are separated

Research actions:

- `ACQUIRE_CLAIM_EVIDENCE`
- `DISCOVER_ROUTE_STRUCTURE`
- `RESEARCH_CONTACT_BINDING`
- `REVALIDATE_R4`
- `REVALIDATE_R5`
- `REVALIDATE_R6`

Paid provider work must return through existing application services:

- company claim findings → `EvidenceService`
- relationship findings → `RelationshipService` / Relationship Truth
- contact findings → `ContactAuthorityService` / Contact Truth

Only after evidence persistence can existing R4/R5/R6 services be re-evaluated.

## 6. Vendor-neutral provider boundary

Build 10 defines a `ResearchProvider` interface but deliberately does **not** bundle a vendor-specific OpenAI/search implementation.

This preserves model/provider replaceability and prevents the transport vendor from becoming part of Genesis authority semantics.

Provider output is recursively rejected if it contains authority-like fields such as:

- confidence
- probability
- score
- rank
- weight
- authority
- viability

Provider execution receives an `AbortSignal` and an explicit **180-second timeout contract**.

## 7. Budget settlement is fail-safe

Budget movement is append-only and attempt-scoped:

- `RESERVE`
- `COMMIT`
- `RELEASE`

A claim reserves the exact work-unit ceiling before the background job enters `RUNNING`.

Successful paid work commits actual cost.

Failed paid work:

- commits any known incurred cost;
- releases only unused reservation;
- if actual provider cost is unknown, conservatively charges the reserved ceiling;
- may record actual spend above the reservation if the provider violated the ceiling, ensuring subsequent budget decisions see the real known spend.

This deliberately prefers temporary budget over-accounting to uncontrolled credit overspend.

## 8. Retry and unchanged-gap protection

Retries stay inside the same immutable work unit and are attempt-scoped. Default background-job maximum attempts remain five with a five-minute defer between retryable failures.

A successfully, unsuccessfully, pending, or currently running work item suppresses the same unchanged `(gapKey, action)` for **six hours**. This prevents an unresolved gap from becoming a tight autonomous credit-burning loop.

The research-cycle dedupe identity includes the current gap-set fingerprint and reference time, so the same gap can legitimately be researched again in a later cycle after cooldown or context change.

## 9. Scheduler concurrency and crash recovery

Only one global `GENESIS_RESEARCH_V1` autonomous scheduler may own the planning cycle at a time.

Build 10 uses the Build-2 `scheduler_leases` table with:

- lease acquisition on scheduler start;
- heartbeat during planning/execution;
- 30-minute lease horizon;
- lease ownership required before work claim;
- owned lease release on scheduler completion.

If a process disappears after claiming research work, a later scheduler can recover abandoned `RUNNING` attempts once the old lease horizon is exceeded.

Recovery:

1. conservatively commits the full reserved ceiling for the abandoned attempt;
2. marks the attempt `ABORTED`;
3. clears stale reservation ownership;
4. returns the job to `PENDING` or marks it `FAILED` when the attempt limit is exhausted;
5. cancels stale scheduler-run records lacking a current lease.

This prevents permanent `RUNNING` jobs and immortal budget reservations.

## 10. Autonomous target scope

Genesis does not research every shared company for every tenant.

Autonomous planning targets only companies with an explicit `organisation_company_scopes.scope_kind = 'CAMPAIGN'` relationship to a campaign whose workflow state is `ACTIVE`.

Planning runs are near-current only. PostgreSQL rejects historical plan replay outside the permitted current-time window.

## 11. Important defects found and closed during Build 10

The adversarial pass found several production-relevant issues before release:

1. **Attempt reservation poisoning** — retrying the same work could collide with a permanent reservation identity. Fixed with attempt-scoped budget events.
2. **Unbounded unchanged-gap re-research** — later plans could repeatedly spend on the same unresolved gap. Fixed with bounded six-hour cooldown while preserving later legitimate re-research.
3. **Failed-call cost undercounting** — provider calls that consumed credits and later failed could be recorded as zero. Failed attempts now settle known cost or conservatively charge the reservation ceiling.
4. **Provider ceiling overrun accounting** — a provider violating its ceiling could leave actual spend unrecorded. Failed-cost settlement accepts and records known over-ceiling spend, after which future budget claims stop naturally.
5. **Historical plan replay** — internally valid old authority context could have been replayed into new research work. Persistence now requires near-current planning reference time.
6. **Low-budget TypeScript/PostgreSQL parity** — the DB could expect more paid work units than remaining budget could actually fund. The DB now simulates the same sequential budget allocation as the pure planner.
7. **Budget exhaustion blocking free revalidation** — deterministic R4/R5/R6 refresh was initially treated like paid provider work. Revalidation is now zero-dollar and independent of AI credit availability.
8. **Concurrent scheduler planning race** — two automation invocations could produce near-simultaneous plans. A single research scheduler lease now fences planning and claim ownership.
9. **Abandoned RUNNING jobs** — a crashed worker could strand job/concurrency/budget state. Stale attempt recovery now fails safe and resumes deterministically.
10. **Hung provider execution** — provider calls now receive a 180-second abort contract.

## 12. Certification

Build-10-specific gates:

- Autonomous research static gate: **33/33 PASS**
- SQL safety gate: **16/16 PASS**
- Pure planner adversarial gate: **21/21 PASS**
- Database research adversarial gate: **47/47 PASS**

Full MarketRoute V2 Builds 1–10 constitutional regression:

**1,112 / 1,112 PASS across 40 suites.**

Additional gates:

- strict changed-module TypeScript compilation: **PASS**
- whole V2 TS/TSX transpilation: **51/51 PASS**
- standalone installer is byte-identical to canonical migration `0013`: **PASS**

## 13. Honest limitations

Build 10 does not yet provide:

- a vendor-specific AI/search provider implementation;
- public research controls/UI;
- Opportunity Engine prioritisation (Build 11);
- Engagement Engine/execution permission (Build 12);
- authoritative product read model (Build 13).

The research engine is therefore architecturally live and provider-ready, but actual paid web/model acquisition requires a future concrete `ResearchProvider` implementation or integration decision.

No freeze is declared. Build 11 is the Opportunity Engine.
