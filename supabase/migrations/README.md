# MarketRoute V2 migrations

The V2 database begins from a clean constitutional history.

Build 2 owns migrations `0001`–`0005`.

Build 3 adds:

6. `0006_evidence_provenance_runtime.sql` — canonical source identity snapshots, evidence-owned dependence families, deterministic fingerprint versions, RPC-only transactional evidence/claim persistence, duplicate collision checks, and source-identity immutability.

Authority storage still exists with **zero registered authority writers**. Build 3 creates evidence provenance only; it does not calculate Truth or commercial authority.
