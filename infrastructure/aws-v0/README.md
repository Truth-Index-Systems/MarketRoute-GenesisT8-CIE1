# MarketRoute AWS V0 Infrastructure

This directory is the AWS-V0 Infrastructure-as-Code boundary. It is intentionally isolated from the Next.js application package.

## Current state

Five stable stack boundaries exist:

- `MrAwsV0IdentityStack`
- `MrAwsV0DatabaseStack`
- `MrAwsV0ApplicationStack`
- `MrAwsV0ResearchStack`
- `MrAwsV0ObservabilityStack`

Build 1 certified the repository/CDK/GitHub OIDC deployment path.

Build 2 activates **only** `MrAwsV0DatabaseStack` with a fresh Aurora PostgreSQL serverless foundation. Application, research and observability stacks remain boundary-only placeholders. Build 2 intentionally creates no MarketRoute schema and no research data; Build 3 owns the canonical AWS schema baseline.

## Build 2 database boundary

- Region: `eu-west-2` (London)
- Aurora PostgreSQL: `16.8` LTS
- Writer: Aurora serverless / `db.serverless`
- Capacity: `0-2 ACU`
- Auto-pause: `300 seconds`
- RDS Data API: enabled
- Storage encryption: enabled
- Administrator credentials: generated in AWS Secrets Manager
- Networking: dedicated two-AZ VPC, private isolated subnets, no NAT gateway, no public database endpoint
- RDS Proxy: not used
- Sandbox deletion protection: disabled
- CDK removal policy: destroy
- Schema/data: none in Build 2

## Install and validate

```bash
npm install --no-audit --no-fund
npm run check
```

The dependency versions are deliberately exact in `package.json`. Commit the generated `package-lock.json` after the first install before treating CI as frozen/reproducible.

## Deployment safety latch

GitHub validation runs on every relevant `aws-v0` change. AWS deployment runs only when both repository variables are present:

- `AWS_V0_DEPLOY_ROLE_ARN`
- `AWS_V0_AUTODEPLOY_ENABLED=true`

Keep `AWS_V0_AUTODEPLOY_ENABLED=false` while reviewing/synthesizing a build.

Build 2 deployment is deliberately scoped to the database stack only:

```bash
npm run deploy:database -- -c githubSubject='EXACT_SUBJECT_FROM_GITHUB'
```

The GitHub deploy job also verifies that Aurora PostgreSQL `16.8` is currently orderable as `db.serverless` in `eu-west-2` before CDK deployment.

## CDK bootstrap

The London environment has been bootstrapped with the standard `CDKToolkit` resources for account `801132668416`.

## GitHub OIDC

The identity stack owns the GitHub OIDC provider and the short-lived `MarketRouteAwsV0GitHubDeployRole`. No permanent AWS access keys are used by GitHub Actions.

## Rollback

Build 2 database resources can be removed with:

```bash
npm run destroy:database
```

This is intentionally destructive in AWS V0 because Build 2 contains no canonical MarketRoute data. The `CDKToolkit` bootstrap stack and Identity stack should remain for later builds unless AWS V0 is abandoned entirely.
