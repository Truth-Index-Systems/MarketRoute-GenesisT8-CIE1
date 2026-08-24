import { ArnFormat, CfnOutput, CfnParameter, Duration, RemovalPolicy, Stack, StackProps } from "aws-cdk-lib";
import * as iam from "aws-cdk-lib/aws-iam";
import * as lambda from "aws-cdk-lib/aws-lambda";
import * as lambdaEventSources from "aws-cdk-lib/aws-lambda-event-sources";
import * as logs from "aws-cdk-lib/aws-logs";
import * as sqs from "aws-cdk-lib/aws-sqs";
import * as path from "node:path";
import { Construct } from "constructs";

const WORKER_TIMEOUT_SECONDS = 240;
const VISIBILITY_TIMEOUT_SECONDS = 1_440;
const MAX_RECEIVE_COUNT = 5;
const MAX_CONCURRENCY = 2;
const BATCH_SIZE = 1;
const DATABASE_NAME = "marketroute";
const BEDROCK_MODEL_ID = "anthropic.claude-sonnet-4-5-20250929-v1:0";
const BEDROCK_EU_DESTINATION_REGIONS = [
  "eu-central-1",
  "eu-north-1",
  "eu-south-1",
  "eu-south-2",
  "eu-west-1",
  "eu-west-2",
  "eu-west-3",
] as const;

