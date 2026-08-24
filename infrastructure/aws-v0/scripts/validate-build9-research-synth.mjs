import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const templatePath = path.join(root, "cdk.out", "MrAwsV0ResearchStack.template.json");
if (!fs.existsSync(templatePath)) throw new Error("Build 9 research synth output missing");

const template = JSON.parse(fs.readFileSync(templatePath, "utf8"));
const resources = Object.values(template.Resources ?? {}).filter((resource) => resource.Type !== "AWS::CDK::Metadata");
const byType = (type) => resources.filter((resource) => resource.Type === type);
const one = (type) => {
  const matches = byType(type);
  if (matches.length !== 1) throw new Error(`Build 9 expected exactly one ${type}, found ${matches.length}`);
  return matches[0];
};

const parameters = template.Parameters ?? {};
for (const name of ["AuroraSecretArn", "BedrockInferenceProfileArn"]) {
  if (!parameters[name]) throw new Error(`Build 9 CloudFormation parameter missing: ${name}`);
}
if (!String(parameters.AuroraSecretArn.AllowedPattern ?? "").includes("marketroute/aws-v0/database/admin-")) {
  throw new Error("Build 9 Aurora secret parameter is not exact-account/region/name bounded");
}
if (!String(parameters.BedrockInferenceProfileArn.AllowedPattern ?? "").includes("application-inference-profile")) {
  throw new Error("Build 9 Bedrock profile parameter is not application-profile bounded");
}

const allowedTypes = new Set([
  "AWS::SQS::Queue",
  "AWS::SQS::QueuePolicy",
  "AWS::Logs::LogGroup",
  "AWS::IAM::Role",
  "AWS::IAM::Policy",
  "AWS::Lambda::Function",
  "AWS::Lambda::EventSourceMapping",
]);
for (const resource of resources) {
  if (!allowedTypes.has(resource.Type)) throw new Error(`Build 9 research stack contains forbidden resource type: ${resource.Type}`);
}

const role = one("AWS::IAM::Role");
if ((role.Properties?.ManagedPolicyArns ?? []).length !== 0) throw new Error("Build 9 worker role must not attach managed policies");
if (!JSON.stringify(role.Properties?.AssumeRolePolicyDocument ?? {}).includes("lambda.amazonaws.com")) {
  throw new Error("Build 9 worker role trust is not Lambda-only");
}

const policy = one("AWS::IAM::Policy");
const statements = policy.Properties?.PolicyDocument?.Statement ?? [];
const list = Array.isArray(statements) ? statements : [statements];
const actions = (statement) => Array.isArray(statement.Action) ? statement.Action : [statement.Action].filter(Boolean);
const findSid = (sid) => list.find((statement) => statement.Sid === sid);

for (const [sid, expectedActions] of [
  ["MarketRouteResearchExecutionDataApi", ["rds-data:ExecuteStatement"]],
  ["MarketRouteResearchExecutionSecretRead", ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]],
  ["MarketRouteResearchBedrockProfileInvocation", ["bedrock:InvokeModel"]],
  ["MarketRouteResearchBedrockModelBoundary", ["bedrock:InvokeModel"]],
]) {
  const statement = findSid(sid);
  if (!statement) throw new Error(`Build 9 IAM statement missing: ${sid}`);
  if (JSON.stringify(actions(statement)) !== JSON.stringify(expectedActions)) throw new Error(`Build 9 IAM action drifted for ${sid}`);
}

const dataApi = findSid("MarketRouteResearchExecutionDataApi");
if (!JSON.stringify(dataApi.Resource).includes("cluster:marketroute-aws-v0")) throw new Error("Build 9 Data API scope is not the exact Aurora cluster");
const secret = findSid("MarketRouteResearchExecutionSecretRead");
if (!JSON.stringify(secret.Resource).includes("AuroraSecretArn")) throw new Error("Build 9 secret read is not parameter-bounded");
const profile = findSid("MarketRouteResearchBedrockProfileInvocation");
if (!JSON.stringify(profile.Resource).includes("BedrockInferenceProfileArn")) throw new Error("Build 9 profile invocation is not parameter-bounded");
const model = findSid("MarketRouteResearchBedrockModelBoundary");
const expectedModels = ["eu-central-1", "eu-north-1", "eu-south-1", "eu-south-2", "eu-west-1", "eu-west-2", "eu-west-3"]
  .map((region) => `arn:aws:bedrock:${region}::foundation-model/anthropic.claude-sonnet-4-5-20250929-v1:0`)
  .sort();
