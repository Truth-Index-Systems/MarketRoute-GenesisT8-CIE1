# MarketRoute V2 — Build 17: V1 → V2 Evidence Migration

## Purpose

Build 17 creates the one and only bridge from MarketRoute V1 into the constitutional V2 system. It is an offline ETL boundary, not a compatibility layer.

## What crosses the bridge

- company identities and domains;
- people identities;
- raw contact/access-point facts;
- seller business identity and raw seller configuration source material;
- campaign definitions and company scopes;
- source provenance;
- evidence and factual claims;
- historical research as migrated evidence.

## What never crosses as authority

- confidence or fit scores;
- viability or READY state;
- old Truth percentages;
- old R4/R5/R6 results;
- route quality/ranking;
- opportunity ordering or score;
- human approval authority;
- workflow/engagement execution state.

The export validator and database recursively reject those semantics. Campaigns are imported as `DRAFT`, and evidence is persisted with extraction method `MIGRATED`.

## Forensic controls

Each batch records a source-export fingerprint. Each migrated V1 identity receives an immutable mapping to its V2 identity and a database-computed factual record fingerprint. Rejections and migration audit events are append-only. Re-running the same clean export is idempotent; changing a previously mapped source payload fails closed.

## Constitutional handoff

Build 17 does not create Truth or authority. Once factual migration is complete, V2 must recompute:

`evidence → Truth → R4 → R5 → R6`

That is how imported companies earn V2 intelligence state from scratch.

## Source-specific export adapter

The final Build 17 package includes a concrete offline exporter for the real pre-V2 MarketRoute/Genesis schema (Forensic Build 8, through migration 0158). This closes the extraction gap while preserving the architectural rule that V2 has no runtime dependency on V1.

The adapter is GET-only, statically whitelists factual source tables, and explicitly excludes old Truth snapshots, CIE R4/R5/R6 decisions, opportunity state, engagement state and route topology. It also reads the shared Genesis G8 intelligence evidence store so the accumulated research asset is not lost; only the source evidence crosses, never its V1 weights, confidence, Truth output or route decision.
