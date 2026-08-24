import {
  fingerprintAwsV0ResearchWorkEnvelope,
  parseAwsV0ResearchWorkEnvelope,
  serialiseAwsV0ResearchWorkEnvelope,
  type AwsV0ResearchWorkEnvelope,
} from "../../core/research";
import { ResearchRepository, type ClaimedResearchWork } from "../../platform/database/research-repository";

export interface AwsV0ResearchPublisher {
  publish(body: string): Promise<{ messageId: string }>;
}

export class AwsV0ResearchDispatcher {
  constructor(
    private readonly repository: ResearchRepository,
    private readonly publisher: AwsV0ResearchPublisher,
  ) {}

  async dispatchClaimed(work: ClaimedResearchWork, schedulerRunId: string, at?: string) {
    const dispatchedAt = (at ? new Date(at) : new Date()).toISOString();
    if (work.action !== "SYNTHESIZE_COMPANY_UNDERSTANDING") {
      throw new Error("MARKETROUTE_AWS_V0_DISPATCH_CAPABILITY_UNSUPPORTED");
    }

    let envelope: AwsV0ResearchWorkEnvelope | null = null;
    try {
      const prepared = await this.repository.prepareAwsV0Dispatch(work.workUnitId, schedulerRunId, dispatchedAt);
      envelope = parseAwsV0ResearchWorkEnvelope(prepared);
      if (envelope === null || envelope.workUnitId !== work.workUnitId) {
        throw new Error("MARKETROUTE_AWS_V0_DISPATCH_ENVELOPE_INVALID");
      }
      const body = serialiseAwsV0ResearchWorkEnvelope(envelope);
      const envelopeFingerprint = fingerprintAwsV0ResearchWorkEnvelope(envelope);
      const sent = await this.publisher.publish(body);
      if (!sent.messageId.trim() || sent.messageId.length > 256) {
        throw new Error("MARKETROUTE_AWS_V0_DISPATCH_MESSAGE_ID_INVALID");
      }
      await this.repository.markAwsV0DispatchSent(
        work.workUnitId,
        schedulerRunId,
        envelopeFingerprint,
        sent.messageId,
        new Date().toISOString(),
      );
      return { outcome: "DISPATCHED" as const, workUnitId: work.workUnitId, messageId: sent.messageId, envelopeFingerprint };
    } catch (error) {
      await this.repository.failAwsV0Dispatch(
        work.workUnitId,
        schedulerRunId,
        error instanceof Error ? error.message : "MARKETROUTE_AWS_V0_DISPATCH_FAILED",
        true,
        new Date().toISOString(),
      ).catch(() => undefined);
      throw error;
    }
  }
}
