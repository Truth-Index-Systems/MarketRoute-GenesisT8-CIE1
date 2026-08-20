import type {
  SemanticOperationId,
  SemanticOperationInput,
  SemanticOperationOutput,
} from "../../../core/ai/semantic-operation";
import {
  SemanticProviderError,
  type SemanticProvider,
} from "../semantic-provider";
import {
  createBedrockRuntimeClient,
  type BedrockRuntimeClientOptions,
} from "./bedrock-runtime";

/**
 * Build 7.2 fail-closed adapter scaffold.
 * Live Bedrock invocation is intentionally deferred to the certified shadow route stage.
 */
export class BedrockSemanticProvider implements SemanticProvider {
  private readonly client;

  constructor(options: BedrockRuntimeClientOptions = {}) {
    this.client = createBedrockRuntimeClient(options);
  }

  async execute<K extends SemanticOperationId>(
    _operation: K,
    _input: SemanticOperationInput<K>,
    _signal: AbortSignal,
  ): Promise<SemanticOperationOutput<K>> {
    throw new SemanticProviderError("NOT_LIVE", false);
  }

  destroy(): void {
    this.client.destroy();
  }
}
