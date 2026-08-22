#!/usr/bin/env node
import { App } from "aws-cdk-lib";
import { MrAwsV0ApplicationStack } from "../lib/application-stack";
import { loadAwsV0Config } from "../lib/config";
import { MrAwsV0CognitoStack } from "../lib/cognito-stack";
import { MrAwsV0DatabaseStack } from "../lib/database-stack";
import { FoundationStack } from "../lib/foundation-stack";
import { MrAwsV0IdentityStack } from "../lib/identity-stack";
import { MrAwsV0ResearchStack } from "../lib/research-stack";
import { applyMandatoryTags } from "../lib/tags";

const app = new App();
const config = loadAwsV0Config(app);
const env = { account: config.account, region: config.region };

const identity = new MrAwsV0IdentityStack(app, "MrAwsV0IdentityStack", {
  env,
  githubSubject: config.githubSubject,
  description: "MarketRoute AWS V0 identity and CI federation boundary",
});

const cognito = new MrAwsV0CognitoStack(app, "MrAwsV0CognitoStack", {
  env,
  description: "MarketRoute AWS V0 customer identity boundary (Build 5)",
});

const database = new MrAwsV0DatabaseStack(app, "MrAwsV0DatabaseStack", {
  env,
  description: "MarketRoute AWS V0 fresh Aurora PostgreSQL foundation (Build 2)",
});

const application = new MrAwsV0ApplicationStack(app, "MrAwsV0ApplicationStack", {
  env,
  description: "MarketRoute AWS V0 private Amplify Hosting SSR shadow (Build 6)",
});

const research = new MrAwsV0ResearchStack(app, "MrAwsV0ResearchStack", {
  env,
  description: "MarketRoute AWS V0 research transport and worker substrate (Build 8)",
});

const observability = new FoundationStack(app, "MrAwsV0ObservabilityStack", {
  env,
  purpose: "Reserved for AWS-V0 Build 14 operational observability",
  description: "MarketRoute AWS V0 observability boundary (Build 1 placeholder only)",
});

for (const stack of [identity, cognito, database, application, research, observability]) {
  applyMandatoryTags(stack, config);
}

app.synth();