export class MrAwsV0ResearchStack extends Stack {
  public constructor(scope: Construct, id: string, props: StackProps) {
    super(scope, id, props);

    const auroraSecretArn = new CfnParameter(this, "AuroraSecretArn", {
      type: "String",
      allowedPattern: "^arn:aws:secretsmanager:eu-west-2:801132668416:secret:marketroute/aws-v0/database/admin-[A-Za-z0-9]+$",
      description: "Existing AWS V0 Aurora administrator secret ARN used only by the trusted Data API worker.",
    });

    const bedrockInferenceProfileArn = new CfnParameter(this, "BedrockInferenceProfileArn", {
      type: "String",
      allowedPattern: "^arn:aws:bedrock:eu-west-2:801132668416:application-inference-profile/[A-Za-z0-9-]+$",
      description: "Existing Build 7.4 application inference profile ARN for non-streaming company understanding.",
    });

    const dlq = new sqs.Queue(this, "ResearchDeadLetterQueue", {
      queueName: "marketroute-aws-v0-research-dlq",
      encryption: sqs.QueueEncryption.SQS_MANAGED,
      enforceSSL: true,
      retentionPeriod: Duration.days(14),
      removalPolicy: RemovalPolicy.RETAIN,
    });

    const queue = new sqs.Queue(this, "ResearchWorkQueue", {
      queueName: "marketroute-aws-v0-research-work",
      encryption: sqs.QueueEncryption.SQS_MANAGED,
      enforceSSL: true,
      retentionPeriod: Duration.days(4),
      receiveMessageWaitTime: Duration.seconds(20),
      visibilityTimeout: Duration.seconds(VISIBILITY_TIMEOUT_SECONDS),
      deadLetterQueue: {
        queue: dlq,
        maxReceiveCount: MAX_RECEIVE_COUNT,
      },
      removalPolicy: RemovalPolicy.RETAIN,
    });

    const logGroup = new logs.LogGroup(this, "ResearchWorkerLogGroup", {
      logGroupName: "/aws/lambda/marketroute-aws-v0-research-worker",
      retention: logs.RetentionDays.TWO_WEEKS,
      removalPolicy: RemovalPolicy.RETAIN,
    });

    const workerRole = new iam.Role(this, "ResearchWorkerRole", {
      assumedBy: new iam.ServicePrincipal("lambda.amazonaws.com"),
      description: "MarketRoute AWS V0 Build 9 bounded research execution worker role",
    });

    workerRole.addToPolicy(new iam.PolicyStatement({
      sid: "MarketRouteResearchWorkerLogs",
      actions: ["logs:CreateLogStream", "logs:PutLogEvents"],
      resources: [`${logGroup.logGroupArn}:*`],
    }));
    queue.grantConsumeMessages(workerRole);

    const clusterArn = this.formatArn({
      service: "rds",
      resource: "cluster",
      resourceName: "marketroute-aws-v0",
      arnFormat: ArnFormat.COLON_RESOURCE_NAME,
    });
    workerRole.addToPolicy(new iam.PolicyStatement({
      sid: "MarketRouteResearchExecutionDataApi",
      actions: ["rds-data:ExecuteStatement"],
      resources: [clusterArn],
    }));
    workerRole.addToPolicy(new iam.PolicyStatement({
      sid: "MarketRouteResearchExecutionSecretRead",
      actions: ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"],
      resources: [auroraSecretArn.valueAsString],
    }));
    workerRole.addToPolicy(new iam.PolicyStatement({
      sid: "MarketRouteResearchBedrockProfileInvocation",
      actions: ["bedrock:InvokeModel"],
      resources: [bedrockInferenceProfileArn.valueAsString],
    }));
    workerRole.addToPolicy(new iam.PolicyStatement({
      sid: "MarketRouteResearchBedrockModelBoundary",
      actions: ["bedrock:InvokeModel"],
      resources: BEDROCK_EU_DESTINATION_REGIONS.map(
        (region) => `arn:aws:bedrock:${region}::foundation-model/${BEDROCK_MODEL_ID}`,
      ),
      conditions: {
        StringEquals: {
          "aws:InferenceProfileArn": bedrockInferenceProfileArn.valueAsString,
        },
      },
    }));

    const worker = new lambda.Function(this, "ResearchWorker", {
      functionName: "marketroute-aws-v0-research-worker",
      description: "MarketRoute AWS V0 Build 9 idempotent evidence-grounded semantic worker",
      runtime: lambda.Runtime.NODEJS_22_X,
      architecture: lambda.Architecture.ARM_64,
      handler: "index.handler",
      code: lambda.Code.fromAsset(path.join(__dirname, "../../runtime/research-worker")),
      timeout: Duration.seconds(WORKER_TIMEOUT_SECONDS),
      memorySize: 512,
      role: workerRole,
      environment: {
        MARKETROUTE_AWS_RESEARCH_TRANSPORT_VERSION: "1",
        MARKETROUTE_AWS_RESEARCH_EXECUTOR_ENABLED: "true",
        MARKETROUTE_AWS_RDS_CLUSTER_ARN: clusterArn,
        MARKETROUTE_AWS_RDS_SECRET_ARN: auroraSecretArn.valueAsString,
        MARKETROUTE_AWS_RDS_DATABASE: DATABASE_NAME,
        MARKETROUTE_AWS_BEDROCK_INFERENCE_PROFILE_ARN: bedrockInferenceProfileArn.valueAsString,
      },
    });

    worker.node.addDependency(logGroup);

    worker.addEventSource(new lambdaEventSources.SqsEventSource(queue, {
      batchSize: BATCH_SIZE,
      enabled: false,
      reportBatchItemFailures: true,
      maxConcurrency: MAX_CONCURRENCY,
    }));

    new CfnOutput(this, "BuildStatus", {
      value: "AWS-V0-BUILD-10-RESEARCH-ORCHESTRATION-SPLIT",
      description: "Build 10 split is source-ready; SQS activation remains disabled pending planner producer and live quota proof",
    });
    new CfnOutput(this, "ResearchQueueArn", { value: queue.queueArn });
    new CfnOutput(this, "ResearchQueueUrl", { value: queue.queueUrl });
    new CfnOutput(this, "ResearchDeadLetterQueueArn", { value: dlq.queueArn });
    new CfnOutput(this, "ResearchWorkerArn", { value: worker.functionArn });
    new CfnOutput(this, "ResearchExecutionReceiptStore", { value: "AURORA_DATA_API_NON_CANONICAL" });
    new CfnOutput(this, "ResearchEventSourceStatus", { value: "DISABLED_PENDING_PLANNER_AND_QUOTA_PROOF" });
  }
}
