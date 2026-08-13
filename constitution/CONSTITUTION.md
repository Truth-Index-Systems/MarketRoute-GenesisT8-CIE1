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

## Build 5 state

There are deliberately **zero commercial authority writers**. Builds 1–4 establish the clean repository, persistence constitution, evidence/provenance runtime and non-authoritative Truth Engine. Build 5 adds first-party seller semantic context only.

The Seller Commercial Genome separates machine-semantic meaning from explanatory prose. Its eight declared dimensions are offerings, capabilities, commercial objectives, delivery, service geography, target characteristics, buyer assumptions and constraints. Each dimension is explicitly `DECLARED`, `EXPLICIT_NONE` or `UNKNOWN`; unknowns remain questions rather than being silently treated as absence.

Seller semantics are first-party declared context, not external Truth and not commercial authority. AI may extract and canonicalise seller meaning under a versioned semantic contract, but output keys resembling confidence, probability, score, rank, fit, viability, authority or priority are constitutionally forbidden. Unrecognised semantic fields fail closed.

Seller genome persistence is append-only and RPC-write-only. PostgreSQL independently validates the canonical semantic shape and computes both an exact content fingerprint and a machine-semantic fingerprint. Explanatory wording may change without changing semantic identity; a genuine semantic change must change semantic identity.

Campaign seller context selection is an append-only founder-intent event. Each selection binds an exact genome snapshot and objective key. Idempotency is request-scoped: retrying the same `selection_request_id` deduplicates, while a later intentional re-selection with a new request ID creates a new current event even if it returns to a previously selected objective.

Build 5 does not create R4, route authority, contact authority, opportunity authority, ranking or execution permission. The authority writer registry remains empty. Build 6 is the first build permitted to introduce a commercial authority writer, and it must consume persisted campaign seller context plus target Truth through an explicit mandatory-boundary constitution.
