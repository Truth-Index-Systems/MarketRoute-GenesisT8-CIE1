import { CfnOutput, Duration, RemovalPolicy, Stack, StackProps } from "aws-cdk-lib";
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

export class MrAwsV0ResearchStack extends Stack {
  public constructor(scope: Construct, id: string, props: StackProps) {
    super(scope, id, props);

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
      description: "MarketRoute AWS V0 Build 8 research transport worker role",
    });

    workerRole.addToPolicy(new iam.PolicyStatement({
      sid: "MarketRouteResearchWorkerLogs",
      actions: ["logs:CreateLogStream", "logs:PutLogEvents"],
      resources: [`${logGroup.logGroupArn}:*`],
    }));
    queue.grantConsumeMessages(workerRole);

    const worker = new lambda.Function(this, "ResearchWorker", {
      functionName: "marketroute-aws-v0-research-worker",
      description: "MarketRoute AWS V0 Build 8 fail-closed research transport worker",
      runtime: lambda.Runtime.NODEJS_22_X,
      architecture: lambda.Architecture.ARM_64,
      handler: "index.handler",
      code: lambda.Code.fromAsset(path.join(__dirname, "../../runtime/research-worker")),
      timeout: Duration.seconds(WORKER_TIMEOUT_SECONDS),
      memorySize: 512,
      role: workerRole,
      environment: {
        MARKETROUTE_AWS_RESEARCH_TRANSPORT_VERSION: "1",
        MARKETROUTE_AWS_RESEARCH_EXECUTOR_ENABLED: "false",
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
      value: "AWS-V0-BUILD-8-RESEARCH-TRANSPORT",
      description: "Build 8 research SQS/Lambda substrate is provisioned fail-closed; execution remains disabled",
    });
    new CfnOutput(this, "ResearchQueueArn", { value: queue.queueArn });
    new CfnOutput(this, "ResearchQueueUrl", { value: queue.queueUrl });
    new CfnOutput(this, "ResearchDeadLetterQueueArn", { value: dlq.queueArn });
    new CfnOutput(this, "ResearchWorkerArn", { value: worker.functionArn });
    new CfnOutput(this, "ResearchEventSourceStatus", { value: "DISABLED_BUILD8" });
  }
}
