import {
  canonicaliseClaim,
  canonicaliseEvidence,
  canonicaliseSource,
  type AcquisitionInput,
  type EvidencePolarity,
  type RawClaimInput,
  type RawEvidenceInput,
  type RawSourceInput,
} from "@/core/evidence";
import { type EvidenceRepository, evidenceRepositoryFromEnvironment } from "@/platform/database/evidence-repository";

export interface EvidenceServiceDependencies {
  repository: EvidenceRepository;
}

export interface IngestEvidenceCommand {
  source: RawSourceInput;
  acquisition: AcquisitionInput;
  evidence: RawEvidenceInput;
}

export interface RecordClaimEvidenceCommand {
  claim: RawClaimInput;
  evidenceItemId: string;
  polarity: EvidencePolarity;
  linkMethod: "DETERMINISTIC" | "AI_EXTRACTED" | "USER_PROVIDED" | "MIGRATED";
  linkVersion?: string | null;
}

export class EvidenceService {
  constructor(private readonly dependencies: EvidenceServiceDependencies) {}

  async ingest(command: IngestEvidenceCommand) {
    const source = canonicaliseSource(command.source);
    const evidence = canonicaliseEvidence(source, command.evidence);
    return this.dependencies.repository.ingest(source, command.acquisition, evidence);
  }

  async recordClaimEvidence(command: RecordClaimEvidenceCommand) {
    const claim = canonicaliseClaim(command.claim);
    return this.dependencies.repository.recordClaimEvidence(
      claim,
      command.evidenceItemId,
      command.polarity,
      command.linkMethod,
      command.linkVersion,
    );
  }

  async supersedeClaim(priorClaimId: string, replacementClaimId: string | null, reasonCode: string) {
    const reason = reasonCode.normalize("NFKC").trim().toUpperCase();
    if (!/^[A-Z0-9_:-]{2,80}$/.test(reason)) throw new Error("MARKETROUTE_INVALID_SUPERSESSION_REASON");
    return this.dependencies.repository.supersedeClaim(priorClaimId, replacementClaimId, reason);
  }
}

export function evidenceServiceFromEnvironment(): EvidenceService {
  return new EvidenceService({ repository: evidenceRepositoryFromEnvironment() });
}
