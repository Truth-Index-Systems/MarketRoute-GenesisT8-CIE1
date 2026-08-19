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

const SYNTH_METADATA_TYPES = new Set(["AWS::CDK::Metadata"]);
const templates = new Map();

for (const name of stackNames) {
  const file = path.join(out, `${name}.template.json`);
  if (!fs.existsSync(file)) throw new Error(`Synth output missing: ${name}`);
  const template = JSON.parse(fs.readFileSync(file, "utf8"));
  templates.set(name, template);
  const resources = Object.values(template.Resources ?? {});
  const productResources = resources.filter((resource) => !SYNTH_METADATA_TYPES.has(resource.Type));

  if (["MrAwsV0ApplicationStack", "MrAwsV0ResearchStack", "MrAwsV0ObservabilityStack"].includes(name) && productResources.length !== 0) {
    throw new Error(`${name} created runtime resources before its numbered build`);
  }

  if (name === "MrAwsV0IdentityStack") {
    const allowed = new Set(["AWS::IAM::OIDCProvider", "AWS::IAM::Role", "AWS::IAM::Policy"]);
    for (const resource of productResources) {
      if (!allowed.has(resource.Type)) {
        throw new Error(`Identity stack contains forbidden resource type: ${resource.Type}`);
      }
    }
  }

  if (name === "MrAwsV0DatabaseStack") {
    const allowed = new Set([
      "AWS::EC2::VPC",
      "AWS::EC2::Subnet",
      "AWS::EC2::RouteTable",
      "AWS::EC2::SubnetRouteTableAssociation",
      "AWS::EC2::SecurityGroup",
      "AWS::SecretsManager::Secret",
      "AWS::SecretsManager::SecretTargetAttachment",
      "AWS::RDS::DBSubnetGroup",
      "AWS::RDS::DBCluster",
      "AWS::RDS::DBInstance",
    ]);
    for (const resource of productResources) {
      if (!allowed.has(resource.Type)) {
        throw new Error(`Build 2 database stack contains forbidden resource type: ${resource.Type}`);
      }
    }
  }
}

const databaseTemplate = templates.get("MrAwsV0DatabaseStack");
const databaseResources = Object.values(databaseTemplate.Resources ?? {}).filter(
  (resource) => !SYNTH_METADATA_TYPES.has(resource.Type),
);

function resourcesOf(type) {
  return databaseResources.filter((resource) => resource.Type === type);
}
function exactlyOne(type) {
  const matches = resourcesOf(type);
  if (matches.length !== 1) throw new Error(`Build 2 expected exactly one ${type}, found ${matches.length}`);
  return matches[0];
}

exactlyOne("AWS::EC2::VPC");
exactlyOne("AWS::EC2::SecurityGroup");
exactlyOne("AWS::SecretsManager::Secret");
exactlyOne("AWS::RDS::DBSubnetGroup");
const cluster = exactlyOne("AWS::RDS::DBCluster");
const instance = exactlyOne("AWS::RDS::DBInstance");

if (resourcesOf("AWS::EC2::Subnet").length !== 2) throw new Error("Build 2 must synthesize exactly two isolated database subnets");
if (resourcesOf("AWS::EC2::RouteTable").length !== 2) throw new Error("Build 2 must synthesize exactly two isolated route tables");

const cp = cluster.Properties ?? {};
if (cp.Engine !== "aurora-postgresql") throw new Error(`Unexpected Aurora engine: ${cp.Engine}`);
if (cp.EngineVersion !== "16.8") throw new Error(`Unexpected Aurora PostgreSQL version: ${cp.EngineVersion}`);
if (cp.DatabaseName !== "marketroute") throw new Error(`Unexpected database name: ${cp.DatabaseName}`);
if (cp.DBClusterIdentifier !== "marketroute-aws-v0") throw new Error(`Unexpected cluster identifier: ${cp.DBClusterIdentifier}`);
if (cp.EnableHttpEndpoint !== true) throw new Error("Build 2 Data API is not enabled");
if (cp.StorageEncrypted !== true) throw new Error("Build 2 Aurora storage encryption is not enabled");
if (cp.DeletionProtection !== false) throw new Error("Build 2 sandbox deletion protection must be disabled");

const scaling = cp.ServerlessV2ScalingConfiguration ?? {};
if (scaling.MinCapacity !== 0) throw new Error(`Build 2 minimum ACU must be 0, got ${scaling.MinCapacity}`);
if (scaling.MaxCapacity !== 2) throw new Error(`Build 2 maximum ACU must be 2, got ${scaling.MaxCapacity}`);
if (scaling.SecondsUntilAutoPause !== 300) throw new Error(`Build 2 auto-pause must be 300 seconds, got ${scaling.SecondsUntilAutoPause}`);

const ip = instance.Properties ?? {};
if (ip.DBInstanceClass !== "db.serverless") throw new Error(`Build 2 writer must use db.serverless, got ${ip.DBInstanceClass}`);
if (ip.PubliclyAccessible !== false) throw new Error("Build 2 writer must not be publicly accessible");

for (const forbiddenType of [
  "AWS::EC2::NatGateway",
  "AWS::EC2::InternetGateway",
  "AWS::EC2::EIP",
  "AWS::RDS::DBProxy",
  "AWS::Lambda::Function",
  "AWS::SQS::Queue",
  "AWS::Cognito::UserPool",
]) {
  if (resourcesOf(forbiddenType).length !== 0) throw new Error(`Build 2 synthesized forbidden resource type: ${forbiddenType}`);
}

console.log("PASS AWS-V0 Build 2 synthesized Aurora boundary");
