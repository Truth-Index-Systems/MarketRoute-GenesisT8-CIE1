# MarketRoute AWS V0 — Build 1 Certification Trigger

This file records the final Build 1 OIDC deployment verification trigger.

## Confirmed before this commit

- `aws-v0` is branched from the RC 0.68 freeze baseline.
- AWS V0 CDK source constitution passes.
- TypeScript compilation passes.
- `cdk synth` passes.
- Synthesized resource-boundary validation passes.
- AWS environment `aws://801132668416/eu-west-2` is bootstrapped.
- `MrAwsV0IdentityStack` is deployed.
- GitHub OIDC subject is branch-pinned to `refs/heads/aws-v0`.
- `AWS_V0_DEPLOY_ROLE_ARN` repository variable has been configured by the repository owner.

This commit exists to trigger the `AWS V0 Infrastructure` workflow and prove end-to-end short-lived GitHub OIDC role assumption plus CDK deployment. It introduces no runtime application or database resource.
