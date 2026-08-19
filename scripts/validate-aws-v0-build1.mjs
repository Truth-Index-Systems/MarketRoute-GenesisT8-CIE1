import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const required = [
  "infrastructure/aws-v0/package.json",
  "infrastructure/aws-v0/cdk.json",
  "infrastructure/aws-v0/bin/aws-v0.ts",
  "infrastructure/aws-v0/lib/identity-stack.ts",
  "infrastructure/aws-v0/lib/foundation-stack.ts",
  "infrastructure/aws-v0/lib/config.ts",
  "infrastructure/aws-v0/lib/tags.ts",
  "database/aws/README.md",
  ".github/workflows/aws-v0-infrastructure.yml",
  ".github/workflows/aws-v0-repository-identity.yml",
];
for (const relative of required) {
  if (!fs.existsSync(path.join(root, relative))) throw new Error(`Missing ${relative}`);
}

const workflow = fs.readFileSync(path.join(root, ".github/workflows/aws-v0-infrastructure.yml"), "utf8");
if (/AWS_(ACCESS_KEY_ID|SECRET_ACCESS_KEY)/.test(workflow)) {
  throw new Error("AWS V0 workflow contains a permanent-key credential name");
}
if (!workflow.includes("id-token: write")) throw new Error("OIDC permission missing");
if (!workflow.includes("allowed-account-ids: \"801132668416\"")) throw new Error("AWS account guard missing");

const identity = fs.readFileSync(path.join(root, "infrastructure/aws-v0/lib/identity-stack.ts"), "utf8");
if (identity.includes("AdministratorAccess")) throw new Error("GitHub deployment role must not be AdministratorAccess");
if (!identity.includes("sts:AssumeRole")) throw new Error("GitHub deployment role does not delegate through CDK bootstrap roles");

const db = fs.readdirSync(path.join(root, "database/aws"));
if (db.some((name) => name.endsWith(".sql"))) throw new Error("Build 1 must not create AWS database SQL");

console.log("PASS MarketRoute AWS-V0 Build 1 repository boundary");
