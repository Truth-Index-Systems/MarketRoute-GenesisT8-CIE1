import fs from "node:fs";

const application = fs.readFileSync("infrastructure/aws-v0/lib/application-stack.ts", "utf8");
const health = fs.readFileSync("app/api/aws-v0/shadow/health/route.ts", "utf8");
const dataApiProbe = fs.readFileSync("app/api/aws-v0/shadow/data-api/route.ts", "utf8");
const dataApiProbeApplication = fs.readFileSync("application/aws-v0/shadow-data-api-health.ts", "utf8");
const dataApiBundleAnchor = fs.readFileSync("platform/database/aws-data-api-bundle-anchor.ts", "utf8");
const dataApiAdapter = fs.readFileSync("platform/database/aws-data-api.ts", "utf8");
const operations = fs.readFileSync("platform/database/aws-data-api-operations.ts", "utf8");
const packageLock = JSON.parse(fs.readFileSync("package-lock.json", "utf8"));
const workflow = fs.readFileSync(".github/workflows/aws-v0-infrastructure.yml", "utf8");

function forbid(source, token, label) {
  if (source.includes(token)) throw new Error(`${label}: forbidden token present: ${token}`);
}

for (const token of [
  "SUPABASE_",
  "OPENAI_",
  "STRIPE_",
  "FOUNDER_DASHBOARD_PASSWORD",
  "CRON_SECRET",
  "AWS_ACCESS_KEY_ID",
  "AWS_SECRET_ACCESS_KEY",
  "clientSecret",
  "generateSecret: true",
]) forbid(application, token, "Build 6 shadow hosting");

for (const token of [
  "enableAutoBuild: true",
  "enablePullRequestPreview: true",
  "stage: \"PRODUCTION\"",
  "CfnDomain",
  "customDomain",
  "rds-data:BatchExecuteStatement",
  "rds-data:*",
  "secretsmanager:*",
  "bedrock:",
  "sqs:",
  "lambda:",
  "cognito-idp:Admin",
]) forbid(application, token, "Build 6 authority boundary");

if (!application.includes('enableAutoBuild: false')) throw new Error("Build 6 must not auto-build the Amplify branch");
if (!application.includes('enableBasicAuth: true')) throw new Error("Build 6 shadow branch must be basic-auth protected");
if (!application.includes('enablePullRequestPreview: false')) throw new Error("Build 6 pull request previews must remain disabled");
if (!application.includes('stage: "BETA"')) throw new Error("Build 6 branch must remain non-production BETA");
if (!application.includes('computeRoleArn: computeRole.roleArn')) throw new Error("Build 6 SSR compute role must be branch-scoped");
if (application.match(/computeRoleArn:/g)?.length !== 1) throw new Error("Build 6 compute role must appear exactly once at branch scope");
if (!application.includes('noEcho: true')) throw new Error("Build 6 secret bootstrap parameters must be NoEcho");
if (!application.includes('MARKETROUTE_AWS_SHADOW_MODE')) throw new Error("Build 6 shadow-mode latch missing");

for (const token of [
  "MARKETROUTE_AWS_RDS_CLUSTER_ARN: process.env",
  "MARKETROUTE_AWS_RDS_SECRET_ARN: process.env",
  "MARKETROUTE_COGNITO_USER_POOL_ID: process.env",
  "MARKETROUTE_COGNITO_USER_POOL_CLIENT_ID: process.env",
  "SUPABASE_",
  "OPENAI_",
  "STRIPE_",
]) forbid(health, token, "Build 6 health response");

if (!health.includes('return NextResponse.json({ error: "not_found" }, { status: 404 })')) {
  throw new Error("Build 6 shadow health endpoint must disappear outside AWS shadow mode");
}
if (!health.includes("databaseConfigured")) throw new Error("Build 6 health endpoint must prove database configuration presence without exposing values");
if (!health.includes("cognitoConfigured")) throw new Error("Build 6 health endpoint must prove Cognito configuration presence without exposing values");
if (!health.includes("productionCutover: false")) throw new Error("Build 6 health endpoint must deny production cutover");

