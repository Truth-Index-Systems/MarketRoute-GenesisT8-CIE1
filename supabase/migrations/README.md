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
- Build 10: `0013_genesis_autonomous_research_engine.sql` — authority-driven autonomous research planning, budget governance, scheduler leasing/recovery and evidence-only provider execution.

Build 10 keeps exactly three authority writers. Research is not authority and cannot mutate opportunity workflow.

- Build 11: `0014_opportunity_engine.sql` — non-authoritative opportunity projection, authority-ready materialisation, system reviewability synchronisation and dimensional/Pareto product semantics.

Build 11 keeps exactly three authority writers. Opportunity state is a product projection, not commercial authority.

- Build 12: `0015_engagement_engine.sql` — path-bound engagement generation/review/approval/queue/delivery with live send-time R4/R5/R6 recheck and reconciliation-safe delivery semantics.
- Build 13: `0016_canonical_application_read_model.sql` — service-role-only canonical application read model for command centre, campaign, company intelligence, engagement and lineage-scoped claim provenance.

Build 13 keeps exactly three authority writers. The read model is presentation composition only and performs no authority, workflow or engagement mutation.
- Build 15C: `0018_build15c_readability_onboarding.sql` — onboarding identity capture that creates the organisation and seller-business identity together from organisation name + full company website URL. Internal workspace slugs are generated automatically. No commercial authority is created or mutated.
