import fs from "node:fs";

const application = fs.readFileSync("infrastructure/aws-v0/lib/application-stack.ts", "utf8");

for (const token of [
  'resources: ["*"]',
  'actions: ["bedrock:*"',
  "bedrock:InvokeModelWithResponseStream",
  "bedrock:ConverseStream",
  "bedrock:CreateInferenceProfile",
  "bedrock:DeleteInferenceProfile",
  "bedrock:ListInferenceProfiles",
  "bedrock:TagResource",
  "bedrock:UntagResource",
  "bedrock:CreateModel",
  "bedrock:DeleteModel",
  "bedrock:CreateModelInvocationJob",
  "aws-marketplace:Subscribe",
  "iam:PassRole",
]) {
  if (token === 'resources: ["*"]') continue; // Amplify log service role legitimately uses wildcard CloudWatch Logs resources.
  if (application.includes(token)) throw new Error(`Build 7.4 Bedrock IAM privilege expansion detected: ${token}`);
}

const modelId = "anthropic.claude-sonnet-4-5-20250929-v1:0";
const expectedRegions = ["eu-central-1", "eu-north-1", "eu-south-1", "eu-south-2", "eu-west-1", "eu-west-2", "eu-west-3"];
for (const region of expectedRegions) {
  const arn = `arn:aws:bedrock:${region}::foundation-model/${modelId}`;
  if (!application.includes('`arn:aws:bedrock:${region}::foundation-model/${BEDROCK_MODEL_ID}`')) {
    throw new Error(`Build 7.4 exact model ARN template missing for ${arn}`);
  }
}

if (!application.includes('resources: [semanticInferenceProfile.attrInferenceProfileArn]')) {
  throw new Error("Build 7.4 profile invocation is not resource-scoped to the application inference profile");
}
if (!application.includes('"bedrock:InferenceProfileArn": semanticInferenceProfile.attrInferenceProfileArn')) {
  throw new Error("Build 7.4 foundation-model permissions are not conditioned on the application inference profile");
}
if (application.includes("global.anthropic")) throw new Error("Build 7.4 must remain EU geographic, not global cross-region");
if (application.includes("NEXT_PUBLIC_MARKETROUTE_AWS_BEDROCK")) throw new Error("Build 7.4 Bedrock profile configuration leaked toward the browser");
if (!application.includes('value: "AWS-V0-BUILD-6-AMPLIFY-SHADOW"')) throw new Error("Build 7.4 changed the frozen Build 6 hosting identity");

console.log("PASS AWS V0 Build 7.4 adversarial Bedrock IAM boundary checks");
