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

### 0019 — Build 17 V1 evidence migration

`0019_v1_evidence_migration.sql` installs service-role-only offline ETL RPCs, immutable V1→V2 mapping/audit tables, factual whitelist enforcement and migrated evidence lineage. It creates no authority writer and imports no Truth/workflow state.

### Production activation / operations

- `0020_production_activation_runtime.sql` — production OpenAI/cron runtime support; no authority writer.
- `0021_founder_dashboard_observability.sql` — founder-only production observability; read-only authority surface.
- `0022_genesis_database_growth.sql` — autonomous shared intelligence-bank growth across ten canonical industries.
- `0023_production_runtime_ambiguity_cost_hotfix.sql` — production RPC ambiguity and growth-cost accounting repairs.
- `0024_truth_entity_snapshot_ambiguity_hotfix.sql` — qualified final entity-Truth snapshot lookup.
- `0025_growth_seed_to_density_policy.sql` — deterministic seed-to-density scheduler policy: 50/industry seed floor, then PROFILE → ROUTES → CONTACTS before further breadth batches.
- `0026_route_relationship_claim_fingerprint_version_hotfix.sql` — restores the mandatory canonical claim-fingerprint version on relationship claims.
- `0027_production_activation_hardening.sql` — first-party seller offering, fail-closed constraint consistency, retry reset, Genesis-bank-first activation candidates and truthful bootstrap failure reporting.
- `0028_seller_genome_json_operator_hotfix.sql` — disambiguates JSON extraction before exact-key removal in the seller-genome validator, repairing production SQLSTATE `22P02` without changing validation policy or authority.
- `0029_activation_company_domain_hotfix.sql` — repairs the over-escaped activation hostname regex so valid discovered or Genesis-bank domains can enter campaign scope.
