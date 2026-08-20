import fs from "node:fs";

function read(path) {
  return fs.readFileSync(path, "utf8");
}

const application = read("infrastructure/aws-v0/lib/application-stack.ts");
const bin = read("infrastructure/aws-v0/bin/aws-v0.ts");
const infraPackage = JSON.parse(read("infrastructure/aws-v0/package.json"));
const packageLock = JSON.parse(read("package-lock.json"));
const shadowHealth = read("app/api/aws-v0/shadow/health/route.ts");
const dataApiProbe = read("app/api/aws-v0/shadow/data-api/route.ts");
const dataApiBundleAnchor = read("platform/database/aws-data-api-bundle-anchor.ts");
const dataApiAdapter = read("platform/database/aws-data-api.ts");
const workflow = read(".github/workflows/aws-v0-infrastructure.yml");

const rootPackage = packageLock.packages?.[""];
if (rootPackage?.dependencies?.next !== "15.5.23") throw new Error(`Build 6 requires frozen Next.js 15.5.23, got ${rootPackage?.dependencies?.next}`);
if (rootPackage?.engines?.node !== "22.x") throw new Error(`Build 6 requires Node 22.x, got ${rootPackage?.engines?.node}`);
if (rootPackage?.dependencies?.["@aws-sdk/client-rds-data"] !== "3.1114.0") throw new Error(`Build 6 requires exact RDS Data SDK 3.1114.0, got ${rootPackage?.dependencies?.["@aws-sdk/client-rds-data"]}`);
if (packageLock.packages?.["node_modules/@aws-sdk/client-rds-data"]?.version !== "3.1114.0") throw new Error("Build 6 RDS Data SDK lockfile resolution drifted");
if (!bin.includes('new MrAwsV0ApplicationStack(app, "MrAwsV0ApplicationStack"')) throw new Error("Build 6 application stack is not wired into the AWS V0 CDK app");
if (infraPackage.scripts?.["deploy:application"] !== "npm run build && cdk deploy MrAwsV0ApplicationStack --require-approval never") {
  throw new Error("Build 6 controlled application deployment script is missing");
}

for (const token of [
  'name: "marketroute-aws-v0-shadow"',
  'platform: "WEB_COMPUTE"',
  'branchName: BRANCH_NAME',
  'stage: "BETA"',
  'enableAutoBuild: false',
  'enableBasicAuth: true',
  'enablePullRequestPreview: false',
  'computeRoleArn: computeRole.roleArn',
  'new CfnParameter(this, "AmplifyGitHubAccessToken"',
  'new CfnParameter(this, "AmplifyShadowBasicAuthPassword"',
  'nvm use 22',
  'npm ci --no-audit --no-fund',
  'baseDirectory: .next',
  'MARKETROUTE_AWS_SHADOW_MODE',
  'MARKETROUTE_AWS_RDS_CLUSTER_ARN',
  'MARKETROUTE_AWS_RDS_SECRET_ARN',
  'MARKETROUTE_AWS_RDS_DATABASE',
  'MARKETROUTE_COGNITO_USER_POOL_ID',
  'MARKETROUTE_COGNITO_USER_POOL_CLIENT_ID',
  'rds-data:ExecuteStatement',
  'secretsmanager:GetSecretValue',
]) {
  if (!application.includes(token)) throw new Error(`Build 6 application foundation missing: ${token}`);
}

for (const forbidden of [
  "CfnDomain",
  "enableAutoBuild: true",
  "enablePullRequestPreview: true",
  "SUPABASE_",
  "OPENAI_",
  "STRIPE_",
  "CRON_SECRET",
  "AWS_ACCESS_KEY_ID",
  "AWS_SECRET_ACCESS_KEY",
  "rds-data:BatchExecuteStatement",
]) {
  if (application.includes(forbidden)) throw new Error(`Build 6 application foundation contains forbidden token: ${forbidden}`);
}

if (!shadowHealth.includes('process.env.MARKETROUTE_AWS_SHADOW_MODE !== "true"')) throw new Error("Build 6 health route is not fail-closed outside AWS shadow mode");
if (!shadowHealth.includes('hosting: "amplify-shadow"')) throw new Error("Build 6 health route does not identify the Amplify shadow");
if (!shadowHealth.includes("productionCutover: false")) throw new Error("Build 6 health route does not preserve the no-cutover invariant");
if (!shadowHealth.includes("genesisEnabled: false")) throw new Error("Build 6 health route does not preserve Genesis-disabled state");

for (const token of [
  'process.env.MARKETROUTE_AWS_SHADOW_MODE !== "true"',
  'awsDataApiFromEnvironment',
  'executeOperation("system.health", {})',
  'transport: "rds-data-api"',
  'operation: "system.health"',
  'databaseReachable: true',
  'resultOk: true',
  'productionCutover: false',
  'genesisEnabled: false',
]) {
  if (!dataApiProbe.includes(token)) throw new Error(`Build 6 live Data API probe missing: ${token}`);
}
if (!dataApiBundleAnchor.includes('RDSDataClient') || !dataApiBundleAnchor.includes('@aws-sdk/client-rds-data')) {
  throw new Error("Build 6 live Data API SDK bundle anchor is missing");
}
if (!dataApiAdapter.includes('AWS_RDS_DATA_PACKAGE = "@aws-sdk/client-rds-data"')) throw new Error("Build 4 Data API adapter package boundary drifted");
if (!dataApiAdapter.includes('executeOperation<TName extends AwsDataApiOperationName>')) throw new Error("Build 4 named-operation boundary drifted");

if (!workflow.includes("Validate Build 6 Amplify shadow hosting")) throw new Error("Build 6 workflow validation step missing");
if (!workflow.includes("node scripts/validate-aws-v0-build6-amplify-shadow.mjs")) throw new Error("Build 6 source validator is not executed in CI");
if (!workflow.includes("node tests/adversarial/aws-v0-build6-amplify-shadow.mjs")) throw new Error("Build 6 adversarial validator is not executed in CI");
if (!workflow.includes("AWS_V0_AUTODEPLOY_ENABLED == 'true'")) throw new Error("AWS V0 autodeploy safety latch drifted");

console.log("PASS AWS V0 Build 6 Amplify shadow hosting + live Data API probe validation");
