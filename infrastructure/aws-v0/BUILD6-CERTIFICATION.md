# AWS V0 Build 6 — Amplify SSR Shadow Certification

Status: CLOSED / CERTIFIED / FROZEN

Certified source parent: `c2bb34a4b9d1b13261e3209ff3c9ae85e4788618`
Frozen Build 5 parent: `f01f2ced55cbc9079f6d0c12cfe9d9a7547e833f`
Region: `eu-west-2`
Amplify application: `d21r3wzl6jmvfy`
Branch: `aws-v0`
Shadow URL: `https://aws-v0.d21r3wzl6jmvfy.amplifyapp.com`
Hosting platform: AWS Amplify Hosting, `WEB_COMPUTE`, Next.js SSR

## Certified scope

Build 6 establishes a private AWS-hosted MarketRoute shadow runtime without production cutover. The certified runtime path is:

`Amplify-hosted Next.js SSR -> Build 4 named-operation Data API adapter -> @aws-sdk/client-rds-data -> RDS Data API -> Aurora PostgreSQL`

The root application dependency is exact-pinned to `@aws-sdk/client-rds-data` version `3.1114.0`.

## Certified gates

- Build 5 frozen starting point preserved.
- Next.js 15.5.23 and Node 22.x compatibility validated.
- Amplify SSR application stack synthesized and deployed.
- Amplify branch remains `BETA`, manual build only, pull-request previews disabled, performance mode disabled, and Basic Auth enabled.
- AWS V0 application deployment remains outside automatic GitHub deployment flow.
- Amplify SSR compute role is least-privilege for the certified path: RDS Data API transaction/statement actions on the exact Aurora cluster and Secrets Manager read/describe on the exact Aurora secret.
- Amplify service role remains limited to CloudWatch log delivery responsibilities.
- Shadow health endpoint is unavailable outside `MARKETROUTE_AWS_SHADOW_MODE=true` and does not expose configuration values.
- Live Data API probe is shadow-only, server-side, named-operation-only, and contains no raw SQL.
- Vercel reference deployment remained green during Build 6 validation.

## Live hosting proof

Amplify release job `1` proved the initial private SSR shadow runtime.

Amplify release job `2` proved the Build 6.9B runtime source. The manual Amplify RELEASE API reported `commitId=HEAD`; source continuity was separately verified with both local and remote `aws-v0` pinned to `c2bb34a4b9d1b13261e3209ff3c9ae85e4788618` at proof time.

Job 2 observed:

- BUILD: `SUCCEED`
- DEPLOY: `SUCCEED`
- VERIFY: `SUCCEED`
- unauthenticated shadow Data API route: HTTP `401`
- authenticated route after controlled Basic Auth rotation: first attempt HTTP `503`, second attempt HTTP `200`

The successful live response contract was:

```json
{
  "status": "ok",
  "build": "AWS-V0-BUILD-6",
  "hosting": "amplify-shadow",
  "transport": "rds-data-api",
  "operation": "system.health",
  "databaseReachable": true,
  "resultOk": true,
  "productionCutover": false,
  "genesisEnabled": false
}
```

This is the first certified proof that the actual TypeScript Build 4 adapter executed successfully from the deployed Amplify SSR runtime through the AWS SDK and RDS Data API into Aurora.

## Security and cutover invariants

- Production cutover remains `false`.
- Genesis remains disabled in the shadow runtime.
- No browser AWS credentials were introduced.
- No raw SQL public application API was introduced.
- No Cognito-to-domain authority expansion occurred.
- No Truth / Genesis / R4 / R5 / R6 / CIE / UDOSIB / Discovery / billing / entitlement semantics were changed.
- No custom production domain was attached.
- Vercel remains the production/reference bridge until a later explicit cutover build.
- `AWS_V0_AUTODEPLOY_ENABLED=false` remains the intended deployment safety state.

## Operational note

During the Build 6.9B proof, the original temporary Basic Auth credential file was unavailable. A controlled CloudFormation update rotated only `AmplifyShadowBasicAuthPassword`; all other application stack parameters retained their previous values. The branch remained private, `BETA`, manual-build-only, with pull-request previews disabled. No source deployment, database migration, Cognito change, or production cutover was performed by that rotation.

## Freeze rule

Build 6 is frozen. Future changes to the AWS application runtime, hosting, Data API transport, or security boundary must be introduced through a new numbered build or an explicitly scoped migration/correction with new evidence. Do not rewrite Build 6 certification history.
