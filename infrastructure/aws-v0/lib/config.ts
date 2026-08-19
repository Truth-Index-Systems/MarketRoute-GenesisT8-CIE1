import { App } from "aws-cdk-lib";

export const AWS_V0_BRANCH = "aws-v0";
export const AWS_V0_ACCOUNT = "801132668416";
export const AWS_V0_REGION = "eu-west-2";

export interface AwsV0Config {
  readonly account: string;
  readonly region: string;
  readonly project: string;
  readonly environment: string;
  readonly owner: string;
  readonly costCentre: string;
  readonly githubSubject?: string;
}

function requiredString(value: unknown, name: string): string {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new Error(`Missing AWS V0 context value: ${name}`);
  }
  return value.trim();
}

function optionalGitHubSubject(app: App): string | undefined {
  const raw = app.node.tryGetContext("githubSubject");
  if (raw === undefined || raw === null || String(raw).trim() === "") return undefined;

  const subject = String(raw).trim();
  if (!subject.startsWith("repo:")) {
    throw new Error("githubSubject must be a GitHub OIDC repository subject beginning with repo:");
  }
  if (!subject.endsWith(`:ref:refs/heads/${AWS_V0_BRANCH}`)) {
    throw new Error(`githubSubject must be pinned to refs/heads/${AWS_V0_BRANCH}`);
  }
  if (subject.includes("*") || subject.includes("?")) {
    throw new Error("githubSubject must be exact; wildcards are forbidden for the AWS V0 deployment role");
  }
  return subject;
}

export function loadAwsV0Config(app: App): AwsV0Config {
  const raw = app.node.tryGetContext("marketRouteAwsV0") as Record<string, unknown> | undefined;
  if (!raw) throw new Error("marketRouteAwsV0 context is missing from cdk.json");

  const account = requiredString(raw.account, "account");
  const region = requiredString(raw.region, "region");
  if (account !== AWS_V0_ACCOUNT) {
    throw new Error(`AWS V0 is pinned to account ${AWS_V0_ACCOUNT}; received ${account}`);
  }
  if (region !== AWS_V0_REGION) {
    throw new Error(`AWS V0 is pinned to ${AWS_V0_REGION}; received ${region}`);
  }

  return {
    account,
    region,
    project: requiredString(raw.project, "project"),
    environment: requiredString(raw.environment, "environment"),
    owner: requiredString(raw.owner, "owner"),
    costCentre: requiredString(raw.costCentre, "costCentre"),
    githubSubject: optionalGitHubSubject(app),
  };
}