for (const token of [
  "SELECT ",
  "INSERT ",
  "UPDATE ",
  "DELETE ",
  "sql:",
  "ExecuteStatementCommand",
  "RDSDataClient",
  "MARKETROUTE_AWS_RDS_CLUSTER_ARN",
  "MARKETROUTE_AWS_RDS_SECRET_ARN",
  "MARKETROUTE_AWS_RDS_DATABASE",
  "AWS_ACCESS_KEY_ID",
  "AWS_SECRET_ACCESS_KEY",
  "providerCode",
  "secretArn",
  "resourceArn",
  "@/platform/",
  "awsDataApiFromEnvironment",
  "process.env",
]) forbid(dataApiProbe, token, "Build 6 live Data API route");

if (!dataApiProbe.includes('isAwsV0ShadowModeEnabled')) throw new Error("Build 6 live Data API route must use the application-owned shadow-mode latch");
if (!dataApiProbe.includes('runAwsV0ShadowDataApiHealthProbe')) throw new Error("Build 6 live Data API route must use the application-layer health bridge");
if (!dataApiProbe.includes('return NextResponse.json({ error: "not_found" }, { status: 404 })')) throw new Error("Build 6 live Data API probe must disappear outside AWS shadow mode");
if (!dataApiProbe.includes('productionCutover: false')) throw new Error("Build 6 live Data API probe must deny production cutover");
if (!dataApiProbe.includes('genesisEnabled: false')) throw new Error("Build 6 live Data API probe must keep Genesis disabled");

for (const token of [
  "SELECT ",
  "INSERT ",
  "UPDATE ",
  "DELETE ",
  "sql:",
  "ExecuteStatementCommand",
  "RDSDataClient",
  "AWS_ACCESS_KEY_ID",
  "AWS_SECRET_ACCESS_KEY",
]) forbid(dataApiProbeApplication, token, "Build 6 application Data API health bridge");
if (!dataApiProbeApplication.includes('process.env.MARKETROUTE_AWS_SHADOW_MODE === "true"')) throw new Error("Build 6 application bridge must own the exact fail-closed shadow-mode latch");
if (!dataApiProbeApplication.includes('assertAwsRdsDataSdkBundled')) throw new Error("Build 6 application bridge must retain the frozen RDS Data SDK bundle anchor");
if (!dataApiProbeApplication.includes('awsDataApiFromEnvironment')) throw new Error("Build 6 application bridge must use the frozen Data API adapter");
if (!dataApiProbeApplication.includes('executeOperation("system.health", {})')) throw new Error("Build 6 application bridge must use the frozen named system.health operation");
if (!dataApiProbeApplication.includes('result.rows.length === 1 && result.rows[0]?.ok === 1')) throw new Error("Build 6 application bridge must preserve the frozen health result contract");

if (!dataApiBundleAnchor.includes('@aws-sdk/client-rds-data') || !dataApiBundleAnchor.includes('RDSDataClient')) throw new Error("Build 6 must statically anchor the RDS Data SDK into the SSR bundle");
if (packageLock.packages?.[""]?.dependencies?.["@aws-sdk/client-rds-data"] !== "3.1114.0") throw new Error("Build 6 root RDS Data SDK dependency must remain exact-pinned");
if (packageLock.packages?.["node_modules/@aws-sdk/client-rds-data"]?.version !== "3.1114.0") throw new Error("Build 6 RDS Data SDK lock resolution must remain exact-pinned");
if (!dataApiAdapter.includes('executeOperation<TName extends AwsDataApiOperationName>')) throw new Error("Build 4 named-operation API must remain intact");
if (!operations.includes('"system.health": Object.freeze({')) throw new Error("Build 6 live probe must reuse the frozen system.health operation");
if (!operations.includes('sql: "SELECT 1::bigint AS ok"')) throw new Error("Frozen system.health SQL drifted");

for (const token of ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "aws-access-key-id", "aws-secret-access-key"]) {
  forbid(workflow, token, "Build 6 CI");
}
if (!workflow.includes("AWS_V0_AUTODEPLOY_ENABLED == 'true'")) throw new Error("Build 6 CI must preserve the explicit AWS deployment latch");
if (workflow.includes("deploy:application")) throw new Error("Build 6 CI must not automatically deploy the Amplify application stack");

console.log("PASS AWS V0 Build 6 adversarial Amplify shadow + live Data API boundary checks");
