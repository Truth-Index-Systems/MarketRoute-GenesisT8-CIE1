# MarketRoute V2

Constitutional rebuild of MarketRoute.

## Current build

**Build 13 — Canonical Application API + Authoritative Read Model**

The live authority spine remains unchanged:

`Seller Genome + Target Truth → R4 Commercial Reality → Relationship Truth/Graph → R5 Route Authority → Contact Truth → R6 Contact Authority → derived authority lifecycle → Opportunity projection → Engagement`

Exactly three authority writers exist: **R4, R5 and R6**. Build 13 adds no writer and performs no workflow or engagement mutation.

Build 13 creates the single server-side read contract that future MarketRoute UI surfaces are allowed to consume. It composes the existing authoritative outputs rather than re-deciding them. Current Truth, R4 boundaries, R5 graph paths, R6 contact bindings, research pressure, human workflow, engagement state and execution predicates are returned through service-role-only canonical RPCs and validated by the application layer.

Browser-direct access to the authority/read-model RPCs remains forbidden. The UI will consume `ApplicationReadService` after authenticated server-side scope resolution in later presentation builds.

The main company/campaign/command-centre payloads deliberately do not embed raw evidence. Build 13 adds a separate, bounded `CLAIM_PROVENANCE` read for a future provenance drawer. A claim snapshot can be inspected only if it is present in the **current R4/R5/R6 lineage for that exact organisation, campaign and company**. Arbitrary historical or guessed snapshot IDs fail closed.

No legacy opportunity, fit, route-quality, viability or confidence score is admitted into the application contract.
