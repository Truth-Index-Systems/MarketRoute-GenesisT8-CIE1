# MarketRoute V2 — Build 6
## Commercial Reality / R4

### Release status

Build 6 introduces the first commercial authority stage in the clean MarketRoute V2 repository.

The authority writer registry advances from zero writers to exactly one:

`marketroute.r4.commercial-reality` → `COMMERCIAL_REALITY`

R5 route authority, R6 contact authority, execution permission and opportunity workflow transitions remain absent.

---

## 1. Constitutional input boundary

R4 accepts only persisted, versioned inputs:

1. the latest campaign seller-context selection from Build 5;
2. an exact-reference-time `COMPANY_CORE_V1` Truth entity snapshot from Build 4;
3. exact Truth snapshots for supported HARD seller-constraint claim keys;
4. the versioned `SELLER_TO_TARGET_V1` boundary constitution.

AI is not present anywhere in the R4 kernel or authority persistence path.

---

## 2. Categorical decision contract

R4 can return only:

- `COMMERCIAL_CANDIDATE`
- `RESEARCH_REQUIRED`
- `NOT_ADMISSIBLE`

Mandatory boundary states are:

- `SATISFIED`
- `UNSATISFIED`
- `UNRESOLVED`
- `CONTRADICTED`
- `STALE`

Decision precedence is deterministic:

1. any known `UNSATISFIED` mandatory/HARD boundary → `NOT_ADMISSIBLE`;
2. otherwise any `UNRESOLVED`, `CONTRADICTED` or `STALE` boundary → `RESEARCH_REQUIRED`;
3. only every required boundary `SATISFIED` → `COMMERCIAL_CANDIDATE`.

There is no continuous commercial threshold.

---

## 3. Mandatory constitution V1

The fixed mandatory boundaries are:

- `seller.offering_present`
- `seller.objective_selected`
- `seller.constraints_known`
- `target.identity`
- `target.canonical_domain`
- `target.current_operation`

This makes unknown seller constraints explicit. `UNKNOWN` cannot mean `EXPLICIT_NONE`.

The target boundaries consume categorical Build-4 Truth. `KNOWN` and `SUPPORTED` are qualifying positive epistemic states; `CONTRADICTED`, `STALE` and `UNRESOLVED` block candidate authority.

The proposition value is separately evaluated. In particular, `operation.current = false` is a known boundary violation and produces `NOT_ADMISSIBLE`.

---

## 4. HARD seller constraints

Build 6 deterministically supports these HARD constraint types:

- geography / country / country_code → `profile.country_code`
- industry → `profile.industry_code`
- company_size / company_size_band → `profile.company_size_band`
- business_model → `profile.business_model_code`

A supported HARD constraint requires Truth-qualified target claims and categorical value membership in the seller-declared allowed values.

An unsupported HARD constraint type is never ignored. It becomes an unresolved required boundary and yields `RESEARCH_REQUIRED` unless another already-known violation independently proves `NOT_ADMISSIBLE`.

PREFERENCE constraints are intentionally non-authoritative in R4.

---

## 5. Premise completeness

The database does not trust the application to choose a convenient subset of target premises.

For dynamic HARD constraints it independently requires:

- the exact derived constraint claim-key set;
- every active global/tenant claim for each required key;
- one latest Truth snapshot per active claim at the exact R4 reference time;
- matching organisation, company and claim-key scope.

Selective omission of a violating constraint claim therefore fails closed.

The core target entity Truth snapshot must also be the latest `COMPANY_CORE_V1` snapshot at the exact reference time.

---

## 6. Database-recomputed authority

`marketroute_persist_commercial_reality_r4_v1` does not accept an input fingerprint or authority fingerprint from the application.

PostgreSQL independently:

