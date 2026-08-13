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

## Build 8 state

Build 8 introduces the third authority writer: `marketroute.r6.contact-truth` / `CONTACT_AUTHORITY`.

R6 consumes only a current R5 structural route. Organisational routes remain executable at the contact layer without inventing a named person. Any path that contains a person or personal channel must prove, through the generic Truth Engine, the exact person identity, current employment with the employer structurally present on that path, at least one current role at that employer, and ownership of the exact terminal channel. A different employer, competing identity, competing channel owner, stale/contradicted claim, archived person, or missing structural person/employer keeps the path at `CONTACT_TRUTH_REQUIRED`.

Contact authority is categorical (`CONTACT_AUTHORISED`, `CONTACT_RESEARCH_REQUIRED`, `CONTACT_NOT_APPLICABLE`). Numeric contact confidence, scores, ranks, probabilities and weights are forbidden authority inputs. PostgreSQL independently re-derives the contact-claim universe, validates the exact Truth snapshots, recomputes bindings/decision/fingerprints, and caps R6 validity at eight hours or the earlier parent/Truth boundary.

## Build 9 state

Build 9 introduces no new authority writer. The constitutional writer set remains R4, R5 and R6.

A derived authority lifecycle composes only the exact current R4 → R5 → R6 chain. It returns a categorical state such as `R4_REVALIDATION_REQUIRED`, `ROUTE_RESEARCH_REQUIRED`, `CONTACT_RESEARCH_REQUIRED`, `NOT_ADMISSIBLE`, or `AUTHORITY_READY`. Continuous confidence or scoring cannot alter this lifecycle.

Human workflow remains orthogonal to authority. Founder approval requires `AUTHORITY_READY` at the instant of review and the exact authority envelope/fingerprint is persisted with the review. Later expiry or mutation of R4/R5/R6 does not demote the opportunity or erase founder intent. Instead, the opportunity remains `APPROVED` while the derived execution predicate becomes false. Revalidation of R4/R5/R6 never consults or mutates opportunity workflow state.

`marketroute_opportunity_executable_now_v1` is a derived predicate, not an authority writer. It is true only when workflow is `APPROVED` and the R4/R5/R6 envelope is currently `AUTHORITY_READY`. Actual execution permission and message sending remain later engagement-build responsibilities.


## Build 10 state

Build 10 introduces no new authority writer. The constitutional writer set remains R4, R5 and R6. Genesis research is an evidence-acquisition and deterministic-revalidation subsystem only. It may spend bounded resources, but it may not create commercial authority, route authority, contact authority, opportunity ranking, workflow transitions, or execution permission.

Research pressure is derived from the current Build-9 authority envelope. `DECISION_BLOCKER` outranks `CURRENTNESS_REPAIR`, which outranks `EXPIRING_SOON`, which outranks `ENRICHMENT`. This ordering is categorical and lexicographic; no continuous research score may become commercial priority. Numeric budget and concurrency values govern resource consumption only.

Paid research findings must return through the Build-3 evidence boundary. Relationship findings return through Relationship Truth; contact findings return through Contact Truth. Only those existing systems may then change R4/R5/R6. Provider output fields resembling confidence, probability, score, rank, weight, authority, or viability are rejected recursively.

Deterministic `REVALIDATE_R4`, `REVALIDATE_R5`, and `REVALIDATE_R6` work has a zero-dollar research ceiling and remains schedulable even when the paid AI budget is exhausted or has been conservatively exceeded.

Autonomous execution uses one `GENESIS_RESEARCH_V1` scheduler lease with heartbeat. Planning is limited to explicit `CAMPAIGN` company scopes whose campaign is `ACTIVE`. A current research plan cannot be replayed historically. Identical unchanged gaps are cooled down for six hours, while retry attempts remain scoped to the same immutable work unit.

Budget settlement is attempt-scoped and append-only. Successful work commits actual spend. Failed work commits known incurred spend and releases only unused reservation. If provider spend is unknown, the system conservatively accounts the reserved ceiling. A process-abandoned RUNNING attempt is recovered after the scheduler lease horizon, conservatively charged to its reserved ceiling, marked `ABORTED`, and retried or failed according to the existing attempt limit.

Provider execution has a 180-second abort contract. Build 10 deliberately defines a vendor-neutral `ResearchProvider` interface rather than coupling Genesis to one model or search vendor.
