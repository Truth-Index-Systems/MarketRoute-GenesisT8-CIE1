import "server-only";

import { RDSDataClient } from "@aws-sdk/client-rds-data";

export function assertAwsRdsDataSdkBundled(): void {
  if (typeof RDSDataClient !== "function") {
    throw new Error("MARKETROUTE_AWS_RDS_DATA_SDK_BUNDLE_INVALID");
  }
}
