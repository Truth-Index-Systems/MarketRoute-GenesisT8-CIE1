import "server-only";

import { ConverseCommand } from "@aws-sdk/client-bedrock-runtime";
import type {
  CompanyUnderstandingInput,
  SemanticOperationId,
  SemanticOperationInput,
  SemanticProbeInput,
} from "../../../core/ai/semantic-operation";
import {
  buildCompanyUnderstandingUserPrompt,
  COMPANY_UNDERSTANDING_JSON_SCHEMA,
  COMPANY_UNDERSTANDING_SCHEMA_NAME,
  COMPANY_UNDERSTANDING_SYSTEM_INSTRUCTION,
  parseCompanyUnderstandingOutput,
} from "../../../core/ai/company-understanding-definition";
import {
  buildSemanticProbeUserPrompt,
  parseSemanticProbeOutput,
  SEMANTIC_PROBE_JSON_SCHEMA,
  SEMANTIC_PROBE_SCHEMA_NAME,
  SEMANTIC_PROBE_SYSTEM_INSTRUCTION,
} from "../../../core/ai/semantic-probe-definition";
import {
  SemanticProviderError,
  type SemanticProvider,
  type SemanticProviderExecution,
  type SemanticProviderTelemetryMetadata,
} from "../semantic-provider";
import {
  createBedrockRuntimeClient,
  type BedrockRuntimeClientOptions,
} from "./bedrock-runtime";

export const BEDROCK_SEMANTIC_MODEL_IDENTIFIER = "anthropic.claude-sonnet-4-5-20250929-v1:0" as const;

export interface BedrockSemanticProviderOptions extends BedrockRuntimeClientOptions {
  inferenceProfileArn: string;
}

function errorMetadata(error: unknown): SemanticProviderTelemetryMetadata | undefined {
  if (typeof error !== "object" || error === null || !("$metadata" in error)) return undefined;
  const metadata = Reflect.get(error, "$metadata");
  if (typeof metadata !== "object" || metadata === null) return undefined;
  const requestId = Reflect.get(metadata, "requestId");
  return typeof requestId === "string" ? { providerRequestId: requestId } : undefined;
}

function errorStatusCode(error: unknown): number | undefined {
  if (typeof error !== "object" || error === null || !("$metadata" in error)) return undefined;
  const metadata = Reflect.get(error, "$metadata");
  if (typeof metadata !== "object" || metadata === null) return undefined;
  const status = Reflect.get(metadata, "httpStatusCode");
  return typeof status === "number" ? status : undefined;
}

function isRetryableProviderError(error: unknown): boolean {
  const name = error instanceof Error ? error.name : "";
  if (["ThrottlingException", "ServiceUnavailableException", "InternalServerException", "ModelTimeoutException"].includes(name)) {
    return true;
  }
  const status = errorStatusCode(error);
  return typeof status === "number" && status >= 500;
}

function parseJson(text: string | undefined): unknown | null {
  if (!text) return null;
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

function buildCommand<K extends SemanticOperationId>(
  operation: K,
  input: SemanticOperationInput<K>,
  inferenceProfileArn: string,
): { command: ConverseCommand; parse: (value: unknown) => unknown | null } {
  if (operation === "ai.semanticProbe") {
    const probeInput = input as SemanticProbeInput;
    return {
      command: new ConverseCommand({
        modelId: inferenceProfileArn,
        system: [{ text: SEMANTIC_PROBE_SYSTEM_INSTRUCTION }],
        messages: [
          {
            role: "user",
            content: [{ text: buildSemanticProbeUserPrompt(probeInput) }],
          },
        ],
        inferenceConfig: {
          maxTokens: 450,
          temperature: 0,
        },
        outputConfig: {
          textFormat: {
            type: "json_schema",
            structure: {
              jsonSchema: {
                schema: SEMANTIC_PROBE_JSON_SCHEMA,
                name: SEMANTIC_PROBE_SCHEMA_NAME,
                description: "MarketRoute controlled semantic probe output",
              },
            },
          },
        },
      }),
      parse: parseSemanticProbeOutput,
    };
  }

  if (operation === "ai.companyUnderstanding") {
    const companyInput = input as CompanyUnderstandingInput;
    return {
      command: new ConverseCommand({
        modelId: inferenceProfileArn,
        system: [{ text: COMPANY_UNDERSTANDING_SYSTEM_INSTRUCTION }],
        messages: [
          {
            role: "user",
            content: [{ text: buildCompanyUnderstandingUserPrompt(companyInput) }],
          },
        ],
        inferenceConfig: {
          maxTokens: 1_400,
          temperature: 0,
        },
        outputConfig: {
          textFormat: {
            type: "json_schema",
            structure: {
              jsonSchema: {
                schema: COMPANY_UNDERSTANDING_JSON_SCHEMA,
                name: COMPANY_UNDERSTANDING_SCHEMA_NAME,
                description: "MarketRoute evidence-grounded company understanding output",
              },
            },
          },
        },
      }),
      parse: (value: unknown) => parseCompanyUnderstandingOutput(value, companyInput),
    };
  }

  throw new SemanticProviderError("UNSUPPORTED_OPERATION", false);
}

export class BedrockSemanticProvider implements SemanticProvider {
  private readonly client;
  private readonly inferenceProfileArn: string;

  constructor(options: BedrockSemanticProviderOptions) {
    if (!options.inferenceProfileArn) throw new Error("BEDROCK_SEMANTIC_INFERENCE_PROFILE_REQUIRED");
    this.inferenceProfileArn = options.inferenceProfileArn;
    this.client = createBedrockRuntimeClient(options);
  }

  async execute<K extends SemanticOperationId>(
    operation: K,
    input: SemanticOperationInput<K>,
    signal: AbortSignal,
  ): Promise<SemanticProviderExecution<K>> {
    const prepared = buildCommand(operation, input, this.inferenceProfileArn);

    try {
      const response = await this.client.send(prepared.command, { abortSignal: signal });
      const text = response.output?.message?.content?.find((block) => typeof block.text === "string")?.text;
      const rawValue = parseJson(text);
      const value = rawValue === null ? null : prepared.parse(rawValue);
      const telemetry: SemanticProviderTelemetryMetadata = {
        modelIdentifier: BEDROCK_SEMANTIC_MODEL_IDENTIFIER,
        inferenceProfileIdentifier: this.inferenceProfileArn,
        providerRequestId: response.$metadata.requestId,
        usageUnit: "TOKEN",
        inputUnits: response.usage?.inputTokens,
        outputUnits: response.usage?.outputTokens,
      };
      if (value === null) throw new SemanticProviderError("INVALID_RESPONSE", false, telemetry);
      return { value, telemetry } as SemanticProviderExecution<K>;
    } catch (error) {
      if (error instanceof SemanticProviderError) throw error;
      if (signal.aborted) throw new SemanticProviderError("TIMEOUT", true, errorMetadata(error));
      throw new SemanticProviderError("UNAVAILABLE", isRetryableProviderError(error), errorMetadata(error));
    }
  }

  destroy(): void {
    this.client.destroy();
  }
}
