import { CfnOutput, Stack, StackProps } from "aws-cdk-lib";
import { Construct } from "constructs";

export interface FoundationStackProps extends StackProps {
  readonly purpose: string;
}

/**
 * Build 1 deliberately creates no product/runtime resources in these stacks.
 * The stacks establish stable deployment boundaries only. Later numbered builds
 * populate them without changing the MarketRoute domain/authority architecture.
 */
export class FoundationStack extends Stack {
  public constructor(scope: Construct, id: string, props: FoundationStackProps) {
    super(scope, id, props);

    new CfnOutput(this, "BuildStatus", {
      value: "AWS-V0-BUILD-1-BOUNDARY-ONLY",
      description: props.purpose,
    });
  }
}
