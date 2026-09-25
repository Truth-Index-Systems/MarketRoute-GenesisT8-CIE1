import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const template = JSON.parse(fs.readFileSync(path.join(root, "cdk.out/MrAwsV0ResearchStack.template.json"), "utf8"));
const resources = Object.values(template.Resources ?? {});
const statements = resources.filter(r => r.Type === "AWS::IAM::Policy")
  .flatMap(r => r.Properties?.PolicyDocument?.Statement ?? []);
const count = statements.filter(s => s.Sid === "MarketRouteResearchCountTokens");
if (count.length !== 1) throw new Error("Build 11 requires one scoped token-count statement");
const actions = Array.isArray(count[0].Action) ? count[0].Action : [count[0].Action];
const arns = Array.isArray(count[0].Resource) ? count[0].Resource : [count[0].Resource];
if (JSON.stringify(actions) !== JSON.stringify(["bedrock:CountTokens"]) ||
    JSON.stringify(arns) !== JSON.stringify(["arn:aws:bedrock:eu-west-2::foundation-model/anthropic.claude-sonnet-4-5-20250929-v1:0"])) {
  throw new Error("Build 11 token counting must not expand invocation, model or region scope");
}
const mappings = resources.filter(r => r.Type === "AWS::Lambda::EventSourceMapping");
if (mappings.length !== 1 || mappings[0].Properties.Enabled !== false) throw new Error("Build 11 must not activate the queue");
console.log("PASS Build 11 token-count IAM and disabled queue synth");
