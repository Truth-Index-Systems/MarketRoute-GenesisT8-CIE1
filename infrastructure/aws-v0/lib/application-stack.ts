import { ArnFormat, CfnOutput, CfnParameter, Stack, StackProps } from "aws-cdk-lib";
import * as amplify from "aws-cdk-lib/aws-amplify";
import * as iam from "aws-cdk-lib/aws-iam";
import { Construct } from "constructs";

const REPOSITORY_URL = "https://github.com/Truth-Index-Systems/MarketRoute-GenesisT8-CIE1";
const BRANCH_NAME = "aws-v0";
const DATABASE_NAME = "marketroute";

const AMPLIFY_BUILD_SPEC = `version: 1
frontend:
  phases:
    preBuild:
      commands:
        - nvm use 22
        - node --version
        - npm ci --no-audit --no-fund
    build:
      commands:
        - env | grep -E '^(MARKETROUTE_AWS_|MARKETROUTE_COGNITO_)' >> .env.production || true
        - npm run build
  artifacts:
    baseDirectory: .next
    files:
      - '**/*'
  cache:
    paths:
      - node_modules/**/*
      - .next/cache/**/*
`;

/**
 * Build 6: private Amplify Hosting shadow for the existing Next.js application.
 *
 * This stack creates hosting only. It does not cut production traffic away from
 * Vercel, does not migrate Supabase runtime routes, and does not enable Genesis.
 * The aws-v0 branch remains manually built and basic-auth protected while the
 * AWS application boundary is proven.
 */
