#!/usr/bin/env node
import { App } from "aws-cdk-lib";
import { loadAwsV0Config } from "../lib/config";
import { FoundationStack } from "../lib/foundation-stack";
import { MrAwsV0IdentityStack } from "../lib/identity-stack";
import { applyMandatoryTags } from "../lib/tags";

const app = new App();
const config = loadAwsV0Config(app);
const env = { account: config.account, region: config.region };

const identity = new MrAwsV0IdentityStack(app, "MrAwsV0IdentityStack", {
  env,
  githubSubject: config.githubSubject,
  description: "MarketRoute AWS V0 identity and CI federation boundary",
});

const database = new FoundationStack(app, "MrAwsV0DatabaseStack", {
  env,
  purpose: "Reserved for AWS-V0 Build 2 Aurora foundation",
  description: "MarketRoute AWS V0 database boundary (Build 1 placeholder only)",
});

const application = new FoundationStack(app, "MrAwsV0ApplicationStack", {
  env,
  purpose: "Reserved for AWS-V0 Build 6 application hosting",
  description: "MarketRoute AWS V0 application boundary (Build 1 placeholder only)",
});

const research = new FoundationStack(app, "MrAwsV0ResearchStack", {
  env,
  purpose: "Reserved for AWS-V0 Builds 8-11 research transport and execution",
  description: "MarketRoute AWS V0 research boundary (Build 1 placeholder only)",
});

const observability = new FoundationStack(app, "MrAwsV0ObservabilityStack", {
  env,
  purpose: "Reserved for AWS-V0 Build 14 operational observability",
  description: "MarketRoute AWS V0 observability boundary (Build 1 placeholder only)",
});

for (const stack of [identity, database, application, research, observability]) {
  applyMandatoryTags(stack, config);
}

app.synth();
