import "server-only";

const BEDROCK_APPLICATION_PROFILE_ARN = /^arn:aws:bedrock:eu-west-2:[0-9]{12}:application-inference-profile\/[A-Za-z0-9._-]+$/;

export function getAwsV0BedrockSemanticInferenceProfileArn(): string {
  const value = process.env.MARKETROUTE_AWS_BEDROCK_INFERENCE_PROFILE_ARN;
  if (!value || !BEDROCK_APPLICATION_PROFILE_ARN.test(value)) {
    throw new Error("AWS_V0_BEDROCK_SEMANTIC_PROFILE_NOT_CONFIGURED");
  }
  return value;
}
