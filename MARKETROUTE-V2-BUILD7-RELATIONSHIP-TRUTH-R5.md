# MarketRoute V2 — Build 7
## Relationship Truth + Canonical Commercial Graph / R5

**Release:** Build 7  
**Schema migration:** `0010_relationship_truth_and_route_authority_r5.sql`  
**Authority stage introduced:** R5 / `ROUTE_AUTHORITY`  
**Authority writer:** `marketroute.r5.relationship-graph` v1.0.0  
**R5 semantics:** `MRV2-R5-SEMANTICS-1.0.0`  
**Relationship ontology:** `MRV2-RELATIONSHIP-ONTOLOGY-1.0.0`

## 1. Purpose

Build 7 adds the second constitutional commercial authority layer to MarketRoute V2. It does two things and deliberately no more:

1. Represents commercial/business relationships as canonical, directional, evidence-backed claims that must pass the existing Build-4 Truth Engine.
2. Allows R5 to construct deterministic multi-hop structural routes only over Truth-qualified, route-capable relationships.

Build 7 does **not** grant named-contact authority. A structurally reachable path through a person or a personal channel is marked `CONTACT_TRUTH_REQUIRED`. Build 8 owns identity, current employment, current role and personal channel ownership.

## 2. Constitutional chain after Build 7

```text
Seller Commercial Genome
          +
Target Truth
          ↓
R4 Commercial Reality
          ↓
Truth-qualified relationship graph
          ↓
R5 Structural Route Authority
```

Authority writers now total exactly two:

- `marketroute.r4.commercial-reality`
- `marketroute.r5.relationship-graph`

R6/contact authority remains undeclared/future-only.

## 3. Canonical relationship ontology

The ontology explicitly defines relation type, direction and whether a relationship is route-traversable.

Canonical relationship types:

- `depends_on`
- `equivalent_to`
- `part_of`
- `parent_of`
- `subsidiary_of`
- `partners_with`
- `supplies`
- `customer_of`
- `uses_technology_from`
- `supersedes`
- `employs`
- `has_access_point`
- `introduced_by`

A business relationship is not automatically a route. In particular, `partners_with`, `supplies`, `customer_of`, and `uses_technology_from` may exist as useful graph knowledge while remaining non-route-capable. A partnership does not imply an introduction. An introduction requires the explicit `introduced_by` semantic relationship.

## 4. Relationship Truth

Every canonical commercial relationship owns an immutable canonical claim:

```text
subject_type = RELATIONSHIP
claim_key    = relationship.exists
predicate    = EXISTS
object       = true
```

Relationship evidence is attached to that exact relationship subject and evaluated through the generic Build-4 Truth Engine under `RELATIONSHIP_CURRENT_V1`.

A relationship may therefore resolve to the same categorical states as other Truth claims:

- `KNOWN`
- `SUPPORTED`
- `UNRESOLVED`
- `CONTRADICTED`
- `STALE`

R5 may traverse only `KNOWN` or `SUPPORTED` relationships with a future revalidation boundary.

Canonical relationship claims cannot be superseded. Their identity is immutable. New evidence may support or contradict the relationship, or a different canonical relationship may be asserted. This prevents historical identity mutation.

## 5. Canonical graph nodes

Node kinds:

- `COMPANY`
- `PERSON`
- `ORGANISATIONAL_UNIT`
- `TECHNOLOGY`
- `ACCESS_POINT`

Canonical company/person nodes are global canonical entities. Tenant-specific semantic nodes may exist where appropriate, but global relationships may never reference private tenant nodes and tenant relationships may never reference another tenant's private nodes.

Access-point identity is based on canonical access kind + canonical value + scope. Arbitrary labels/stable keys cannot manufacture duplicate graph endpoints for the same real access point.

Supported access-point kinds include:

- contact form
- generic email
- switchboard
- department email/form
- personal email
- LinkedIn
- personal phone
- other

## 6. Deterministic route calculus

R5 uses a bounded graph search:

- maximum path depth: 4
- maximum relationship universe: 128
- maximum submitted/persisted paths: 512
- cycles are rejected/prevented
- directed relationships cannot be traversed backwards
- undirected relationships are traversable in either direction

A valid path must begin at the target company and end at an access point.

Examples:

```text
Target Company
   └─has_access_point→ Generic Inbox
```

```text
Target Company
   └─parent_of→ Operations Department
                    └─has_access_point→ Department Email
```

```text
Target Company
   └─employs→ Jane Doe
                 └─has_access_point→ jane@example.com
```

The first two can be structurally organisationally open at R5. The third is only structurally reachable and remains `CONTACT_TRUTH_REQUIRED` until Build 8.

## 7. R5 categorical outputs

R5 decisions are categorical:

- `ROUTE_STRUCTURALLY_OPEN`
- `ROUTE_RESEARCH_REQUIRED`
- `ROUTE_NOT_APPLICABLE`

There is no numeric route score, route confidence, route quality, weighted rank or probability in R5 authority.

Path knowledge state is categorical (`KNOWN` or `SUPPORTED`) and derives only from the relationship Truth states on the path.

## 8. Database-independent verification

The application is not trusted to declare R5 authority.

Supabase independently verifies:

