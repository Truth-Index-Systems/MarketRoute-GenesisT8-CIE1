import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const out = path.join(root, "cdk.out");
const stackNames = [
  "MrAwsV0IdentityStack",
  "MrAwsV0CognitoStack",
  "MrAwsV0DatabaseStack",
  "MrAwsV0ApplicationStack",
  "MrAwsV0ResearchStack",
  "MrAwsV0ObservabilityStack",
];

const SYNTH_METADATA_TYPES = new Set(["AWS::CDK::Metadata"]);
const templates = new Map();

for (const name of stackNames) {
  const file = path.join(out, `${name}.template.json`);
  if (!fs.existsSync(file)) throw new Error(`Synth output missing: ${name}`);
  const template = JSON.parse(fs.readFileSync(file, "utf8"));
  templates.set(name, template);
  const resources = Object.values(template.Resources ?? {});
  const productResources = resources.filter((resource) => !SYNTH_METADATA_TYPES.has(resource.Type));

  if (["MrAwsV0ResearchStack", "MrAwsV0ObservabilityStack"].includes(name) && productResources.length !== 0) {
    throw new Error(`${name} created runtime resources before its numbered build`);
  }

  if (name === "MrAwsV0IdentityStack") {
    const allowed = new Set(["AWS::IAM::OIDCProvider", "AWS::IAM::Role", "AWS::IAM::Policy"]);
    for (const resource of productResources) {
      if (!allowed.has(resource.Type)) throw new Error(`Identity stack contains forbidden resource type: ${resource.Type}`);
    }
  }

  if (name === "MrAwsV0CognitoStack") {
    const allowed = new Set(["AWS::Cognito::UserPool", "AWS::Cognito::UserPoolClient"]);
    for (const resource of productResources) {
      if (!allowed.has(resource.Type)) throw new Error(`Build 5 Cognito stack contains forbidden resource type: ${resource.Type}`);
    }
  }

  if (name === "MrAwsV0DatabaseStack") {
    const allowed = new Set([
      "AWS::EC2::VPC",
      "AWS::EC2::Subnet",
      "AWS::EC2::RouteTable",
      "AWS::EC2::SubnetRouteTableAssociation",
      "AWS::EC2::SecurityGroup",
      "AWS::SecretsManager::Secret",
      "AWS::SecretsManager::SecretTargetAttachment",
      "AWS::RDS::DBSubnetGroup",
      "AWS::RDS::DBCluster",
      "AWS::RDS::DBInstance",
    ]);
    for (const resource of productResources) {
      if (!allowed.has(resource.Type)) throw new Error(`Build 2 database stack contains forbidden resource type: ${resource.Type}`);
    }
  }

  if (name === "MrAwsV0ApplicationStack") {
    const allowed = new Set(["AWS::IAM::Role", "AWS::IAM::Policy", "AWS::Amplify::App", "AWS::Amplify::Branch"]);
    for (const resource of productResources) {
      if (!allowed.has(resource.Type)) throw new Error(`Build 6 application stack contains forbidden resource type: ${resource.Type}`);
    }
  }
}

