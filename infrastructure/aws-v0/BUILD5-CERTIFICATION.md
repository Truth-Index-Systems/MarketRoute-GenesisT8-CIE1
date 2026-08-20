# AWS V0 Build 5 — Final Certification

**Status:** CERTIFIED / FROZEN

Build 5 establishes MarketRoute's AWS-native customer identity boundary using Amazon Cognito for human authentication and Aurora for canonical internal actor identity. The existing Supabase/Vercel runtime remains a reference system and is not cut over by this build.

## Certified implementation

Frozen Build 4 starting head: `bc0c9585caa499730f907b6f6a31bf72e2dc59e0`

Build 5 implementation lineage:

- `4906d19c222d2215c24cb09faf5c5001c8286b4b` — Cognito identity foundation
- `4ef8326bf28d6edbcfb65f68864da3719123138d` — Cognito JWK type import fix
- `1a5c26bc0a0d72f7b4d69572a94d1f611cdc8c22` — strict Cognito JWK conversion fix / certified implementation parent

Build 5 adds a dedicated Cognito user pool/client stack, an additive Aurora identity-mapping migration, a server-only Cognito authentication/JWT verifier, a server-only Cognito-to-Aurora identity resolver boundary, and the named Data API operation `identity.resolveActor`.

The governing identity law is:

> Cognito authenticates the human. Aurora identifies the MarketRoute actor.

A Cognito `sub` is an external principal identifier only. It must never be used directly as a MarketRoute business/domain foreign key. Organisation membership and business authority remain PostgreSQL truth.

## Frozen Build 3 baseline

The canonical Build 3 baseline remains byte-for-byte frozen at SHA-256:

`46d9c3aee85d1021d7f514c0384aef036b7f53073a7aa78be4bfabd3266d5e5a`

Build 5 did not modify or replay `database/aws/0001_marketroute_aws_canonical_baseline.sql`.

The only Build 5 database schema change is the additive migration:

`database/aws/0002_marketroute_cognito_identity_mapping.sql`

## CI / synthesis proof

GitHub Actions workflow run `32347678719` completed its `validate` job successfully. The run proved:

- AWS V0 source constitution validation
- Build 5 Cognito foundation validation
- adversarial Cognito boundary validation
- short-lived AWS OIDC role assumption
- TypeScript/source validation
- CDK synthesis and resource validation
- live OIDC identity synthesis

The workflow `deploy` job was skipped by design. `AWS_V0_AUTODEPLOY_ENABLED` remained false.

The final Build 5 implementation parent also passed the existing Vercel reference compile/deployment check.

## Live Cognito infrastructure proof

Target AWS account: `801132668416`  
Region: `eu-west-2`  
CloudFormation stack: `MrAwsV0CognitoStack`

Controlled CloudShell deployment established:

- stack status `CREATE_COMPLETE`
- user pool `marketroute-aws-v0-users`
- user pool ID `eu-west-2_SgJ0EYBxM`
- public web client ID `2vpqcibic80c07o64j30dig09e`
- issuer `https://cognito-idp.eu-west-2.amazonaws.com/eu-west-2_SgJ0EYBxM`
- JWKS endpoint at the issuer `/.well-known/jwks.json`
- deletion protection `ACTIVE`
- email sign-in and email auto-verification enabled
- MFA `OFF` for AWS V0
- token revocation enabled
- `ALLOW_USER_PASSWORD_AUTH`, `ALLOW_USER_SRP_AUTH`, and `ALLOW_REFRESH_TOKEN_AUTH`
- access token lifetime 1 hour
- ID token lifetime 1 hour
- refresh token lifetime 30 days
- no Cognito Hosted UI/domain introduced
- no app-client secret introduced

## Aurora migration proof

Migration `0002_marketroute_cognito_identity_mapping.sql` was applied manually through the RDS Data API inside one controlled transaction.

Pre-migration proof established:

- identity mapping table absent
- identity resolver function absent
- users 0
- organisations 0
- companies 0
- claims 0
- opportunities 0
- Genesis growth disabled

