# MarketRoute V2 — Build 4: Truth Engine V2

**Release:** MRV2 Build 4  
**Truth engine:** `MRV2-TRUTH-1.0.0`  
**Truth semantics:** `MRV2-TRUTH-SEM-1.0.0`  
**Entity aggregation:** `MRV2-TRUTH-ENTITY-1.0.0`  
**Database boundary:** `MRV2-DB-BOUNDARY-1.2.0`

## Status

Build 4 introduces MarketRoute V2's first epistemic reasoning layer. It converts persisted evidence and claim provenance from Build 3 into versioned, time-aware, append-only Truth snapshots.

Build 4 creates **zero commercial authority writers**. Truth is reasoning, not permission. No Truth state or Truth metric can grant commercial viability, route authority, contact authority, opportunity workflow state, or execution permission.

`authority-manifest.json` remains empty:

```json
"authorityWriters": []
```

## Constitutional Truth model

### Claim states

A claim is evaluated into one categorical state:

- `KNOWN`
- `SUPPORTED`
- `UNRESOLVED`
- `CONTRADICTED`
- `STALE`

Categorical state is determined by independent evidence families under a versioned policy. It is **not** selected by a continuous score threshold.

For Build 4 policies:

- any current explicit contradiction family => `CONTRADICTED`;
- at least the policy's required independent support-family count and no contradiction => `KNOWN`;
- at least one current independent support family and no contradiction => `SUPPORTED`;
- no current family but historical stale evidence => `STALE`;
- otherwise => `UNRESOLVED`.

The seeded `KNOWN` requirement is two independent families. Policy rows are versioned and future policy changes can therefore be distinguished from historical Truth snapshots.

### Contradiction is fail-closed

Contradiction has precedence at two levels.

At claim level, one current explicit contradiction cannot be numerically outvoted by ten supporting families.

At entity level, a current `CONTRADICTED` evaluation for a required boundary outranks a separate `KNOWN` or `SUPPORTED` copy. This prevents positive duplicate claims from masking a conflicted premise.

### Dependence before corroboration

Evidence is collapsed by the Build 3 `dependence_family_key` before corroboration.

Ten observations inside one family count as one family. If one family contains both current support and current contradiction, that family is `CONFLICT` and contributes contradiction, not support.

### Freshness

Freshness is evaluated against an explicit `referenceTime`.

Effective origin is:

```text
originPublishedAt ?? sourcePublishedAt ?? observedAt
```

Therefore undated evidence still ages.

Evidence is current only while:

```text
age < maxAge
```

At the exact expiry boundary it becomes stale.

Evidence dated more than five minutes into the future relative to the evaluation reference time is excluded and recorded as a temporal anomaly.

`freshnessCoverage` is the average remaining freshness of **currently qualifying independent families**. Historical stale evidence remains visible, but merely retaining old research does not permanently penalise a newly refreshed claim.

### Continuous metrics are diagnostic only

Build 4 exposes:

- `evidenceSufficiency`
- `supportStrength`
- `contradictionStrength`
- `evidenceBalance`
- `freshnessCoverage`

These describe evidence condition. They cannot flip the categorical Truth state.

This explicitly prevents the V1 defect where an arbitrarily tiny positive numerical difference could become a commercially decisive premise.

## Probability semantics

Build 4 does not manufacture probability.

Every Truth snapshot stores:

```text
truthProbability = NULL
probabilityState = UNCALIBRATED
```

Probability may only be introduced by a future empirical calibration layer with observed labels/outcomes and a declared calibration contract.

Evidence strength, evidence sufficiency and the Truth Index must not be relabelled as probability.

## Tenant-neutral proposition identity

Build 3 claim fingerprints are intentionally tenant-scoped so provenance and access boundaries remain immutable.

Build 4 adds a separate database-generated `proposition_fingerprint` representing the tenant-neutral semantic proposition:

```text
subject type
+ subject ID
+ claim key
+ predicate
+ canonical object
+ canonical value
```

