# MarketRoute V2 Constitutional Foundation

Version: **MRV2-CONSTITUTION-1.0.0**

## Product truth

MarketRoute exists to research markets, identify commercially admissible companies, and prove evidence-backed routes to the people or access points needed to reach them.

## Constitutional laws

1. **Evidence precedes authority.** No score, model output, UI state, or historical workflow field is evidence.
2. **Unknown is not false.** Missing knowledge remains unresolved.
3. **Evidence strength is not probability.** Probability is only permitted when an empirical calibration layer exists.
4. **AI owns semantics, not commercial authority.** AI may interpret and generate; deterministic evidence-qualified systems govern Truth, commercial reality, route authority, contact authority, and execution permission.
5. **Workflow state is not authority state.** Human approval can coexist with stale execution authority; authority may be revalidated without erasing human history.
6. **Authority is explicit, versioned, fingerprinted, time-bound and fail-closed.**
7. **The UI reads authority; it never reconstructs it.**
8. **No V1 runtime dependency.** V1 may become a one-way evidence migration source only.
9. **No compatibility layer.** Compatibility cannot become a route around constitutional boundaries.
10. **Every authority writer must be declared in `authority-manifest.json`.** Undeclared authority is a build failure.

## Layer ownership

- `/core`: deterministic domain kernels and contracts.
- `/platform`: AI transport, database, scheduler and observability adapters.
- `/application`: orchestration/use cases that consume core contracts.
- `/ui`: presentation components consuming application read models only.
- `/app`: Next.js routing/composition only.

## Build 2 state

There are deliberately **zero authority writers**. Build 2 adds the fresh V2 persistence constitution only: identity/tenancy, canonical evidence, non-authoritative reasoning, locked authority storage, separate human workflow, scheduler primitives, observability and append-only audit history.

Authority tables are persistence targets, not capability. Direct authority DML is revoked from client roles and `service_role`; future authority builds must register a writer by migration and write through a security-definer boundary that re-proves its authority contract. Workflow mutation is likewise not enabled in Build 2.