- current parent R4 authority;
- exact R4 parent fingerprint;
- exact route-relevant relationship universe;
- exact latest relationship Truth snapshot at the R5 reference time;
- relationship Truth context fingerprints;
- ontology relation type/direction;
- route-traversability;
- graph endpoint identity;
- every submitted path edge-by-edge;
- terminal access-point set;
- contact-required endpoint set;
- distinct access-point count;
- next revalidation time;
- R5 input fingerprint;
- R5 authority fingerprint.

The caller supplies neither the R5 input fingerprint nor authority fingerprint.

The R5 authority fingerprint binds the validated path JSON and validated endpoint sets.

## 9. Premise-omission resistance

R5 cannot selectively hide relationships that would change the route graph.

The persistence RPC requires the exact database-derived relationship universe and exact Truth snapshots for every relationship in that universe. Missing, substituted, cross-tenant, cross-relationship or stale snapshots fail closed.

The database separately computes the set of structurally reachable access points and requires every open endpoint to have submitted path provenance.

## 10. Temporal currentness

R5 authority is capped at 12 hours and can expire earlier from:

- parent R4 expiry;
- relationship Truth revalidation;
- relationship evidence mutation;
- relationship-universe mutation;
- parent R4 mutation/invalidation;
- explicit authority supersession/invalidation/revocation.

A currently closed relationship can still influence the next R5 revalidation time if its contradiction/staleness boundary may later change the graph. An unresolved relationship with no finite revalidation boundary does not cause an immediate expiry loop.

`marketroute_r5_authority_current_v1` rechecks the current R4 parent, relationship universe and relationship Truth context rather than relying on an invalidation worker having already run.

## 11. AI boundary

Build 7 defines a provider-neutral relationship extraction contract only.

AI may propose semantic relationships and evidence. It may not provide or influence:

- score
- confidence
- probability
- weight
- rank
- authority
- strength
- viability

Such fields are rejected rather than ignored.

No live OpenAI research implementation is introduced in this build. Build 10 will own autonomous acquisition/research.

## 12. Security hardening found during Build 7

The adversarial pass caught and fixed several issues before release:

1. **Business relationship ≠ access route.** Partnerships/supply/customer relationships are not traversable just because they exist.
2. **Personal structural route ≠ contact authority.** Person/personal-channel paths are explicitly deferred to Build 8.
3. **Access-point identity manipulation.** Arbitrary stable labels cannot create duplicate endpoint identities for one canonical email/URL.
4. **Premise omission.** The client cannot omit a route-relevant relationship or substitute a Truth snapshot.
5. **Fake path provenance.** Every path is re-proven in PostgreSQL edge-by-edge.
6. **Helper-function exposure.** Internal graph/universe helper functions have `PUBLIC` execution explicitly revoked; they cannot become tenant-data probes.
7. **Canonical relationship identity mutation.** Relationship claims cannot be superseded.
8. **Closed-edge temporal transition.** Contradicted/stale relationships with future revalidation can shorten R5 validity so a future topology change is reconsidered.
9. **Non-candidate R4 parity.** TypeScript and PostgreSQL both produce no open/contact route sets when the parent R4 is not a current commercial candidate.

## 13. Persistence introduced by migration 0010

New tables include:

- `commercial_relationship_type_registry`
- `commercial_graph_nodes`
- `commercial_relationships`
- `route_authority_r5_records`

New/important RPCs:

- `marketroute_ensure_graph_node_v1`
- `marketroute_ensure_commercial_relationship_v1`
- `marketroute_link_relationship_evidence_v1`
- `marketroute_get_r5_relationship_claim_ids_v1`
- `marketroute_get_r5_context_v1`
- `marketroute_persist_route_authority_r5_v1`
- `marketroute_r5_authority_current_v1`

Direct DML is revoked from protected graph/authority ledgers. Canonical ledgers remain append-only.

## 14. Certification

Build-7 specific gates:

- Relationship graph static: **46/46 PASS**
- SQL safety: **15/15 PASS**
- Graph adversarial: **31/31 PASS**
- Database-boundary adversarial: **40/40 PASS**

Full Builds 1–7 constitutional regression:

- **737/737 PASS** across 28 suites.

Additional release gates:

- strict pure R5/evidence core TypeScript compile: PASS
- strict changed-module TypeScript compile: PASS
- whole V2 TS/TSX transpilation: **34/34 PASS**
- standalone installer byte-identical to canonical migration `0010`: PASS

## 15. Runtime validation limitation

The build environment does not contain a local PostgreSQL/Supabase runtime. Therefore the migration has been statically/adversarially validated but not executed against local PostgreSQL. The fresh MarketRoute V2 Supabase project is the final PL/pgSQL parser/runtime gate.

## 16. Constitutional state after Build 7

```text
Evidence                     ✅
Truth                        ✅
Seller Commercial Genome     ✅
R4 Commercial Reality        ✅
Relationship Truth           ✅
R5 Structural Route          ✅
Contact Truth / R6            ⏳ Build 8
Workflow authority            ❌ not introduced
Execution authority           ❌ not introduced
```

Build 8 must bind R5 `CONTACT_TRUTH_REQUIRED` paths to categorical person/contact Truth: identity, current employer, current role and exact personal channel ownership/currentness. Organisational routes must remain usable without inventing a named person.
