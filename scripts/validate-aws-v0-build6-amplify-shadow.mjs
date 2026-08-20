import fs from "node:fs";

function read(path) {
  return fs.readFileSync(path, "utf8");
}

const application = read("infrastructure/aws-v0/lib/application-stack.ts");
const bin = read("infrastructure/aws-v0/bin/aws-v0.ts");
const infraPackage = JSON.parse(read("infrastructure/aws-v0/package.json"));
const packageLock = JSON.parse(read("package-lock.json"));
const shadowHealth = read("app/api/aws-v0/shadow/health/route.ts");
const shadowRuntime = read("application/aws-v0/shadow-runtime.ts");
const dataApiProbe = read("app/api/aws-v0/shadow/data-api/route.ts");
const dataApiProbeApplication = read("application/aws-v0/shadow-data-api-health.ts");
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

for (const token of [
  'isAwsV0ShadowModeEnabled()',
  'getAwsV0ShadowRuntimeStatus()',
  'hosting: "amplify-shadow"',
  'databaseConfigured',
  'cognitoConfigured',
  'productionCutover: false',
  'genesisEnabled: false',
]) {
  if (!shadowHealth.includes(token)) throw new Error(`Build 6 health route missing: ${token}`);
}
if (shadowHealth.includes("process.env")) throw new Error("Build 6 health route must remain environment-blind");
for (const token of [
  'process.env.MARKETROUTE_AWS_SHADOW_MODE === "true"',
  'Boolean(process.env.AWS_REGION)',
  'process.env.MARKETROUTE_AWS_RDS_CLUSTER_ARN',
  'process.env.MARKETROUTE_AWS_RDS_SECRET_ARN',
  'process.env.MARKETROUTE_AWS_RDS_DATABASE',
  'process.env.MARKETROUTE_COGNITO_USER_POOL_ID',
  'process.env.MARKETROUTE_COGNITO_USER_POOL_CLIENT_ID',
]) {
  if (!shadowRuntime.includes(token)) throw new Error(`Build 6 application shadow runtime missing: ${token}`);
}

for (const token of [
  'isAwsV0ShadowModeEnabled()',
  'runAwsV0ShadowDataApiHealthProbe',
  'transport: "rds-data-api"',
  'operation: "system.health"',
  'databaseReachable: true',
  'resultOk: true',
  'productionCutover: false',
  'genesisEnabled: false',
]) {
  if (!dataApiProbe.includes(token)) throw new Error(`Build 6 live Data API route missing: ${token}`);
}
if (dataApiProbe.includes("@/platform/")) throw new Error("Build 6 live Data API route must not bypass the application layer");
if (dataApiProbe.includes("process.env")) throw new Error("Build 6 live Data API route must remain environment-blind");
for (const token of [
  'assertAwsRdsDataSdkBundled',
  'awsDataApiFromEnvironment',
  'executeOperation("system.health", {})',
  'result.rows.length === 1 && result.rows[0]?.ok === 1',
]) {
  if (!dataApiProbeApplication.includes(token)) throw new Error(`Build 6 application health bridge missing: ${token}`);
}
if (dataApiProbeApplication.includes("process.env")) throw new Error("Build 6 Data API application bridge must not own environment configuration");
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
