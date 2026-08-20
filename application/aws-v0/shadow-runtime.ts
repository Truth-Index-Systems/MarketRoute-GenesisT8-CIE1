import "server-only";

export interface AwsV0ShadowRuntimeStatus {
  awsRegionPresent: boolean;
  databaseConfigured: boolean;
  cognitoConfigured: boolean;
}

/**
 * Application-owned fail-closed latch for all AWS V0 shadow HTTP surfaces.
 * Route/presentation source must remain environment-blind.
 */
export function isAwsV0ShadowModeEnabled(): boolean {
  return process.env.MARKETROUTE_AWS_SHADOW_MODE === "true";
}

/**
 * Reports configuration presence only. No identifier, ARN, secret, credential,
 * or provider value crosses this application boundary.
 */
export function getAwsV0ShadowRuntimeStatus(): AwsV0ShadowRuntimeStatus {
  return {
    awsRegionPresent: Boolean(process.env.AWS_REGION),
    databaseConfigured: Boolean(
      process.env.MARKETROUTE_AWS_RDS_CLUSTER_ARN &&
        process.env.MARKETROUTE_AWS_RDS_SECRET_ARN &&
        process.env.MARKETROUTE_AWS_RDS_DATABASE,
    ),
    cognitoConfigured: Boolean(
      process.env.MARKETROUTE_COGNITO_USER_POOL_ID &&
        process.env.MARKETROUTE_COGNITO_USER_POOL_CLIENT_ID,
    ),
  };
}
