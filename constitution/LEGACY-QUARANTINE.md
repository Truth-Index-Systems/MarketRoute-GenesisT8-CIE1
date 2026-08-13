# V1 Quarantine Contract

MarketRoute V1 is not a dependency of MarketRoute V2.

Forbidden in the V2 runtime:
- G4/G5/G8 runtime imports
- MR-TI compatibility imports
- CIE compatibility adapters
- V1 RPC names
- V1 views
- V1 authority tables
- legacy opportunity scoring
- legacy route viability booleans
- compatibility directories or modules

The future V1→V2 migration is one-way ETL of explicitly whitelisted evidence/factual data only.
