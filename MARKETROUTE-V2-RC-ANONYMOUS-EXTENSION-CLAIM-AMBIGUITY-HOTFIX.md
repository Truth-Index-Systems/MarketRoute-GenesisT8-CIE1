# MarketRoute V2 RC — Anonymous Discovery Extension Claim Ambiguity Hotfix

## Fault
`marketroute_claim_anonymous_discovery_extension_v1` returned HTTP 400 when invoked by the bootstrap worker.
The function is `RETURNS TABLE(... run_id ...)`, so `run_id` is also a PL/pgSQL output variable. The statement `ON CONFLICT(run_id)` therefore creates a PL/pgSQL column/variable ambiguity at runtime.

## Fix
- Replace `ON CONFLICT(run_id)` with the explicit unique constraint `ON CONFLICT ON CONSTRAINT anonymous_discovery_extension_jobs_run_id_key`.
- Retain service-role-only execution, ACTIVE/CLAIMED run eligibility, ACTIVE campaign requirement, paid-entitlement exclusion, target ceiling, expiry boundary, and three-attempt ceiling.
- Qualify the attempt-count increment in the claimed job update.

## Deployment
Run `APPLY-IN-SUPABASE-MARKETROUTE-V2-ANONYMOUS-EXTENSION-CLAIM-AMBIGUITY-HOTFIX.sql` first, then deploy the ZIP so migration/source history remains aligned.

No environment-variable changes.

## Validation
- Hotfix static: 8/8
- Hotfix adversarial: 6/6
- Build 18 release certification: 34/34
- Complete `npm run production:check`: PASS

## Expected next bootstrap trace
`marketroute_claim_anonymous_discovery_extension_v1` should return 200. If the current Discovery run is still below its target and eligible, bootstrap should continue into extension execution rather than terminating at the claim RPC.
