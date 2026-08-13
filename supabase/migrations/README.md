# MarketRoute V2 migrations

The V2 database begins from a clean constitutional history.

- Build 2: `0001`–`0005` — identity/tenancy, evidence, reasoning/authority/workflow separation, scheduler/observability, append-only integrity.
- Build 3: `0006_evidence_provenance_runtime.sql` — canonical evidence/provenance runtime.
- Build 4: `0007_truth_engine_v2.sql` — non-authoritative categorical Truth Engine.
- Build 5: `0008_seller_commercial_genome.sql` — first-party Seller Commercial Genome.
- Build 6: `0009_commercial_reality_r4.sql` — first authority writer, R4 Commercial Reality.
- Build 7: `0010_relationship_truth_and_route_authority_r5.sql` — Truth-qualified relationship ontology, canonical graph and R5 Route Authority.
- Build 8: `0011_contact_truth_and_authority_r6.sql` — Contact Truth and R6 Contact Authority.
- Build 9: `0012_unified_authority_lifecycle.sql` — derived R4→R5→R6 lifecycle, founder review provenance and workflow/authority separation.

Build 9 keeps exactly three authority writers. Execution permission remains future work.