const actualModels = (Array.isArray(model.Resource) ? model.Resource : [model.Resource]).slice().sort();
if (JSON.stringify(actualModels) !== JSON.stringify(expectedModels)) throw new Error("Build 9 Bedrock destination model boundary drifted");
if (!JSON.stringify(model.Condition?.StringEquals?.["aws:InferenceProfileArn"]).includes("BedrockInferenceProfileArn")) {
  throw new Error("Build 9 model invocation is not conditioned on the application profile");
}

const policyJson = JSON.stringify(policy);
for (const required of [
  "logs:CreateLogStream",
  "logs:PutLogEvents",
  "sqs:ReceiveMessage",
  "sqs:ChangeMessageVisibility",
  "sqs:DeleteMessage",
  "rds-data:ExecuteStatement",
  "secretsmanager:GetSecretValue",
  "bedrock:InvokeModel",
]) if (!policyJson.includes(required)) throw new Error(`Build 9 worker IAM missing: ${required}`);
for (const forbidden of [
  "rds-data:BatchExecuteStatement",
  "rds-data:BeginTransaction",
  "rds-data:CommitTransaction",
  "rds-data:RollbackTransaction",
  "rds-data:*",
  "secretsmanager:*",
  "bedrock:InvokeModelWithResponseStream",
  "bedrock:*",
  "sqs:SendMessage",
  "sqs:*",
  "iam:PassRole",
  "aws-marketplace:",
]) if (policyJson.includes(forbidden)) throw new Error(`Build 9 worker IAM contains forbidden authority: ${forbidden}`);

const fn = one("AWS::Lambda::Function");
const env = fn.Properties?.Environment?.Variables ?? {};
if (env.MARKETROUTE_AWS_RESEARCH_EXECUTOR_ENABLED !== "true") throw new Error("Build 9 executor latch is not enabled");
if (env.MARKETROUTE_AWS_RDS_DATABASE !== "marketroute") throw new Error("Build 9 worker database drifted");
if (!JSON.stringify(env.MARKETROUTE_AWS_RDS_CLUSTER_ARN).includes("marketroute-aws-v0")) throw new Error("Build 9 worker cluster environment drifted");
if (!JSON.stringify(env.MARKETROUTE_AWS_RDS_SECRET_ARN).includes("AuroraSecretArn")) throw new Error("Build 9 worker secret environment is not parameter-bounded");
if (!JSON.stringify(env.MARKETROUTE_AWS_BEDROCK_INFERENCE_PROFILE_ARN).includes("BedrockInferenceProfileArn")) throw new Error("Build 9 worker profile environment is not parameter-bounded");
if (fn.Properties?.Runtime !== "nodejs22.x" || fn.Properties?.Timeout !== 240 || fn.Properties?.MemorySize !== 512) {
  throw new Error("Build 9 worker runtime boundary drifted");
}

const mapping = one("AWS::Lambda::EventSourceMapping");
if (mapping.Properties?.Enabled !== false) throw new Error("Build 9 event source mapping activated before Build 10 sync");
if (mapping.Properties?.BatchSize !== 1 || mapping.Properties?.ScalingConfig?.MaximumConcurrency !== 2) {
  throw new Error("Build 9 transport concurrency drifted");
}
if (JSON.stringify(mapping.Properties?.FunctionResponseTypes) !== JSON.stringify(["ReportBatchItemFailures"])) {
  throw new Error("Build 9 partial batch response boundary drifted");
}

for (const forbiddenType of [
  "AWS::DynamoDB::Table",
  "AWS::Lambda::Url",
  "AWS::ApiGateway::RestApi",
  "AWS::ApiGatewayV2::Api",
  "AWS::RDS::DBCluster",
  "AWS::SecretsManager::Secret",
  "AWS::Bedrock::ApplicationInferenceProfile",
]) if (byType(forbiddenType).length !== 0) throw new Error(`Build 9 synthesized forbidden resource type: ${forbiddenType}`);

console.log("PASS AWS V0 Build 9 synthesized bounded research worker boundary");
