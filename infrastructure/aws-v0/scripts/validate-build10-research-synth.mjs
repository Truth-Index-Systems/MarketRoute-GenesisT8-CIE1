import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const template = JSON.parse(fs.readFileSync(path.join(root, "cdk.out", "MrAwsV0ResearchStack.template.json"), "utf8"));
const resources = Object.values(template.Resources ?? {}).filter((resource) => resource.Type !== "AWS::CDK::Metadata");
const mappings = resources.filter((resource) => resource.Type === "AWS::Lambda::EventSourceMapping");
if (mappings.length !== 1 || mappings[0].Properties?.Enabled !== false) throw new Error("Build 10 event source mapping must remain disabled");
const outputs = template.Outputs ?? {};
if (outputs.BuildStatus?.Value !== "AWS-V0-BUILD-10-RESEARCH-ORCHESTRATION-SPLIT") throw new Error("Build 10 synthesized status missing");
if (outputs.ResearchEventSourceStatus?.Value !== "DISABLED_PENDING_PLANNER_AND_QUOTA_PROOF") throw new Error("Build 10 activation blocker missing");
for (const forbidden of ["AWS::Lambda::Url", "AWS::ApiGateway::RestApi", "AWS::ApiGatewayV2::Api", "AWS::EventBridge::Rule", "AWS::Events::Rule"]) {
  if (resources.some((resource) => resource.Type === forbidden)) throw new Error(`Build 10 synthesized an unapproved trigger: ${forbidden}`);
}
console.log("PASS AWS V0 Build 10 synthesized fail-closed orchestration boundary");
