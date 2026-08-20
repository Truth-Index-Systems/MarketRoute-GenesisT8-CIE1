import "server-only";

import { BedrockRuntimeClient } from "@aws-sdk/client-bedrock-runtime";

export const AWS_V0_BEDROCK_REGION = "eu-west-2" as const;
export const BEDROCK_RUNTIME_SDK_VERSION = "3.1111.0" as const;

export interface BedrockRuntimeClientOptions {
  region?: string;
}

/**
 * Server-side Bedrock Runtime client. Credentials are deliberately omitted so
 * Amplify Hosting's SSR compute role supplies short-lived AWS identity.
 * SDK retries remain disabled because MarketRoute owns retry policy.
 */
export function createBedrockRuntimeClient(options: BedrockRuntimeClientOptions = {}): BedrockRuntimeClient {
  return new BedrockRuntimeClient({
    region: options.region ?? AWS_V0_BEDROCK_REGION,
    maxAttempts: 1,
  });
}