All 7 executable migration statements were applied inside the transaction. Before commit, the new table/function existed while runtime rows remained zero. The transaction then committed successfully.

Post-commit proof established:

- `marketroute_external_identities` exists
- `marketroute_resolve_external_identity_v1(...)` exists
- external identities 0
- users 0
- organisations 0
- companies 0
- claims 0
- opportunities 0
- Genesis growth disabled

## Live authentication proof

A temporary Cognito test principal was used only for Build 5 certification. The proof established:

- SignUp succeeded
- email confirmation succeeded
- `USER_PASSWORD_AUTH` succeeded
- access, ID, and refresh tokens were returned
- access JWT RSA signature valid
- ID JWT RSA signature valid
- exact issuer validated
- exact client audience validated
- token use validated
- expiry validated
- `GetUser` returned the same Cognito subject
- verified email state was true
- `REFRESH_TOKEN_AUTH` returned another valid access/ID token pair
- Aurora remained `users=0 / identities=0` before identity resolution

No password, confirmation code, raw JWT, refresh token, or test email is retained in this certification.

## Cognito-to-internal-actor proof

Using the verified Cognito principal, the Build 5 resolver was exercised live against Aurora.

The proof established:

- Cognito principal was reauthenticated before resolution
- Aurora began at zero runtime identity state
- first resolution created exactly one internal `marketroute_users` row
- first resolution created exactly one `marketroute_external_identities` mapping
- internal MarketRoute actor UUID differed from the external Cognito subject
- internal user status was `ACTIVE`
- mapping recorded `provider=COGNITO`
- mapping recorded verified email state
- organisation memberships remained 0
- organisations/companies/claims/opportunities remained 0
- Genesis growth remained disabled
- second resolution returned the same internal actor UUID
- second resolution created no duplicate user or identity mapping

This proves that authentication establishes identity but does not infer organisation authority.

## Cleanup proof

After the live identity proof:

- the exact temporary internal actor was deleted
- FK cascade removed its external identity mapping
- users returned to 0
- external identities returned to 0
- organisations remained 0
- companies remained 0
- claims remained 0
- opportunities remained 0
- Genesis growth remained disabled
- the temporary Cognito user was deleted
- the secure temporary refresh-token continuation file was deleted

AWS V0 therefore returned to a clean zero-runtime test state after certification.

## Gates

5.0 exact frozen Build 4 head — PASS  
5.1 auth / identity inventory — PASS  
5.2 identity mapping contract — PASS  
5.3 Cognito IaC + additive migration foundation — PASS  
5.4 server-only Cognito / JWT boundary — PASS  
5.5 adversarial Cognito security boundary — PASS  
5.6 repository compile / CDK synthesis / OIDC validation — PASS  
5.7 controlled Cognito deployment — PASS  
5.8 live signup / confirm / auth / JWT / refresh proof — PASS  
5.9 Cognito-to-internal-actor Aurora proof + cleanup — PASS  
5.10 certification / freeze — PASS

## Freeze law

Build 5 is closed. Do not reopen it without a concrete defect or a later numbered migration requirement.

Build 6 must start from the commit containing this certification and is the Amplify shadow SSR / AWS application-hosting build. Build 6 may pin the RDS Data API SDK dependency when the AWS adapter becomes a live application transport, but it must not weaken the Build 5 identity contract.

The following remain frozen unless a later numbered build explicitly requires change:

- Cognito `sub` is external identity only
- `marketroute_users.id` is the canonical internal MarketRoute actor UUID
- organisation/business authorization remains PostgreSQL truth
- no browser AWS credentials
- no arbitrary SQL database boundary
- no RLS reintroduction for AWS V0
- no Supabase production cutover as part of Build 5
- no Genesis activation
- no Truth / R4 / R5 / R6 / CIE / UDOSIB semantic change
- Build 3 canonical baseline remains immutable
- `AWS_V0_AUTODEPLOY_ENABLED` remains false unless explicitly changed by a later controlled build
