import { BedrockRuntimeClient } from "@aws-sdk/client-bedrock-runtime";

export const AWS_V0_BEDROCK_REGION = "eu-west-2" as const;
export const BEDROCK_RUNTIME_SDK_VERSION = "3.1111.0" as const;

export interface BedrockRuntimeClientOptions {
  region?: string;
}

/**
 * Build 7.2 only establishes the server-side SDK boundary.
 * Credentials are deliberately omitted so AWS execution-role identity is used.
 * SDK retries are disabled here because MarketRoute owns retry policy at the application boundary.
 */
export function createBedrockRuntimeClient(options: BedrockRuntimeClientOptions = {}): BedrockRuntimeClient {
  return new BedrockRuntimeClient({
    region: options.region ?? AWS_V0_BEDROCK_REGION,
    maxAttempts: 1,
  });
}