export class MrAwsV0ApplicationStack extends Stack {
  public constructor(scope: Construct, id: string, props: StackProps) {
    super(scope, id, props);

    const githubAccessToken = new CfnParameter(this, "AmplifyGitHubAccessToken", {
      type: "String",
      noEcho: true,
      minLength: 1,
      description: "One-time GitHub personal access token used by Amplify GitHub App repository connection. Never commit this value.",
    });

    const shadowBasicAuthPassword = new CfnParameter(this, "AmplifyShadowBasicAuthPassword", {
      type: "String",
      noEcho: true,
      minLength: 16,
      description: "Private basic-auth password for the AWS V0 Amplify shadow branch.",
    });

    const auroraSecretArn = new CfnParameter(this, "AuroraSecretArn", {
      type: "String",
      allowedPattern: "^arn:aws:secretsmanager:eu-west-2:801132668416:secret:marketroute/aws-v0/database/admin-[A-Za-z0-9]+$",
      description: "Existing Build 2 Aurora admin secret ARN. The ARN is configuration; the secret value is never exposed to Amplify build settings.",
    });

    const cognitoUserPoolId = new CfnParameter(this, "CognitoUserPoolId", {
      type: "String",
      allowedPattern: "^eu-west-2_[A-Za-z0-9]+$",
      description: "Existing Build 5 Cognito user pool ID.",
    });

    const cognitoUserPoolClientId = new CfnParameter(this, "CognitoUserPoolClientId", {
      type: "String",
      allowedPattern: "^[A-Za-z0-9]{8,128}$",
      description: "Existing Build 5 public Cognito web client ID.",
    });

    const amplifySourceArn = this.formatArn({
      service: "amplify",
      resource: "apps",
      resourceName: "*",
      arnFormat: ArnFormat.SLASH_RESOURCE_NAME,
    });

    const amplifyPrincipal = new iam.PrincipalWithConditions(
      new iam.ServicePrincipal("amplify.amazonaws.com"),
      {
        StringEquals: { "aws:SourceAccount": this.account },
        ArnLike: { "aws:SourceArn": amplifySourceArn },
      },
    );

    const serviceRole = new iam.Role(this, "AmplifyServiceRole", {
      roleName: "MarketRouteAwsV0AmplifyServiceRole",
      assumedBy: amplifyPrincipal,
      description: "Least-privilege Amplify Hosting service role for AWS V0 SSR logs",
    });
    serviceRole.addToPolicy(new iam.PolicyStatement({
      sid: "AmplifySsrCloudWatchLogs",
      actions: [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:DescribeLogGroups",
        "logs:PutLogEvents",
      ],
      resources: ["*"],
    }));

    const computeRole = new iam.Role(this, "AmplifySsrComputeRole", {
      roleName: "MarketRouteAwsV0AmplifySsrComputeRole",
      assumedBy: amplifyPrincipal,
      description: "Branch-scoped AWS V0 SSR compute role for the named RDS Data API boundary",
    });

    const clusterArn = this.formatArn({
      service: "rds",
      resource: "cluster",
      resourceName: "marketroute-aws-v0",
      arnFormat: ArnFormat.COLON_RESOURCE_NAME,
    });

    computeRole.addToPolicy(new iam.PolicyStatement({
      sid: "MarketRouteNamedDataApiBoundary",
      actions: [
        "rds-data:ExecuteStatement",
        "rds-data:BeginTransaction",
        "rds-data:CommitTransaction",
        "rds-data:RollbackTransaction",
      ],
      resources: [clusterArn],
    }));
    computeRole.addToPolicy(new iam.PolicyStatement({
      sid: "MarketRouteAuroraSecretRead",
      actions: ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"],
      resources: [auroraSecretArn.valueAsString],
    }));

    const app = new amplify.CfnApp(this, "AmplifyApp", {
      name: "marketroute-aws-v0-shadow",
      description: "MarketRoute AWS V0 private shadow hosting (Build 6)",
      repository: REPOSITORY_URL,
      accessToken: githubAccessToken.valueAsString,
      platform: "WEB_COMPUTE",
      iamServiceRole: serviceRole.roleArn,
      enableBranchAutoDeletion: false,
      buildSpec: AMPLIFY_BUILD_SPEC,
      environmentVariables: [
        { name: "MARKETROUTE_AWS_SHADOW_MODE", value: "true" },
        { name: "MARKETROUTE_AWS_RDS_CLUSTER_ARN", value: clusterArn },
        { name: "MARKETROUTE_AWS_RDS_SECRET_ARN", value: auroraSecretArn.valueAsString },
        { name: "MARKETROUTE_AWS_RDS_DATABASE", value: DATABASE_NAME },
        { name: "MARKETROUTE_COGNITO_USER_POOL_ID", value: cognitoUserPoolId.valueAsString },
        { name: "MARKETROUTE_COGNITO_USER_POOL_CLIENT_ID", value: cognitoUserPoolClientId.valueAsString },
      ],
    });

    const branch = new amplify.CfnBranch(this, "AwsV0Branch", {
      appId: app.attrAppId,
      branchName: BRANCH_NAME,
      description: "Private AWS V0 shadow branch; manual builds only",
      stage: "BETA",
      framework: "Next.js - SSR",
      enableAutoBuild: false,
      enablePullRequestPreview: false,
      enablePerformanceMode: false,
      computeRoleArn: computeRole.roleArn,
      basicAuthConfig: {
        enableBasicAuth: true,
        username: "marketroute-shadow",
        password: shadowBasicAuthPassword.valueAsString,
      },
    });
    branch.addDependency(app);

    new CfnOutput(this, "BuildStatus", {
      value: "AWS-V0-BUILD-6-AMPLIFY-SHADOW",
      description: "Private Amplify Hosting SSR shadow; no production cutover",
    });
    new CfnOutput(this, "AmplifyAppId", { value: app.attrAppId });
    new CfnOutput(this, "AmplifyDefaultDomain", { value: app.attrDefaultDomain });
    new CfnOutput(this, "AmplifyShadowUrl", { value: `https://${BRANCH_NAME}.${app.attrDefaultDomain}` });
    new CfnOutput(this, "AmplifyBranchName", { value: BRANCH_NAME });
    new CfnOutput(this, "AmplifySsrComputeRoleArn", { value: computeRole.roleArn });
    new CfnOutput(this, "AmplifyServiceRoleArn", { value: serviceRole.roleArn });
  }
}
