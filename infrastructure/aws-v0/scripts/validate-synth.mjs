import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const out = path.join(root, "cdk.out");
const stackNames = [
  "MrAwsV0IdentityStack",
  "MrAwsV0DatabaseStack",
  "MrAwsV0ApplicationStack",
  "MrAwsV0ResearchStack",
  "MrAwsV0ObservabilityStack",
];

for (const name of stackNames) {
  const file = path.join(out, `${name}.template.json`);
  if (!fs.existsSync(file)) throw new Error(`Synth output missing: ${name}`);
  const template = JSON.parse(fs.readFileSync(file, "utf8"));
  const resources = Object.values(template.Resources ?? {});

  if (name !== "MrAwsV0IdentityStack" && resources.length !== 0) {
    throw new Error(`${name} created runtime resources during Build 1`);
  }

  if (name === "MrAwsV0IdentityStack") {
    const allowed = new Set(["AWS::IAM::OIDCProvider", "AWS::IAM::Role", "AWS::IAM::Policy"]);
    for (const resource of resources) {
      if (!allowed.has(resource.Type)) {
        throw new Error(`Build 1 identity stack contains forbidden resource type: ${resource.Type}`);
      }
    }
  }
}

console.log("PASS AWS-V0 Build 1 synthesized-resource boundary");