const cognitoTemplate = templates.get("MrAwsV0CognitoStack");
const cognitoResources = Object.values(cognitoTemplate.Resources ?? {}).filter(resource => !SYNTH_METADATA_TYPES.has(resource.Type));
const cognitoOf = (type) => cognitoResources.filter(resource => resource.Type === type);
if (cognitoOf("AWS::Cognito::UserPool").length !== 1) throw new Error("Build 5 must synthesize exactly one Cognito user pool");
if (cognitoOf("AWS::Cognito::UserPoolClient").length !== 1) throw new Error("Build 5 must synthesize exactly one Cognito user pool client");
if (cognitoOf("AWS::Cognito::UserPoolDomain").length !== 0) throw new Error("Build 5 hosted Cognito domain is forbidden");
const userPool = cognitoOf("AWS::Cognito::UserPool")[0].Properties ?? {};
if (JSON.stringify(userPool.UsernameAttributes) !== JSON.stringify(["email"])) throw new Error("Build 5 Cognito sign-in must be email-only");
if (JSON.stringify(userPool.AutoVerifiedAttributes) !== JSON.stringify(["email"])) throw new Error("Build 5 Cognito email verification is not enabled");
if (userPool.MfaConfiguration !== "OFF") throw new Error("Build 5 Cognito MFA configuration drifted from the frozen foundation");
const userPoolClient = cognitoOf("AWS::Cognito::UserPoolClient")[0].Properties ?? {};
if (userPoolClient.GenerateSecret !== false) throw new Error("Build 5 Cognito web client must not have a client secret");
if (userPoolClient.PreventUserExistenceErrors !== "ENABLED") throw new Error("Build 5 user-existence error suppression is not enabled");
if (userPoolClient.EnableTokenRevocation !== true) throw new Error("Build 5 token revocation is not enabled");
for (const flow of ["ALLOW_USER_PASSWORD_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]) {
  if (!(userPoolClient.ExplicitAuthFlows ?? []).includes(flow)) throw new Error(`Build 5 Cognito auth flow missing: ${flow}`);
}

const databaseTemplate = templates.get("MrAwsV0DatabaseStack");
const databaseResources = Object.values(databaseTemplate.Resources ?? {}).filter(resource => !SYNTH_METADATA_TYPES.has(resource.Type));
function resourcesOf(type) { return databaseResources.filter(resource => resource.Type === type); }
function exactlyOne(type) { const matches = resourcesOf(type); if (matches.length !== 1) throw new Error(`Build 2 expected exactly one ${type}, found ${matches.length}`); return matches[0]; }
exactlyOne("AWS::EC2::VPC");
exactlyOne("AWS::EC2::SecurityGroup");
exactlyOne("AWS::SecretsManager::Secret");
exactlyOne("AWS::RDS::DBSubnetGroup");
const cluster = exactlyOne("AWS::RDS::DBCluster");
const instance = exactlyOne("AWS::RDS::DBInstance");
if (resourcesOf("AWS::EC2::Subnet").length !== 2) throw new Error("Build 2 must synthesize exactly two isolated database subnets");
if (resourcesOf("AWS::EC2::RouteTable").length !== 2) throw new Error("Build 2 must synthesize exactly two isolated route tables");
const cp = cluster.Properties ?? {};
if (cp.Engine !== "aurora-postgresql") throw new Error(`Unexpected Aurora engine: ${cp.Engine}`);
if (cp.EngineVersion !== "16.8") throw new Error(`Unexpected Aurora PostgreSQL version: ${cp.EngineVersion}`);
if (cp.DatabaseName !== "marketroute") throw new Error(`Unexpected database name: ${cp.DatabaseName}`);
if (cp.DBClusterIdentifier !== "marketroute-aws-v0") throw new Error(`Unexpected cluster identifier: ${cp.DBClusterIdentifier}`);
if (cp.EnableHttpEndpoint !== true) throw new Error("Build 2 Data API is not enabled");
if (cp.StorageEncrypted !== true) throw new Error("Build 2 Aurora storage encryption is not enabled");
if (cp.DeletionProtection !== false) throw new Error("Build 2 sandbox deletion protection must be disabled");
const scaling = cp.ServerlessV2ScalingConfiguration ?? {};
if (scaling.MinCapacity !== 0) throw new Error(`Build 2 minimum ACU must be 0, got ${scaling.MinCapacity}`);
if (scaling.MaxCapacity !== 2) throw new Error(`Build 2 maximum ACU must be 2, got ${scaling.MaxCapacity}`);
if (scaling.SecondsUntilAutoPause !== 300) throw new Error(`Build 2 auto-pause must be 300 seconds, got ${scaling.SecondsUntilAutoPause}`);
const ip = instance.Properties ?? {};
if (ip.DBInstanceClass !== "db.serverless") throw new Error(`Build 2 writer must use db.serverless, got ${ip.DBInstanceClass}`);
if (ip.PubliclyAccessible !== false) throw new Error("Build 2 writer must not be publicly accessible");
for (const forbiddenType of ["AWS::EC2::NatGateway", "AWS::EC2::InternetGateway", "AWS::EC2::EIP", "AWS::RDS::DBProxy", "AWS::Lambda::Function", "AWS::SQS::Queue", "AWS::Cognito::UserPool"]) {
  if (resourcesOf(forbiddenType).length !== 0) throw new Error(`Build 2 synthesized forbidden resource type: ${forbiddenType}`);
}

const applicationTemplate = templates.get("MrAwsV0ApplicationStack");
const applicationResources = Object.values(applicationTemplate.Resources ?? {}).filter(resource => !SYNTH_METADATA_TYPES.has(resource.Type));
const applicationOf = (type) => applicationResources.filter(resource => resource.Type === type);
if (applicationOf("AWS::Amplify::App").length !== 1) throw new Error("Build 6 must synthesize exactly one Amplify app");
if (applicationOf("AWS::Amplify::Branch").length !== 1) throw new Error("Build 6 must synthesize exactly one Amplify branch");
if (applicationOf("AWS::IAM::Role").length !== 2) throw new Error("Build 6 must synthesize exactly two IAM roles: service and SSR compute");
if (applicationOf("AWS::IAM::Policy").length !== 2) throw new Error("Build 6 must synthesize exactly two least-privilege IAM policies");
for (const forbiddenType of ["AWS::Amplify::Domain", "AWS::Lambda::Function", "AWS::SQS::Queue", "AWS::Cognito::UserPool", "AWS::RDS::DBCluster", "AWS::EC2::VPC"]) {
  if (applicationOf(forbiddenType).length !== 0) throw new Error(`Build 6 synthesized forbidden resource type: ${forbiddenType}`);
}
const amplifyApp = applicationOf("AWS::Amplify::App")[0].Properties ?? {};
if (amplifyApp.Name !== "marketroute-aws-v0-shadow") throw new Error(`Build 6 Amplify app name drifted: ${amplifyApp.Name}`);
if (amplifyApp.Platform !== "WEB_COMPUTE") throw new Error(`Build 6 Amplify platform must be WEB_COMPUTE, got ${amplifyApp.Platform}`);
if (amplifyApp.Repository !== "https://github.com/Truth-Index-Systems/MarketRoute-GenesisT8-CIE1") throw new Error("Build 6 Amplify repository is not exact");
if (amplifyApp.ComputeRoleArn !== undefined) throw new Error("Build 6 compute role must be branch-scoped, not app-scoped");
if (typeof amplifyApp.BuildSpec !== "string" || !amplifyApp.BuildSpec.includes("nvm use 22") || !amplifyApp.BuildSpec.includes("baseDirectory: .next")) {
  throw new Error("Build 6 Amplify build spec must pin Node 22 and .next artifacts");
}
for (const forbidden of ["SUPABASE_", "OPENAI_", "STRIPE_", "CRON_SECRET", "FOUNDER_DASHBOARD_PASSWORD"]) {
  if (JSON.stringify(amplifyApp).includes(forbidden)) throw new Error(`Build 6 Amplify app leaked legacy/runtime secret configuration: ${forbidden}`);
}
const amplifyBranch = applicationOf("AWS::Amplify::Branch")[0].Properties ?? {};
if (amplifyBranch.BranchName !== "aws-v0") throw new Error(`Build 6 branch must be aws-v0, got ${amplifyBranch.BranchName}`);
if (amplifyBranch.Stage !== "BETA") throw new Error(`Build 6 branch stage must be BETA, got ${amplifyBranch.Stage}`);
if (amplifyBranch.EnableAutoBuild !== false) throw new Error("Build 6 Amplify branch auto-build must remain disabled");
if (amplifyBranch.EnableBasicAuth !== true) throw new Error("Build 6 Amplify shadow must be basic-auth protected");
if (amplifyBranch.EnablePullRequestPreview !== false) throw new Error("Build 6 pull-request previews must remain disabled");
if (!amplifyBranch.ComputeRoleArn) throw new Error("Build 6 SSR compute role must be attached at branch scope");
const basicAuth = amplifyBranch.BasicAuthConfig ?? {};
if (basicAuth.EnableBasicAuth !== true || basicAuth.Username !== "marketroute-shadow" || !basicAuth.Password) {
  throw new Error("Build 6 Amplify branch basic-auth configuration is incomplete");
}

const parameters = applicationTemplate.Parameters ?? {};
for (const name of ["AmplifyGitHubAccessToken", "AmplifyShadowBasicAuthPassword", "AuroraSecretArn", "CognitoUserPoolId", "CognitoUserPoolClientId"]) {
  if (!parameters[name]) throw new Error(`Build 6 CloudFormation parameter missing: ${name}`);
}
if (parameters.AmplifyGitHubAccessToken.NoEcho !== true) throw new Error("Build 6 GitHub access token parameter must be NoEcho");
if (parameters.AmplifyShadowBasicAuthPassword.NoEcho !== true) throw new Error("Build 6 basic-auth password parameter must be NoEcho");

const policyJson = JSON.stringify(applicationOf("AWS::IAM::Policy"));
for (const action of ["rds-data:ExecuteStatement", "rds-data:BeginTransaction", "rds-data:CommitTransaction", "rds-data:RollbackTransaction", "secretsmanager:GetSecretValue"]) {
  if (!policyJson.includes(action)) throw new Error(`Build 6 SSR compute policy missing action: ${action}`);
}
for (const forbidden of ["rds-data:BatchExecuteStatement", "secretsmanager:*", "rds-data:*", "AdministratorAccess", "cognito-idp:AdminCreateUser", "bedrock:", "sqs:"]) {
  if (policyJson.includes(forbidden)) throw new Error(`Build 6 application policy contains forbidden authority: ${forbidden}`);
}

console.log("PASS AWS-V0 synthesized infrastructure boundary through Build 6");