1. reconstructs the persisted seller + Truth context;
2. re-derives the complete boundary array;
3. re-derives the categorical R4 decision;
4. verifies the application's output exactly;
5. computes `MRV2-R4-INPUT-1.0.0` fingerprint;
6. persists a `COMMERCIAL_REALITY` reasoning run;
7. persists a reasoning artifact;
8. computes `MRV2-R4-AUTHORITY-1.0.0` fingerprint;
9. writes the generic authority record under the declared writer context;
10. writes the R4-specific append-only ledger row.

The authority record is therefore physically descended from a persisted reasoning artifact whose input fingerprint the generic authority trigger also verifies.

---

## 7. Temporal and mutation currentness

R4 cannot be back-dated into current authority. Authority evaluation reference time must be near-current (within 15 minutes; at most five minutes future tolerance).

Each R4 record has a finite validity window capped at 24 hours and shortened by earlier Truth revalidation boundaries.

`marketroute_r4_authority_current_v1` additionally fails closed when:

- the authority interval expires;
- the authority has been superseded, invalidated or revoked;
- the campaign selects a newer seller context;
- a consumed target claim is newly created after authority persistence;
- new evidence is linked to a consumed target claim after authority persistence;
- a consumed target claim is superseded after authority persistence.

This means new research can remove current R4 status before an asynchronous invalidation worker exists.

---

## 8. Persistence and privileges

New persistence objects:

- `commercial_reality_boundary_constitutions`
- `commercial_reality_r4_records`
- `current_commercial_reality_r4`

`commercial_reality_r4_records` is append-only and RPC-write-only. `service_role` receives SELECT but no direct INSERT/UPDATE/DELETE permission.

Build 6 does not mutate `opportunities` and creates no workflow transition RPC.

---

## 9. Runtime modules

New core modules:

- `core/commercial-reality/contracts.ts`
- `core/commercial-reality/engine.ts`
- `core/commercial-reality/index.ts`
- `core/authority/commercial-reality.ts`

New application/platform modules:

- `application/commercial-reality/service.ts`
- `platform/database/commercial-reality-repository.ts`

The application service orchestrates current seller context, exact-time Truth hydration, supported HARD-constraint Truth hydration, the pure R4 kernel, and audited persistence.

---

## 10. Adversarial findings closed during Build 6

The build itself found and closed several authority-class defects before release:

1. A Truth-qualified claim's value must satisfy the boundary; `KNOWN false` cannot count as positive current-operation knowledge.
2. New evidence must make old R4 non-current immediately rather than waiting for a scheduler.
3. A caller must not be able to omit a known violating HARD-constraint claim from the persistence payload.
4. A caller must not be able to submit an older Truth snapshot at the same reference time.
5. Historical Truth evaluation must not be replayable as newly granted current commercial authority.
6. A pre-existing authority-writer registry collision must fail closed rather than being silently overwritten by migration upsert.

---

## 11. Certification

Full Builds 1–6 constitutional regression:

**584 / 584 PASS**

Build-6-specific gates:

- R4 static: **36 / 36**
- SQL safety: **12 / 12**
- pure commercial-reality adversarial: **21 / 21**
- database-boundary adversarial: **42 / 42**

Additional checks:

- framework-free R4/evidence/Truth/seller kernel strict TypeScript compile: PASS
- whole-source TS/TSX transpilation: PASS
- standalone Build-6 SQL byte-identical to canonical migration `0009`: PASS
- ZIP integrity: PASS (performed at packaging)

Environment limitation: this workspace does not provide a local PostgreSQL/Supabase runtime, so the user's fresh Supabase project is the final PL/pgSQL parser/runtime gate. Vercel remains the final complete Next.js dependency/framework compile gate.

---

## 12. Next build

Build 7 is Relationship Truth + Canonical Commercial Graph / R5.

R5 must not treat a persisted business relationship as immortal or binary-verified. Relationship premises will receive their own evidence, Truth state, freshness, contradiction and revalidation semantics before they can form deterministic multi-hop commercial paths.
