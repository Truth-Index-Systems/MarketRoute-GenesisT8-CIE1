# Canonical application read API

Build 13 creates the only supported read contract for future MarketRoute UI surfaces.

The UI must not reconstruct Truth, R4, R5, R6, research pressure, workflow readiness, execution permission, or engagement state from raw persistence tables. Server-side product surfaces consume `ApplicationReadService`, which in turn calls service-role-only canonical read RPCs.

Main command-centre/campaign/company reads do not embed raw evidence. Evidence is available only through the bounded `claimProvenance` method, and the requested Truth snapshot must belong to the exact current R4/R5/R6 lineage for the selected organisation, campaign and company.

No browser-direct Supabase authority/read-model access is introduced in this build. Authenticated HTTP/UI transport is a later presentation concern; the application contract is stable first.
