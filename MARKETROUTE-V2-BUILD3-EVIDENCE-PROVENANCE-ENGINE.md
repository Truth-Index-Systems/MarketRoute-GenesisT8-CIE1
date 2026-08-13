# MarketRoute V2 — Build 3
## Evidence & Provenance Engine

Status: **BUILD COMPLETE — DEPLOYMENT CANDIDATE**

Build 3 is the first MarketRoute V2 runtime data path. It deliberately creates **no Truth state and no commercial authority**. Its responsibility is to make raw research persistable without allowing provenance, duplicate handling or dependence-family identity to be improvised by downstream reasoning.

## Constitutional objective

MarketRoute V2 now enforces this sequence:

`source -> acquisition -> evidence -> claim -> claim/evidence polarity`

None of those objects is commercial authority.

The authority writer registry remains empty.

## Core evidence kernel

New `core/evidence` modules implement:

- canonical text normalisation;
- canonical HTTP/HTTPS URL identity;
- removal of tracking parameters;
- canonical query ordering;
- `www` and transport/default-port normalisation;
- stable canonical JSON;
- deterministic SHA-256 implemented without framework/provider dependencies;
- source identity fingerprints;
- conservative publisher dependence families;
- evidence fingerprints;
- claim fingerprints;
- explicit fingerprint/normalisation versions.

### Source identity

Source identity is based on canonical source kind + stable source locator. Titles and observation metadata cannot change identity.

For web sources, equivalent URLs such as tracking variants, HTTP/HTTPS transport variants, `www` aliases and reordered query parameters converge where the semantic locator is equivalent.

Meaningful query parameters remain identity-bearing.

### Dependence families

Dependence-family identity is calculated once at source/evidence ingestion and snapshotted on evidence.

For web evidence, pages from the same publisher domain are conservatively placed in one dependence family. A later claim-linking call cannot supply its own family key.

This prevents copied/repeated evidence from manufacturing apparent independence by choosing different family labels downstream.

## Database migration 0006

`0006_evidence_provenance_runtime.sql` adds:

### Source provenance

- `source_identity_fingerprint`
- `stable_locator`
- `dependence_family_key`
- `normalisation_version`
- source identity immutability trigger

### Evidence provenance snapshots

- `source_identity_fingerprint`
- `dependence_family_key`
- `fingerprint_version`

### Claim versioning

- `fingerprint_version`

### RPC-only writes

Direct service-role mutation is revoked for:

- `source_records`
- `source_acquisitions`
- `evidence_items`
- `claims`
- `claim_supersessions`
- `claim_evidence_links`

Writes occur through:

- `marketroute_ingest_evidence_v1`
- `marketroute_record_claim_evidence_v1`
- `marketroute_supersede_claim_v1`

All three require the backend service role.

## Transactional ingestion contract

`marketroute_ingest_evidence_v1`:

1. resolves/creates canonical source identity;
2. fails closed on source fingerprint collision;
3. always records the acquisition event;
4. deduplicates evidence by deterministic evidence fingerprint;
5. fails closed if the same fingerprint points to a different immutable payload;
6. snapshots source identity and dependence family onto the evidence row.

A repeated crawl may therefore create a new acquisition without creating fake new evidence.

## Claim contract

`marketroute_record_claim_evidence_v1`:

- deduplicates canonical claims;
- fails closed on claim fingerprint collision;
- derives the link's dependence family from the evidence row;
- does not accept caller-supplied dependence-family identity;
- requires exact claim/evidence subject identity;
- preserves tenant isolation;
- prevents a single evidence item from being both SUPPORTS and CONTRADICTS for the same claim;
- makes repeated identical links idempotent.

Claim correction remains append-only through explicit supersession.

## Runtime architecture

New server-side runtime:

- `platform/database/postgrest-rpc.ts`
- `platform/database/evidence-repository.ts`
- `application/evidence/service.ts`

The application service performs deterministic canonicalisation before persistence. The database then enforces collision, tenancy, subject and provenance invariants.

No public evidence HTTP endpoint exists in Build 3.

## Adversarial findings closed during the build

### 1. HTTP default-port identity bug

The first test pass found that converting HTTP to HTTPS before removing port 80 could create `https://host:80` as a distinct identity. Canonicalisation now evaluates the original transport/default port before normalising transport.

### 2. `www` identity fragmentation

`www.example.com` and `example.com` initially generated separate source identities despite representing the same publisher endpoint in the tested canonical case. Build 3 now canonicalises the `www` alias.

### 3. Caller-manufactured evidence independence

Build 2 allowed `dependence_family_key` to be supplied when linking evidence. Build 3 makes the family evidence-owned and database-checked.

### 4. Cross-subject evidence leakage

A same-tenant claim could theoretically cite evidence scoped to another subject. Build 3 now requires exact `subject_type + subject_id` equality between claim and evidence.

### 5. Dual polarity on one evidence item

The Build-2 uniqueness contract allowed the same claim/evidence pair to exist once as SUPPORTS and once as CONTRADICTS. Build 3 adds one-polarity-per-claim/evidence uniqueness.

## Explicit non-goals

Build 3 does **not** implement:

- evidence strength;
- freshness mathematics;
- Truth state;
- calibrated probability;
- commercial reality;
- route authority;
- contact authority;
- opportunity workflow transitions;
- AI research orchestration.

Those capabilities must be introduced by later builds under separate constitutional gates.

## Verification

Full constitutional chain:

- Build 1 architecture: **15/15**
- AI boundary: **7/7**
- legacy quarantine: **3/3**
- authority manifest: **10/10**
- Build 2 schema: **44/44**
- Build 2 SQL: **12/12**
- Build 1 adversarial architecture: **18/18**
- Build 2 database adversarial: **22/22**
- Build 3 evidence static: **28/28**
- Build 3 SQL safety: **11/11**
- Build 3 canonicalisation adversarial: **21/21**
- Build 3 database adversarial: **25/25**

Total: **216/216 assertions PASS**

Additional compile gates:

- strict standalone evidence-core TypeScript compile: **PASS**
- whole-project TypeScript syntax/transpile (`--noCheck` in dependency-free audit workspace): **PASS**
- standalone Build-3 SQL byte-equals canonical migration 0006: **PASS**

The local workspace does not contain the project's installed Next/React dependency tree, so Vercel remains the final whole-framework type/build gate. Supabase remains the final PostgreSQL parser/runtime gate.

## Deployment order

1. Run `APPLY-IN-SUPABASE-MARKETROUTE-V2-BUILD3.sql` against the existing fresh V2 Supabase project.
2. Deploy this repository revision to Vercel.
3. Do not create authority or workflow capability manually.

## Next build

**Build 4 — Truth Engine V2**

Build 4 can now consume a provenance foundation that is deterministic, deduplicated, append-only and explicit about dependence. It should introduce evidence qualification, freshness, contradiction handling, dependence-family collapse, evidence sufficiency and categorical Truth states while preserving the rule that evidence strength is not calibrated probability.
