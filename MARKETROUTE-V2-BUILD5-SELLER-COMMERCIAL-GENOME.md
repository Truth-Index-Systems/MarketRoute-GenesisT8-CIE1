# MarketRoute V2 — Build 5: Seller Commercial Genome

## Release

- Build: **5 of 18**
- Release marker: `MRV2-BUILD5-SELLER-COMMERCIAL-GENOME`
- Seller genome schema: `MRV2-SELLER-GENOME-1.0.0`
- Canonicalisation: `MRV2-SELLER-CANON-1.0.0`
- Extraction contract: `MRV2-SELLER-EXTRACT-1.0.0`
- Canonical migration: `supabase/migrations/0008_seller_commercial_genome.sql`
- Commercial authority writers after this build: **0**

## Objective

Build 5 gives MarketRoute a canonical representation of the business doing the selling before any Commercial Reality reasoning is permitted. It is first-party declared context, not target Truth and not commercial authority.

The central design law is:

> **Seller meaning is canonical semantic input. Seller wording is explanation. Neither is commercial authority.**

## Canonical seller model

The genome contains eight semantic dimensions:

1. offerings
2. capabilities
3. commercial objectives
4. delivery
5. service geography
6. target characteristics
7. buyer assumptions
8. constraints

Every dimension is explicitly one of:

- `DECLARED`
- `EXPLICIT_NONE`
- `UNKNOWN`

`UNKNOWN` is never silently converted into `EXPLICIT_NONE`. Unknown dimensions carry an explicit research/onboarding question and make the genome `PARTIAL`.

### Commercial objectives

Objectives are typed categorically as one of:

- `ACQUIRE_CUSTOMERS`
- `EXPAND_ACCOUNTS`
- `BUILD_PARTNERSHIPS`
- `ENTER_MARKET`
- `SOURCE_SUPPLIERS`
- `RECRUIT_TALENT`
- `OTHER`

An objective may reference only offering keys present in the same canonical genome snapshot.

### Constraints

Constraints are categorical `HARD` or `PREFERENCE`. A declared constraint must carry machine-readable `valueCodes`; prose alone cannot hide the value that later deterministic reasoning will consume.

## Semantic / prose separation

`CanonicalSellerGenome` contains:

- `semantic`: stable machine meaning
- `explanatory`: founder-facing labels, descriptions, statements and notes

The semantic fingerprint is computed from the machine-semantic identity only. Therefore a wording change such as “bespoke software” → “custom software” can preserve semantic identity, while changing an offering, objective, geography, buyer assumption or constraint changes semantic identity.

This avoids unnecessary future R4 invalidation caused by copy edits.

## Dual lineage fingerprints

Supabase computes two distinct fingerprints:

### Exact content fingerprint

Captures the exact persisted extraction/provenance state, including source-material fingerprint, extraction versions and complete canonical genome.

### Semantic fingerprint

Captures only the canonical machine-semantic seller meaning. Arrays are database-canonicalised before hashing, so ordering cannot create a false semantic change.

Later R4 can therefore distinguish exact provenance change from material commercial-context change.

## Source material

New append-only table:

`seller_genome_source_materials`

Supported material kinds:

- `USER_DECLARED`
- `WEBSITE_ANALYSIS`
- `IMPORT`
- `COMPOSITE`

The source-material fingerprint is database-generated. Fingerprint collisions with a different immutable payload fail closed. If a creator user ID is supplied, Supabase verifies that user is an active member of the organisation.

## Seller genome snapshots

New append-only table:

`seller_commercial_genome_snapshots`

Supabase independently validates:

- exact top-level and nested semantic keys
- dimension states
- machine-code syntax
- duplicate keys/codes
- objective-to-offering references
- seller identity
- explicit unknowns
- missing-dimension derivation
- constraint machine semantics
- forbidden authority-like keys

The application cannot choose the semantic or content fingerprint.

## Campaign seller context

New append-only table:

`campaign_seller_context_selections`

A campaign selection binds:

- organisation
- campaign
- seller business
- exact genome snapshot
- selected objective key
- request-scoped idempotency ID
- exact input fingerprint
- semantic context fingerprint

### Lifecycle defect found and fixed

The first append-only design deduplicated selections by semantic input. That broke the legitimate sequence:

`Objective A → Objective B → intentionally re-select Objective A`

because the historical A row could be reused while B remained the latest event.

Build 5 now uses `selection_request_id`:

- same request ID + same payload = retry/deduplicate
- same request ID + different payload = fail closed
- new request ID = new founder-intent event, even when returning to an older objective

This preserves both append-only history and correct current selection.

## AI boundary

Build 5 defines a provider-neutral `SellerGenomeSemanticExtractor` port. It does not wire a live model/provider yet.

AI may extract and classify seller semantics. It may not emit or hide authority through fields resembling:

- confidence
- probability
- score
- rank
- fit
- viability
- authority
- priority

Unknown output keys are rejected rather than silently discarded. Numeric seller metadata cannot become a disguised commercial score.

## Database write boundary

Build 5 is RPC-write-only through:

- `marketroute_record_seller_genome_source_v1`
- `marketroute_persist_seller_genome_v1`
- `marketroute_select_campaign_seller_context_v1`
- `marketroute_get_current_campaign_seller_context_v1`

The first three are service-role write boundaries; direct DML on the three seller-genome ledgers is revoked. RLS grants authenticated members read visibility only within their organisation.

Internal canonicalisation/validation helpers are not exposed to service role.

## Commercial authority remains absent

Build 5 does **not**:

- register an authority writer
- create R4
- judge a target commercially viable
- rank opportunities
- create route authority
- create contact authority
- transition opportunity workflow
- grant execution permission

The authority writer registry remains empty.

## Verification

Full constitutional regression:

- architecture: **33/33**
- AI boundary: **7/7**
- legacy quarantine: **3/3**
- authority manifest: **10/10**
- Build 2 schema: **49/49**
- Build 2 SQL: **12/12**
- Build 1 architecture attacks: **18/18**
- Build 2 DB attacks: **22/22**
- Build 3 evidence static: **28/28**
- Build 3 SQL: **11/11**
- Build 3 evidence attacks: **21/21**
- Build 3 DB attacks: **25/25**
- Build 4 Truth static: **39/39**
- Build 4 SQL: **16/16**
- Build 4 Truth attacks: **25/25**
- Build 4 DB attacks: **30/30**
- Build 5 seller static: **29/29**
- Build 5 SQL: **15/15**
- Build 5 seller semantic attacks: **27/27**
- Build 5 DB attacks: **36/36**

**Total: 456/456 PASS**

Additional gates:

- changed Build-5 modules strict TypeScript compile: **PASS**
- whole V2 non-declaration TS/TSX transpilation: **PASS**
- standalone Build-5 SQL equals canonical migration `0008`: **PASS**

A local PostgreSQL/Supabase runtime is not available in this environment, so the fresh Supabase project remains the final DDL/parser/runtime gate. The local workspace also does not contain the installed Next/React dependency tree, so Vercel remains the final full framework build gate.

## Build 6 handoff

Build 6 — Commercial Reality / R4 — is the first build allowed to introduce a commercial authority writer.

Its input boundary must be:

`exact campaign seller-context selection + target Truth + versioned mandatory-boundary constitution`

R4 must be deterministic, database-verified, fingerprinted, time-bound and fail closed. AI may help create semantic inputs but may not decide commercial viability.
