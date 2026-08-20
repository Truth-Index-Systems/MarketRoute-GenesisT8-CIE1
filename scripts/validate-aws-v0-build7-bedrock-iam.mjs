import fs from "node:fs";

const application = fs.readFileSync("infrastructure/aws-v0/lib/application-stack.ts", "utf8");
const workflow = fs.readFileSync(".github/workflows/aws-v0-infrastructure.yml", "utf8");

const required = [
  'import * as bedrock from "aws-cdk-lib/aws-bedrock"',
  'const BEDROCK_MODEL_ID = "anthropic.claude-sonnet-4-5-20250929-v1:0"',
  'const BEDROCK_EU_INFERENCE_PROFILE_ID = "eu.anthropic.claude-sonnet-4-5-20250929-v1:0"',
  'new bedrock.CfnApplicationInferenceProfile',
  'copyFrom: bedrockEuSystemInferenceProfileArn',
  'actions: ["bedrock:InvokeModel"]',
  '"bedrock:InferenceProfileArn": semanticInferenceProfile.attrInferenceProfileArn',
  'MARKETROUTE_AWS_BEDROCK_INFERENCE_PROFILE_ARN',
  'enableAutoBuild: false',
  'enableBasicAuth: true',
  'enablePullRequestPreview: false',
  'stage: "BETA"',
];
for (const token of required) {
  if (!application.includes(token)) throw new Error(`Build 7.4 IAM source requirement missing: ${token}`);
}

for (const region of ["eu-central-1", "eu-north-1", "eu-south-1", "eu-south-2", "eu-west-1", "eu-west-2", "eu-west-3"]) {
  if (!application.includes(`"${region}"`)) throw new Error(`Build 7.4 EU destination missing: ${region}`);
}

for (const forbidden of [
  "bedrock:*",
  "bedrock:InvokeModelWithResponseStream",
  "bedrock:ConverseStream",
  "bedrock:CreateInferenceProfile",
  "bedrock:DeleteInferenceProfile",
  "bedrock:ListInferenceProfiles",
  "bedrock:CreateModel",
  "bedrock:DeleteModel",
  "bedrock:PutModel",
  "bedrock:GetInferenceProfile",
  "arn:aws:bedrock:*::foundation-model/*",
  "arn:aws:bedrock:*:*:application-inference-profile/*",
  "CfnDomain",
  "enableAutoBuild: true",
  "enablePullRequestPreview: true",
]) {
  if (application.includes(forbidden)) throw new Error(`Build 7.4 IAM source contains forbidden authority: ${forbidden}`);
}

if ((application.match(/actions: \["bedrock:InvokeModel"\]/g) ?? []).length !== 2) {
  throw new Error("Build 7.4 must have exactly two scoped Bedrock InvokeModel statements");
}
if (!workflow.includes("Validate Build 7.4 Bedrock IAM")) throw new Error("Build 7.4 IAM workflow step missing");
if (!workflow.includes("npm run synth && npm run validate:synth")) throw new Error("Build 7.4 local synth gate missing");

console.log("PASS AWS V0 Build 7.4 least-privilege Bedrock IAM source boundary");