This allows an organisation's entity evaluation to reuse both:

- globally researched claims; and
- its own tenant-private claims.

Two global/private claim rows that assert the same proposition do **not** become a false competing-fact contradiction simply because their tenant-scoped claim fingerprints differ.

Genuine different propositions for the same required key remain contradictory when simultaneously supported.

Build 4 deliberately does not pool independent evidence families across separate claim rows merely to upgrade a duplicate proposition. It chooses the strongest independently evaluated copy. That is conservative: cross-scope corroboration cannot manufacture `KNOWN` until a future explicit proposition-merging contract safely defines that operation.

## Claim Truth persistence

New tables:

- `truth_claim_policy_registry`
- `truth_claim_policy_bindings`
- `truth_claim_snapshots`

Claim Truth runtime:

```text
persisted claim + evidence
        ↓
marketroute_get_claim_truth_context_v1
        ↓
pure TypeScript Truth kernel
        ↓
marketroute_persist_claim_truth_v1
        ↓
PostgreSQL independently re-derives evidence facts
        ↓
append-only Truth snapshot + reasoning artifact
```

The application cannot simply persist `KNOWN`.

Before accepting a snapshot PostgreSQL independently checks:

- current support-family count;
- contradiction-family count;
- stale-family count;
- temporal anomalies;
- evidence sufficiency;
- support/contradiction diagnostics;
- evidence balance;
- freshness;
- exact revalidation boundary;
- current input fingerprint;
- engine and semantics versions;
- uncalibrated probability state.

If the TypeScript result differs from the persisted evidence state, the write fails with:

`MARKETROUTE_TRUTH_OUTPUT_DOES_NOT_MATCH_EVIDENCE`.

The database generates the proposition fingerprint and Truth snapshot fingerprint itself.

## Entity Truth and required boundaries

Build 4 introduces explicit versioned entity profiles.

Seeded `COMPANY_CORE_V1` requires:

1. `identity.canonical_name`
2. `identity.canonical_domain`
3. `operation.current`

Missing required keys remain unresolved. The entity aggregator does not pretend that an absent claim means the boundary is satisfied.

Entity states:

- `KNOWN`
- `SUPPORTED`
- `PARTIAL`
- `UNRESOLVED`
- `CONTRADICTED`
- `STALE`

A required boundary with multiple distinct currently supported propositions becomes an entity-level contradiction. A required boundary containing an explicit current contradicted claim also becomes contradicted even if a separate positive copy exists.

## Truth Index

The V2 Truth Index is explicitly **not probability**.

For the declared entity profile it is:

```text
100 × min(
  currentCoverage,
  evidenceSufficiency,
  freshnessCoverage,
  coherence
)
```

It is therefore a maximin epistemic-readiness/completeness measure. A severe weakness in one required dimension cannot be hidden by averaging strong dimensions around it.

The profile is explicit and versioned, so a high Truth Index only means strong epistemic readiness across the declared required boundaries—not omniscience about the entity.

## Database hardening

Truth snapshot tables are append-only and direct writes are revoked.

`service_role` receives read access plus execution rights only to the intended context/persistence RPCs.

Direct service-role writes to generic `reasoning_runs` and `reasoning_artifacts` are revoked from Build 4 onward. Truth persistence creates those records only inside the security-definer Truth boundary.

Internal helpers, including proposition-fingerprint calculation and SQL Truth-fact derivation, are not granted to application callers.

The migration creates no commercial authority writer and mutates no opportunity workflow state.

## Runtime architecture

Pure deterministic core:

- `core/truth/contracts.ts`
- `core/truth/engine.ts`
- `core/truth/index.ts`

Database adapter:

- `platform/database/truth-repository.ts`

Application orchestration:

- `application/truth/service.ts`

The dependency flow remains constitutional:

```text
application
   ├── core/truth
   └── platform/database

core/truth
   └── core/evidence deterministic primitives
```

Core Truth has no database, UI, AI or framework dependency.

## Migration

