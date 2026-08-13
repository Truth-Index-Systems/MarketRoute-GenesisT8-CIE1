# MarketRoute V2 migrations

The V2 database begins from a clean constitutional history.

Build 2 owns migrations `0001`–`0005`:

1. `0001_platform_identity_and_tenancy.sql` — organisations, membership, seller businesses and campaigns.
2. `0002_canonical_entities_and_evidence.sql` — canonical companies/people plus raw source, acquisition, evidence and claim provenance.
3. `0003_reasoning_authority_and_workflow_separation.sql` — non-authoritative reasoning, locked authority ledgers, opportunities and human workflow.
4. `0004_scheduler_jobs_and_observability.sql` — leases, resumable jobs, attempts, AI cost telemetry and audit events.
5. `0005_append_only_integrity_and_build2_release.sql` — append-only enforcement and the Build-2 release marker.

Authority storage exists, but **Build 2 registers zero authority writers**. Direct authority DML is revoked from `authenticated` and `service_role`. A future authority build must register a writer by migration and write through a security-definer persistence boundary that sets the transaction-local `marketroute.authority_writer` context.
