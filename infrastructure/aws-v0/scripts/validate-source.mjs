import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..");
const repo = path.resolve(root, "../..");

function read(relative) {
  return fs.readFileSync(path.join(repo, relative), "utf8");
}

const required = [
  "infrastructure/aws-v0/cdk.json",
  "infrastructure/aws-v0/bin/aws-v0.ts",
  "infrastructure/aws-v0/lib/config.ts",
  "infrastructure/aws-v0/lib/identity-stack.ts",
  "infrastructure/aws-v0/lib/database-stack.ts",
  "database/aws/README.md",
  ".github/workflows/aws-v0-infrastructure.yml",
];

for (const file of required) {
  if (!fs.existsSync(path.join(repo, file))) throw new Error(`Missing ${file}`);
}

const app = read("infrastructure/aws-v0/bin/aws-v0.ts");
for (const stack of [
  "MrAwsV0IdentityStack",
  "MrAwsV0DatabaseStack",
  "MrAwsV0ApplicationStack",
  "MrAwsV0ResearchStack",
  "MrAwsV0ObservabilityStack",
]) {
  if (!app.includes(stack)) throw new Error(`Missing stack declaration: ${stack}`);
}
if (!app.includes("new MrAwsV0DatabaseStack")) throw new Error("Build 2 database stack is not active");

const tags = read("infrastructure/aws-v0/lib/tags.ts");
for (const key of ["Project", "Environment", "Owner", "ManagedBy", "CostCentre"]) {
  if (!tags.includes(key)) throw new Error(`Mandatory tag missing from CDK source: ${key}`);
}

const database = read("infrastructure/aws-v0/lib/database-stack.ts");
for (const requiredSetting of [
  "AuroraPostgresEngineVersion.VER_16_8",
  "ClusterInstance.serverlessV2",
  "serverlessV2MinCapacity: MIN_ACU",
  "serverlessV2MaxCapacity: MAX_ACU",
  "serverlessV2AutoPauseDuration: AUTO_PAUSE",
  "enableDataApi: true",
  "storageEncrypted: true",
  "deletionProtection: false",
  "RemovalPolicy.DESTROY",
  "PRIVATE_ISOLATED",
  "natGateways: 0",
  "publiclyAccessible: false",
  "availabilityZones: DATABASE_AZS",
  'const DATABASE_AZS = ["eu-west-2a", "eu-west-2b"]',
]) {
  if (!database.includes(requiredSetting)) throw new Error(`Build 2 database setting missing: ${requiredSetting}`);
}

// Reject actual forbidden constructs/configuration, not harmless words appearing in
// safe settings such as `publiclyAccessible: false` or descriptive output strings.
for (const forbidden of [
  "DatabaseProxy",
  "DBProxy",
  "new ec2.NatGateway",
  "SubnetType.PUBLIC",
  "SubnetType.PRIVATE_WITH_EGRESS",
  "publiclyAccessible: true",
]) {
  if (database.includes(forbidden)) throw new Error(`Build 2 database boundary contains forbidden construct: ${forbidden}`);
}
if (!database.includes("const MIN_ACU = 0")) throw new Error("Build 2 must allow Aurora auto-pause at 0 ACU");
if (!database.includes("const MAX_ACU = 2")) throw new Error("Build 2 sandbox maximum must remain capped at 2 ACU");
if (!database.includes("Duration.minutes(5)")) throw new Error("Build 2 auto-pause must remain at five minutes");

const workflow = read(".github/workflows/aws-v0-infrastructure.yml");
for (const forbidden of ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "aws-access-key-id", "aws-secret-access-key"]) {
  if (workflow.includes(forbidden)) throw new Error(`Long-lived AWS credential pattern forbidden: ${forbidden}`);
}
if (!workflow.includes("id-token: write")) throw new Error("GitHub workflow does not request OIDC id-token permission");
if (!workflow.includes("AWS_V0_DEPLOY_ROLE_ARN")) throw new Error("GitHub workflow is not role-ARN driven");
if (!workflow.includes("AWS_V0_AUTODEPLOY_ENABLED")) throw new Error("GitHub workflow is missing the explicit deployment safety latch");
if (!workflow.includes("refs/heads/aws-v0")) throw new Error("GitHub deploy workflow is not branch pinned to aws-v0");

const identityWorkflow = read(".github/workflows/aws-v0-repository-identity.yml");
if (!identityWorkflow.includes("id-token: write")) throw new Error("Repository identity workflow cannot request a GitHub OIDC token");
if (!identityWorkflow.includes("core.getIDToken('sts.amazonaws.com')")) throw new Error("Repository identity workflow does not capture the exact AWS OIDC subject");
if (!identityWorkflow.includes(":ref:refs/heads/aws-v0")) throw new Error("Repository identity workflow does not verify the aws-v0 branch subject");

const databaseReadme = read("database/aws/README.md");
if (!databaseReadme.includes("Build 3")) throw new Error("database/aws boundary does not defer canonical 0001 to Build 3");

console.log("PASS AWS-V0 Build 2 source constitution");
