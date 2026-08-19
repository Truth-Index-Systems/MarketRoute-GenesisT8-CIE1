# MarketRoute AWS V0 Infrastructure

This directory is the AWS-V0 Infrastructure-as-Code boundary. It is intentionally isolated from the Next.js application package.

## Build 1 state

Five stable stack boundaries exist:

- `MrAwsV0IdentityStack`
- `MrAwsV0DatabaseStack`
- `MrAwsV0ApplicationStack`
- `MrAwsV0ResearchStack`
- `MrAwsV0ObservabilityStack`

Build 1 does **not** create Aurora, Cognito, Amplify, Lambda, SQS, EventBridge, Bedrock, or CloudWatch product resources. The four non-identity stacks are placeholders only. The identity stack creates GitHub OIDC resources only when an exact `githubSubject` is supplied.

## Install and validate

```bash
npm install --no-audit --no-fund
npm run check
```

The dependency versions are deliberately exact in `package.json`. Commit the generated `package-lock.json` after the first install before treating CI as frozen/reproducible.

## CDK bootstrap

The London environment must be bootstrapped once before CDK deployment:

```bash
npx cdk bootstrap aws://801132668416/eu-west-2 \
  --tags Project=MarketRoute \
  --tags Environment=aws-v0 \
  --tags Owner=TruthIndexSystems \
  --tags ManagedBy=CDK \
  --tags CostCentre=MarketRoute
```

This creates the standard `CDKToolkit` bootstrap resources only. It does not deploy MarketRoute application/database infrastructure.

## GitHub OIDC bootstrap

Capture the exact GitHub OIDC subject for the `aws-v0` branch, then deploy only the identity stack:

```bash
npm run deploy:identity -- -c githubSubject='EXACT_SUBJECT_FROM_GITHUB'
```

Wildcards are rejected by the CDK app.

After deployment, copy the `GitHubDeployRoleArn` CloudFormation output into a GitHub repository **variable** named `AWS_V0_DEPLOY_ROLE_ARN`. Do not create AWS access-key secrets.

## Rollback

The Build 1 identity stack can be removed with:

```bash
npm run build
npx cdk destroy MrAwsV0IdentityStack --force -c githubSubject='EXACT_SUBJECT_USED_AT_DEPLOYMENT'
```

The `CDKToolkit` bootstrap stack should normally remain for later AWS-V0 builds. If the AWS V0 experiment is abandoned entirely, it can be deleted separately after all CDK stacks are removed.