Canonical migration:

`supabase/migrations/0007_truth_engine_v2.sql`

Standalone installer:

`APPLY-IN-SUPABASE-MARKETROUTE-V2-BUILD4.sql`

The standalone installer is byte-identical to canonical migration `0007`.

The migration is atomic and reloads the PostgREST schema only after all Build 4 DDL completes.

## Adversarial cases covered

The Build 4 attack suite explicitly covers:

- one support family cannot become `KNOWN`;
- repeated evidence in one dependence family cannot manufacture corroboration;
- explicit contradiction cannot be numerically outvoted;
- support + contradiction in one family becomes conflict;
- stale evidence cannot remain current;
- undated evidence ages from observation time;
- freshness changes with evaluation reference time;
- exact max-age expiry is stale;
- future-dated evidence is excluded;
- old stale families do not penalise freshly renewed current evidence;
- no probability is invented;
- evidence balance cannot decide categorical Truth;
- required-family policy cannot be weakened below two;
- missing entity boundaries keep the entity partial/unresolved;
- competing supported propositions create entity contradiction;
- global/private copies of the same proposition do not create false contradiction;
- explicit contradicted entity evidence outranks a `KNOWN` copy;
- database recomputes claim Truth from evidence;
- database rejects stale-context persistence;
- duplicate claim-snapshot IDs are rejected;
- entity snapshots cannot cross subject, tenant or reference-time boundaries;
- global claim snapshots may be reused by tenant evaluation but another tenant's private snapshot cannot;
- no commercial authority or opportunity workflow write occurs.

## Certification

Full constitutional chain after Build 4:

- Architecture boundary: **23/23**
- AI boundary: **7/7**
- Legacy quarantine: **3/3**
- Authority manifest: **10/10**
- Build 2 schema: **46/46**
- Build 2 SQL safety: **12/12**
- Build 1 architecture attacks: **18/18**
- Build 2 DB attacks: **22/22**
- Build 3 evidence static: **28/28**
- Build 3 SQL safety: **11/11**
- Build 3 evidence attacks: **21/21**
- Build 3 DB attacks: **25/25**
- Build 4 Truth static: **39/39**
- Build 4 SQL safety: **16/16**
- Build 4 Truth attacks: **25/25**
- Build 4 DB attacks: **30/30**

**Total constitutional assertions exercised: 336/336 PASS.**

Additional compile checks:

- strict TypeScript compile of `core/evidence` + `core/truth`: **PASS**
- whole V2 TypeScript/TSX source transpilation with `--noCheck`: **PASS**
- standalone Build 4 SQL equals canonical migration: **PASS**

A complete framework typecheck could not run in the working container because the workspace has no installed Next/React/Node type dependency tree. The observed errors are unresolved package/type declarations, not source diagnostics from the Truth kernel. Vercel remains the final framework/dependency compile gate.

No local PostgreSQL/Supabase runtime or PostgreSQL parser is available in the working environment, so the user's fresh Supabase project is the final DDL parser/runtime gate.

## Known limitation / deliberate conservatism

Build 4 reasons only over the evidence and claims persisted through Build 3. It does not judge whether an AI research extraction was semantically correct; future research builds must produce evidence/claim proposals that still pass the same provenance boundary.

Global/private copies of an identical proposition are recognised as one semantic proposition for entity conflict detection, but their evidence families are not pooled across claim rows in Build 4. This avoids accidental cross-scope corroboration. A future explicit proposition-merging layer may safely add that capability if required.

Build 4 does not implement seller commercial semantics, commercial reality, graph route authority, contacts, opportunities or engagement. Those remain later builds.

## Release conclusion

Build 4 establishes a clean V2 epistemic substrate:

```text
RAW EVIDENCE
     ↓
DEPENDENCE-AWARE CLAIM TRUTH
     ↓
VERSIONED ENTITY TRUTH
     ↓
TRUTH INDEX / EPISTEMIC READINESS
```

The next build may consume Truth, but it may not redefine it.
