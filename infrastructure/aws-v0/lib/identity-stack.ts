import { Aws, CfnOutput, Duration, Stack, StackProps } from "aws-cdk-lib";
import * as iam from "aws-cdk-lib/aws-iam";
import { Construct } from "constructs";

export interface MrAwsV0IdentityStackProps extends StackProps {
  readonly githubSubject?: string;
}

export class MrAwsV0IdentityStack extends Stack {
  public constructor(scope: Construct, id: string, props: MrAwsV0IdentityStackProps) {
    super(scope, id, props);

    new CfnOutput(this, "IdentityBoundary", {
      value: props.githubSubject ? "GITHUB-OIDC-ENABLED" : "GITHUB-OIDC-PENDING-SUBJECT",
      description: "AWS V0 identity bootstrap state",
    });

    if (!props.githubSubject) return;

    // Use the native CloudFormation IAM OIDC provider resource. This keeps the
    // Build 1 identity boundary free of CDK custom-resource Lambda machinery.
    const provider = new iam.CfnOIDCProvider(this, "GitHubActionsOidcProvider", {
      url: "https://token.actions.githubusercontent.com",
      clientIdList: ["sts.amazonaws.com"],
    });

    // Ref for AWS::IAM::OIDCProvider is the provider ARN. Using the resource
    // token directly also gives CloudFormation an explicit dependency edge.
    const githubPrincipal = new iam.WebIdentityPrincipal(provider.ref, {
      StringEquals: {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
        "token.actions.githubusercontent.com:sub": props.githubSubject,
      },
    });

    const deployRole = new iam.Role(this, "GitHubDeployRole", {
      roleName: "MarketRouteAwsV0GitHubDeployRole",
      description: "Short-lived GitHub OIDC actor for the MarketRoute AWS V0 CDK deployment boundary",
      assumedBy: githubPrincipal,
      maxSessionDuration: Duration.hours(1),
    });

    deployRole.addToPolicy(new iam.PolicyStatement({
      sid: "AssumeMarketRouteCdkBootstrapRoles",
      actions: ["sts:AssumeRole"],
      resources: [
        `arn:${Aws.PARTITION}:iam::${Aws.ACCOUNT_ID}:role/cdk-hnb659fds-deploy-role-${Aws.ACCOUNT_ID}-${Aws.REGION}`,
        `arn:${Aws.PARTITION}:iam::${Aws.ACCOUNT_ID}:role/cdk-hnb659fds-lookup-role-${Aws.ACCOUNT_ID}-${Aws.REGION}`,
        `arn:${Aws.PARTITION}:iam::${Aws.ACCOUNT_ID}:role/cdk-hnb659fds-file-publishing-role-${Aws.ACCOUNT_ID}-${Aws.REGION}`,
        `arn:${Aws.PARTITION}:iam::${Aws.ACCOUNT_ID}:role/cdk-hnb659fds-image-publishing-role-${Aws.ACCOUNT_ID}-${Aws.REGION}`,
      ],
    }));

    deployRole.addToPolicy(new iam.PolicyStatement({
      sid: "ReadCdkBootstrapVersion",
      actions: ["ssm:GetParameter"],
      resources: [
        `arn:${Aws.PARTITION}:ssm:${Aws.REGION}:${Aws.ACCOUNT_ID}:parameter/cdk-bootstrap/hnb659fds/version`,
      ],
    }));

    new CfnOutput(this, "GitHubDeployRoleArn", {
      value: deployRole.roleArn,
      description: "Set this ARN as the GitHub repository variable AWS_V0_DEPLOY_ROLE_ARN",
    });

    new CfnOutput(this, "GitHubOidcSubject", {
      value: props.githubSubject,
      description: "Exact GitHub OIDC subject trusted by the deployment role",
    });
  }
}
