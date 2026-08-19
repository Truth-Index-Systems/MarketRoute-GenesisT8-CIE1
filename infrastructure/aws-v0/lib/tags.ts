import { Tags } from "aws-cdk-lib";
import { IConstruct } from "constructs";
import { AwsV0Config } from "./config";

export function applyMandatoryTags(scope: IConstruct, config: AwsV0Config): void {
  const tags: Record<string, string> = {
    Project: config.project,
    Environment: config.environment,
    Owner: config.owner,
    ManagedBy: "CDK",
    CostCentre: config.costCentre,
  };

  for (const [key, value] of Object.entries(tags)) {
    Tags.of(scope).add(key, value);
  }
}
