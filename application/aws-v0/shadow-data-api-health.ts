import "server-only";

import { assertAwsRdsDataSdkBundled } from "../../platform/database/aws-data-api-bundle-anchor";
import { awsDataApiFromEnvironment } from "../../platform/database/aws-data-api";

/**
 * Application-layer ownership of the frozen AWS V0 shadow-mode latch.
 * Keeps route/presentation source environment-blind while preserving fail-closed behavior.
 */
export function isAwsV0ShadowModeEnabled(): boolean {
  return process.env.MARKETROUTE_AWS_SHADOW_MODE === "true";
}

/**
 * Application-layer bridge for the frozen AWS V0 shadow health probe.
 * Keeps Next.js routing unaware of platform/database transport details.
 */
export async function runAwsV0ShadowDataApiHealthProbe(): Promise<{ resultOk: boolean }> {
  assertAwsRdsDataSdkBundled();
  const database = await awsDataApiFromEnvironment();
  const result = await database.executeOperation("system.health", {});
  return {
    resultOk: result.rows.length === 1 && result.rows[0]?.ok === 1,
  };
}
