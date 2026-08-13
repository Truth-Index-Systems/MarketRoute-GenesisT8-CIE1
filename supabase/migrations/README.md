# MarketRoute V2 migrations

The V2 database begins from a clean constitutional history.

- Build 2: `0001`–`0005` — identity/tenancy, evidence, reasoning/authority/workflow separation, scheduler/observability, append-only integrity.
- Build 3: `0006_evidence_provenance_runtime.sql` — canonical evidence/provenance runtime.
- Build 4: `0007_truth_engine_v2.sql` — non-authoritative categorical Truth Engine.
- Build 5: `0008_seller_commercial_genome.sql` — first-party Seller Commercial Genome.
- Build 6: `0009_commercial_reality_r4.sql` — first authority writer, R4 Commercial Reality.
- Build 7: `0010_relationship_truth_and_route_authority_r5.sql` — Truth-qualified relationship ontology, canonical commercial graph, and second authority writer R5.

Build 7 deliberately does not create contact authority or execution permission.
