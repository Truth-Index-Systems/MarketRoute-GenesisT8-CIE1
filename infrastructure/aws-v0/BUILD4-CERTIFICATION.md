# AWS V0 Build 4 — Final Certification

**Status:** CERTIFIED / FROZEN

Build 4 establishes MarketRoute's first AWS-native database access boundary over the Aurora Serverless v2 RDS Data API while leaving the existing Supabase runtime/reference stack untouched.

## Certified implementation

Starting head: `d123f1d7f0a52f4a0af73d4b28e0e97d032e4f66`

Implementation commit: `6ff8f4f35f61f18254adc8bb1e893d4a8486f318`

Build 4 added only:

- `platform/database/AWS_DATA_API.md`
- `platform/database/aws-data-api-operations.ts`
- `platform/database/aws-data-api-types.ts`
- `platform/database/aws-data-api.ts`
- `scripts/validate-aws-v0-build4-data-api.mjs`
- `tests/adversarial/aws-v0-build4-data-api.mjs`

The boundary is server-only and exposes named operations rather than arbitrary SQL, table names, or routine names. The initial live-proof operation set is `system.health`, `system.currentDatabase`, `commercial.publicPlans`, `genesis.growthSettings`, and `truth.policyBinding`.

## Live Aurora proof

Target: account `801132668416`, region `eu-west-2`, Aurora cluster `marketroute-aws-v0`, database `marketroute`.

The live CloudShell proof established:

- Aurora status `available`
- engine `aurora-postgresql` version `16.8`
- RDS Data API enabled
- `system.health` returned `1`
- current database returned `marketroute`
- public plans returned Starter £99 / Growth £249 / Scale £599
- active-market governance remained Starter 1 / Growth 3 / Scale 10
- Genesis growth remained disabled
- Truth policy lookup for `PERSON / employment.current` returned `PERSON_CURRENT_EMPLOYMENT_V1`
- a Data API transaction was successfully begun, read from, and rolled back with `Rollback complete`

No transaction commit was performed during the Build 4 proof.

## Post-proof invariants

Immediately after the live proof:

- users: 0
- organisations: 0
- companies: 0
- claims: 0
- opportunities: 0
- Genesis growth: disabled
- Growth active-market limit: 3
- Scale active-market limit: 10

The Build 3 canonical baseline remains frozen at SHA-256 `46d9c3aee85d1021d7f514c0384aef036b7f53073a7aa78be4bfabd3266d5e5a`.

The Build 4 implementation commit compiled successfully through the existing Vercel reference deployment check.

## Gates

4.0 exact starting head — PASS  
4.1 database access inventory — PASS  
4.2 adapter contract — PASS  
4.3 implementation boundary — PASS  
4.4 adversarial safety boundary — PASS  
4.5 server-only boundary — PASS  
4.6 repository compile — PASS  
4.7 live Aurora Data API read smoke — PASS  
4.8 transaction begin/read/rollback — PASS  
4.9 canonical invariants preserved — PASS  
4.10 certification receipt — PASS

## Freeze law

Build 4 is closed. Do not reopen it without a concrete defect or a later numbered migration requirement. Build 5 must start from the commit containing this certification. Build 5 is identity/Cognito work only; it must not enable Genesis growth, rewrite Truth/R4/R5/R6/CIE/UDOSIB semantics, or alter the frozen Build 3 canonical baseline.

`AWS_V0_AUTODEPLOY_ENABLED` remains false unless explicitly changed by a later controlled build.
