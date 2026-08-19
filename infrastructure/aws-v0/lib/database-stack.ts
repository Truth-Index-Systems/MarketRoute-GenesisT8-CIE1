import { CfnOutput, Duration, RemovalPolicy, Stack, StackProps } from "aws-cdk-lib";
import * as ec2 from "aws-cdk-lib/aws-ec2";
import * as rds from "aws-cdk-lib/aws-rds";
import * as secretsmanager from "aws-cdk-lib/aws-secretsmanager";
import { Construct } from "constructs";

const DATABASE_NAME = "marketroute";
const ENGINE_VERSION = rds.AuroraPostgresEngineVersion.VER_16_8;
const MIN_ACU = 0;
const MAX_ACU = 2;
const AUTO_PAUSE = Duration.minutes(5);
const DATABASE_AZS = ["eu-west-2a", "eu-west-2b"];

/**
 * Build 2: fresh Aurora PostgreSQL foundation only.
 *
 * No MarketRoute schema or research data is created here. Build 3 owns the
 * canonical AWS schema baseline. Data API is the only intended application
 * access path at this stage; the cluster is isolated from public networking.
 */
export class MrAwsV0DatabaseStack extends Stack {
  public constructor(scope: Construct, id: string, props: StackProps) {
    super(scope, id, props);

    const vpc = new ec2.Vpc(this, "DatabaseVpc", {
      ipAddresses: ec2.IpAddresses.cidr("10.42.0.0/20"),
      // Pin the two London AZ aliases used by this fixed account/region so CDK
      // synthesis remains fully offline and never requires AWS credentials.
      availabilityZones: DATABASE_AZS,
      natGateways: 0,
      subnetConfiguration: [
        {
          name: "database",
          subnetType: ec2.SubnetType.PRIVATE_ISOLATED,
          cidrMask: 24,
        },
      ],
    });

    const securityGroup = new ec2.SecurityGroup(this, "DatabaseSecurityGroup", {
      vpc,
      allowAllOutbound: false,
      description: "MarketRoute AWS V0 Aurora boundary; no direct network clients in Build 2",
    });

    const adminSecret = new secretsmanager.Secret(this, "DatabaseAdminSecret", {
      secretName: "marketroute/aws-v0/database/admin",
      description: "Generated administrator credentials for the MarketRoute AWS V0 Aurora cluster",
      generateSecretString: {
        secretStringTemplate: JSON.stringify({ username: "marketroute_admin" }),
        generateStringKey: "password",
        passwordLength: 40,
        excludePunctuation: true,
      },
    });
    adminSecret.applyRemovalPolicy(RemovalPolicy.DESTROY);

    const cluster = new rds.DatabaseCluster(this, "DatabaseCluster", {
      clusterIdentifier: "marketroute-aws-v0",
      engine: rds.DatabaseClusterEngine.auroraPostgres({ version: ENGINE_VERSION }),
      writer: rds.ClusterInstance.serverlessV2("writer", {
        publiclyAccessible: false,
      }),
      credentials: rds.Credentials.fromSecret(adminSecret),
      defaultDatabaseName: DATABASE_NAME,
      vpc,
      vpcSubnets: { subnetType: ec2.SubnetType.PRIVATE_ISOLATED },
      securityGroups: [securityGroup],
      enableDataApi: true,
      storageEncrypted: true,
      deletionProtection: false,
      removalPolicy: RemovalPolicy.DESTROY,
      backup: { retention: Duration.days(1) },
      serverlessV2MinCapacity: MIN_ACU,
      serverlessV2MaxCapacity: MAX_ACU,
      serverlessV2AutoPauseDuration: AUTO_PAUSE,
    });

    new CfnOutput(this, "BuildStatus", {
      value: "AWS-V0-BUILD-2-AURORA-FOUNDATION",
      description: "Fresh Aurora PostgreSQL foundation; schema intentionally deferred to Build 3",
    });
    new CfnOutput(this, "ClusterArn", { value: cluster.clusterArn });
    new CfnOutput(this, "SecretArn", { value: adminSecret.secretArn });
    new CfnOutput(this, "DatabaseName", { value: DATABASE_NAME });
    new CfnOutput(this, "EngineVersion", { value: ENGINE_VERSION.auroraPostgresFullVersion });
    new CfnOutput(this, "CapacityRange", { value: `${MIN_ACU}-${MAX_ACU} ACU` });
    new CfnOutput(this, "DataApi", { value: "ENABLED" });
    new CfnOutput(this, "NetworkBoundary", { value: "PRIVATE_ISOLATED-NO_NAT-NO_PUBLIC_INGRESS" });
  }
}
