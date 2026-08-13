# Commercial Reality / R4

Build 6 introduces the first commercial authority stage in MarketRoute V2.

R4 consumes only persisted seller semantic context and Truth-qualified target claims. It emits one categorical decision:

- `COMMERCIAL_CANDIDATE`
- `RESEARCH_REQUIRED`
- `NOT_ADMISSIBLE`

No continuous score, probability, confidence, ranking, or weighted average may grant R4 authority. Mandatory boundaries are explicit and any unresolved/stale/contradicted boundary blocks `COMMERCIAL_CANDIDATE`. A known violation of a mandatory or HARD seller constraint yields `NOT_ADMISSIBLE`.
