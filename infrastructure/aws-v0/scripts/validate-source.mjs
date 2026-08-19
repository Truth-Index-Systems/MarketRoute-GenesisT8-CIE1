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

const tags = read("infrastructure/aws-v0/lib/tags.ts");
for (const key of ["Project", "Environment", "Owner", "ManagedBy", "CostCentre"]) {
  if (!tags.includes(key)) throw new Error(`Mandatory tag missing from CDK source: ${key}`);
}

const workflow = read(".github/workflows/aws-v0-infrastructure.yml");
for (const forbidden of ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "aws-access-key-id", "aws-secret-access-key"]) {
  if (workflow.includes(forbidden)) throw new Error(`Long-lived AWS credential pattern forbidden: ${forbidden}`);
}
if (!workflow.includes("id-token: write")) throw new Error("GitHub workflow does not request OIDC id-token permission");
if (!workflow.includes("AWS_V0_DEPLOY_ROLE_ARN")) throw new Error("GitHub workflow is not role-ARN driven");
if (!workflow.includes("refs/heads/aws-v0")) throw new Error("GitHub deploy workflow is not branch pinned to aws-v0");

const identityWorkflow = read(".github/workflows/aws-v0-repository-identity.yml");
if (!identityWorkflow.includes("id-token: write")) throw new Error("Repository identity workflow cannot request a GitHub OIDC token");
if (!identityWorkflow.includes("core.getIDToken('sts.amazonaws.com')")) throw new Error("Repository identity workflow does not capture the exact AWS OIDC subject");
if (!identityWorkflow.includes(":ref:refs/heads/aws-v0")) throw new Error("Repository identity workflow does not verify the aws-v0 branch subject");

const databaseReadme = read("database/aws/README.md");
if (!databaseReadme.includes("Build 3")) throw new Error("database/aws boundary does not defer canonical 0001 to Build 3");

console.log("PASS AWS-V0 Build 1 source constitution");
