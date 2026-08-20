import "server-only";

import { ConverseCommand } from "@aws-sdk/client-bedrock-runtime";
import type {
  SemanticOperationId,
  SemanticOperationInput,
  SemanticProbeInput,
} from "../../../core/ai/semantic-operation";
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

function parseStructuredText(text: string | undefined): ReturnType<typeof parseSemanticProbeOutput> {
  if (!text) return null;
  try {
    return parseSemanticProbeOutput(JSON.parse(text));
  } catch {
    return null;
  }
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
    if (operation !== "ai.semanticProbe") {
      throw new SemanticProviderError("UNSUPPORTED_OPERATION", false);
    }

    const probeInput = input as SemanticProbeInput;
    const command = new ConverseCommand({
      modelId: this.inferenceProfileArn,
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
    });

    try {
      const response = await this.client.send(command, { abortSignal: signal });
      const text = response.output?.message?.content?.find((block) => typeof block.text === "string")?.text;
      const value = parseStructuredText(text);
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
