# MarketRoute V2 Constitutional Foundation

Version: **MRV2-CONSTITUTION-1.0.0**

## Product truth

MarketRoute exists to research markets, identify commercially admissible companies, and prove evidence-backed routes to the people or access points needed to reach them.

## Constitutional laws

1. **Evidence precedes authority.** No score, model output, UI state, or historical workflow field is evidence.
2. **Unknown is not false.** Missing knowledge remains unresolved.
3. **Evidence strength is not probability.** Probability is only permitted when an empirical calibration layer exists.
4. **AI owns semantics, not commercial authority.** AI may interpret and generate; deterministic evidence-qualified systems govern Truth, commercial reality, route authority, contact authority, and execution permission.
5. **Truth is epistemic state, not commercial authority.** Truth may describe what the evidence justifies; it cannot itself grant viability, route authority, contact authority or execution.
6. **Contradiction is fail-closed.** Explicit current contradiction outranks positive evidence at both claim and required entity-boundary level.
7. **Dependence precedes corroboration.** Multiple observations from one dependence family never manufacture independent confirmation.
8. **Freshness is evaluated at an explicit reference time.** Historical stale evidence remains visible but cannot remain current forever or penalise freshly renewed evidence merely by existing.
9. **Workflow state is not authority state.** Human approval can coexist with stale execution authority; authority may be revalidated without erasing human history.
10. **Authority is explicit, versioned, fingerprinted, time-bound and fail-closed.**
11. **The UI reads authority; it never reconstructs it.**
12. **No V1 runtime dependency.** V1 may become a one-way evidence migration source only.
13. **No compatibility layer.** Compatibility cannot become a route around constitutional boundaries.
14. **Every authority writer must be declared in `authority-manifest.json`.** Undeclared authority is a build failure.

## Layer ownership

- `/core`: deterministic domain kernels and contracts.
- `/platform`: AI transport, database, scheduler and observability adapters.
- `/application`: orchestration/use cases that consume core contracts.
- `/ui`: presentation components consuming application read models only.
- `/app`: Next.js routing/composition only.

## Build 4 state

There are deliberately **zero commercial authority writers**. Builds 1–3 establish the clean repository, fresh persistence constitution and evidence/provenance runtime. Build 4 adds non-authoritative Truth reasoning only.

Truth claim states are categorical: `KNOWN`, `SUPPORTED`, `UNRESOLVED`, `CONTRADICTED`, and `STALE`. `KNOWN` requires multiple independent current evidence families under a versioned policy; an explicit current contradiction always wins. Continuous evidence strength, balance, sufficiency and freshness metrics are diagnostic and cannot change the categorical state.

Truth probability remains `NULL / UNCALIBRATED` until an empirical calibration layer exists. The Truth Index is a maximin epistemic-readiness measure across declared required boundaries, not a probability of correctness.

Global and tenant-private claims may represent the same tenant-neutral proposition. Proposition identity is distinct from tenant-scoped claim identity so shared research can be reused without creating false contradiction. Genuine competing propositions or explicit current contradiction remain fail-closed.

Truth snapshots are append-only and RPC-write-only. PostgreSQL independently re-derives categorical Truth and metrics from stored evidence before accepting a snapshot and computes persisted fingerprints itself.
