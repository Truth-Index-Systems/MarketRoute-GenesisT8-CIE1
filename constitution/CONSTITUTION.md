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

## Build 7 state

Two commercial authority writers are live and explicitly declared:

1. `marketroute.r4.commercial-reality` — consumes exact campaign seller context + current target Truth + mandatory boundaries and returns `COMMERCIAL_CANDIDATE`, `RESEARCH_REQUIRED`, or `NOT_ADMISSIBLE`.
2. `marketroute.r5.relationship-graph` — consumes a current R4 parent plus the exact Truth-qualified route relationship universe and returns `ROUTE_STRUCTURALLY_OPEN`, `ROUTE_RESEARCH_REQUIRED`, or `ROUTE_NOT_APPLICABLE`.

Build 7 introduces a canonical commercial relationship ontology. A relationship row is only identity/topology; it is never an OPEN graph premise by itself. Every relationship has an immutable `relationship.exists` claim and may be traversed by R5 only when the generic Truth Engine evaluates that claim as `KNOWN` or `SUPPORTED` at the exact R5 reference time. `UNRESOLVED`, `CONTRADICTED`, `STALE`, expired, or mutated relationship Truth cannot be traversed.

Business relationships such as `partners_with`, `supplies`, `customer_of`, and `uses_technology_from` are intelligence edges but are not automatic access routes. Route traversal is ontology-owned and currently limited to explicit structural access relations such as `parent_of`, `employs`, `has_access_point`, and `introduced_by`.

R5 proves structural reachability only. A path containing a person or personal access point is marked `CONTACT_TRUTH_REQUIRED`; Build 7 does not grant current identity, employment, role, or channel ownership. Build 8 owns that contact authority.

R5 has no numeric score, confidence, probability, weight, strength, or rank. PostgreSQL independently verifies the exact reachable relationship universe, exact current Truth snapshot for every relationship, the structural endpoint set, path directionality, canonical ontology metadata, parent R4 fingerprint, time validity, and the final authority fingerprint. New route-relevant relationships, new relationship evidence, Truth expiry, or stale R4 authority make R5 non-current without waiting for a scheduler.
