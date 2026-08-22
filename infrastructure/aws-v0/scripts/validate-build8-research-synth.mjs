import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const templatePath = path.join(root, "cdk.out", "MrAwsV0ResearchStack.template.json");
if (!fs.existsSync(templatePath)) throw new Error("Build 8 research synth output missing");

const template = JSON.parse(fs.readFileSync(templatePath, "utf8"));
const resources = Object.values(template.Resources ?? {}).filter((resource) => resource.Type !== "AWS::CDK::Metadata");
const byType = (type) => resources.filter((resource) => resource.Type === type);
const one = (type) => {
  const matches = byType(type);
  if (matches.length !== 1) throw new Error(`Build 8 expected exactly one ${type}, found ${matches.length}`);
  return matches[0];
};

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
  if (!allowedTypes.has(resource.Type)) throw new Error(`Build 8 research stack contains forbidden resource type: ${resource.Type}`);
}

if (byType("AWS::SQS::Queue").length !== 2) throw new Error("Build 8 must synthesize exactly source queue plus DLQ");
const queues = byType("AWS::SQS::Queue");
const sourceQueue = queues.find((resource) => resource.Properties?.QueueName === "marketroute-aws-v0-research-work");
const dlq = queues.find((resource) => resource.Properties?.QueueName === "marketroute-aws-v0-research-dlq");
if (!sourceQueue || !dlq) throw new Error("Build 8 queue names drifted");
if (sourceQueue.Properties.VisibilityTimeout !== 1440) throw new Error("Build 8 source visibility timeout must be 1440 seconds");
if (sourceQueue.Properties.MessageRetentionPeriod !== 345600) throw new Error("Build 8 source retention must be four days");
if (sourceQueue.Properties.ReceiveMessageWaitTimeSeconds !== 20) throw new Error("Build 8 source queue must use 20-second long polling");
if (sourceQueue.Properties.SqsManagedSseEnabled !== true || dlq.Properties.SqsManagedSseEnabled !== true) throw new Error("Build 8 queues must use SQS-managed encryption");
if (dlq.Properties.MessageRetentionPeriod !== 1209600) throw new Error("Build 8 DLQ retention must be fourteen days");
const redrive = sourceQueue.Properties.RedrivePolicy ?? {};
if (redrive.maxReceiveCount !== 5) throw new Error("Build 8 redrive maxReceiveCount must remain five");
if (!JSON.stringify(redrive.deadLetterTargetArn ?? {}).includes("ResearchDeadLetterQueue")) throw new Error("Build 8 source queue does not redrive to the dedicated DLQ");

const queuePolicies = byType("AWS::SQS::QueuePolicy");
if (queuePolicies.length !== 2) throw new Error(`Build 8 expected two SSL-enforcement queue policies, found ${queuePolicies.length}`);
for (const policy of queuePolicies) {
  const json = JSON.stringify(policy.Properties?.PolicyDocument ?? {});
  if (!json.includes("aws:SecureTransport") || !json.includes("sqs:*")) throw new Error("Build 8 queue policy does not enforce TLS");
}

const logGroup = one("AWS::Logs::LogGroup");
if (logGroup.Properties?.LogGroupName !== "/aws/lambda/marketroute-aws-v0-research-worker") throw new Error("Build 8 log group name drifted");
if (logGroup.Properties?.RetentionInDays !== 14) throw new Error("Build 8 worker log retention must be fourteen days");

const role = one("AWS::IAM::Role");
const trust = JSON.stringify(role.Properties?.AssumeRolePolicyDocument ?? {});
if (!trust.includes("lambda.amazonaws.com")) throw new Error("Build 8 worker role trust is not Lambda-only");
if ((role.Properties?.ManagedPolicyArns ?? []).length !== 0) throw new Error("Build 8 worker role must not attach managed policies");

const policy = one("AWS::IAM::Policy");
const statements = policy.Properties?.PolicyDocument?.Statement ?? [];
const statementList = Array.isArray(statements) ? statements : [statements];
const actions = statementList.flatMap((statement) => Array.isArray(statement.Action) ? statement.Action : [statement.Action].filter(Boolean));
for (const required of ["logs:CreateLogStream", "logs:PutLogEvents", "sqs:ReceiveMessage", "sqs:ChangeMessageVisibility", "sqs:GetQueueUrl", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]) {
  if (!actions.includes(required)) throw new Error(`Build 8 worker IAM missing action: ${required}`);
}
for (const forbidden of ["sqs:SendMessage", "sqs:*", "bedrock:", "rds-data:", "secretsmanager:", "ssm:", "dynamodb:", "iam:PassRole", "aws-marketplace:"]) {
  if (JSON.stringify(policy).includes(forbidden)) throw new Error(`Build 8 worker IAM contains forbidden authority: ${forbidden}`);
}
for (const statement of statementList) {
  if (statement.Resource === "*" || (Array.isArray(statement.Resource) && statement.Resource.includes("*"))) throw new Error("Build 8 worker IAM resource wildcard is forbidden");
}

const fn = one("AWS::Lambda::Function");
const fp = fn.Properties ?? {};
if (fp.FunctionName !== "marketroute-aws-v0-research-worker") throw new Error("Build 8 worker name drifted");
if (fp.Runtime !== "nodejs22.x") throw new Error(`Build 8 worker runtime drifted: ${fp.Runtime}`);
if (fp.Handler !== "index.handler") throw new Error("Build 8 worker handler drifted");
if (fp.Timeout !== 240) throw new Error("Build 8 worker timeout must remain 240 seconds");
if (fp.MemorySize !== 512) throw new Error("Build 8 worker memory must remain 512 MB");
if (JSON.stringify(fp.Architectures) !== JSON.stringify(["arm64"])) throw new Error("Build 8 worker architecture must remain arm64");
const env = fp.Environment?.Variables ?? {};
if (env.MARKETROUTE_AWS_RESEARCH_TRANSPORT_VERSION !== "1") throw new Error("Build 8 transport version environment missing");
if (env.MARKETROUTE_AWS_RESEARCH_EXECUTOR_ENABLED !== "false") throw new Error("Build 8 executor must remain disabled");

const mapping = one("AWS::Lambda::EventSourceMapping");
const mp = mapping.Properties ?? {};
if (mp.Enabled !== false) throw new Error("Build 8 SQS event source mapping must remain disabled");
if (mp.BatchSize !== 1) throw new Error("Build 8 batch size must remain one research work unit");
if (JSON.stringify(mp.FunctionResponseTypes) !== JSON.stringify(["ReportBatchItemFailures"])) throw new Error("Build 8 partial batch failure reporting is not enabled");
if (mp.ScalingConfig?.MaximumConcurrency !== 2) throw new Error("Build 8 research maximum concurrency must remain two");
if (!JSON.stringify(mp.EventSourceArn ?? {}).includes("ResearchWorkQueue")) throw new Error("Build 8 event source is not the research work queue");

for (const forbiddenType of ["AWS::Lambda::Url", "AWS::ApiGateway::RestApi", "AWS::ApiGatewayV2::Api", "AWS::RDS::DBCluster", "AWS::Bedrock::ApplicationInferenceProfile", "AWS::DynamoDB::Table", "AWS::SecretsManager::Secret"]) {
  if (byType(forbiddenType).length !== 0) throw new Error(`Build 8 synthesized forbidden resource type: ${forbiddenType}`);
}

console.log("PASS AWS V0 Build 8 synthesized research transport boundary");
