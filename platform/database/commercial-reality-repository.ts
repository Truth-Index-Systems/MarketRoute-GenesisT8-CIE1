import type { CommercialRealityContext, CommercialRealityEvaluation } from "../../core/commercial-reality/index.js";
import { PostgrestRpcClient, databaseConfigFromEnvironment } from "./postgrest-rpc.js";

export interface PersistedCommercialReality {
  r4RecordId: string;
  authorityRecordId: string;
  reasoningRunId: string;
  reasoningArtifactId: string;
  inputFingerprint: string;
  authorityFingerprint: string;
  validUntil: string;
  deduplicated: boolean;
}

interface PersistRow {
  r4_record_id: string;
  authority_record_id: string;
  reasoning_run_id: string;
  reasoning_artifact_id: string;
  input_fingerprint: string;
  authority_fingerprint: string;
  valid_until: string;
  deduplicated: boolean;
}

function oneRow<T>(value: T[] | T, code: string): T {
  if (Array.isArray(value)) {
    if (value.length !== 1) throw new Error(`${code}:${value.length}`);
    return value[0]!;
  }
  if (!value) throw new Error(`${code}:0`);
  return value;
}

export class CommercialRealityRepository {
  constructor(private readonly rpc: PostgrestRpcClient) {}

  static fromEnvironment(): CommercialRealityRepository {
    return new CommercialRealityRepository(new PostgrestRpcClient(databaseConfigFromEnvironment()));
  }

  getTargetClaimIds(organisationId: string, companyId: string, claimKeys: string[]): Promise<Record<string, string[]>> {
    return this.rpc.call("marketroute_get_r4_target_claim_ids_v1", {
      p_organisation_id: organisationId,
      p_company_id: companyId,
      p_claim_keys: claimKeys,
    });
  }

  getContext(input: {
    organisationId: string;
    campaignId: string;
    companyId: string;
    referenceTime: string;
    sellerContextSelectionId: string;
    targetTruthEntitySnapshotId: string;
    constraintTruthSnapshotMap: Record<string, string[]>;
  }): Promise<CommercialRealityContext> {
    return this.rpc.call("marketroute_get_r4_context_v1", {
      p_organisation_id: input.organisationId,
      p_campaign_id: input.campaignId,
      p_company_id: input.companyId,
      p_reference_time: input.referenceTime,
      p_seller_context_selection_id: input.sellerContextSelectionId,
      p_target_truth_entity_snapshot_id: input.targetTruthEntitySnapshotId,
      p_constraint_truth_snapshot_map: input.constraintTruthSnapshotMap,
    });
  }

  async persist(input: {
    evaluation: CommercialRealityEvaluation;
    sellerContextSelectionId: string;
    targetTruthEntitySnapshotId: string;
    constraintTruthSnapshotMap: Record<string, string[]>;
  }): Promise<PersistedCommercialReality> {
    const e = input.evaluation;
    const result = await this.rpc.call<PersistRow[] | PersistRow>("marketroute_persist_commercial_reality_r4_v1", {
      p_organisation_id: e.organisationId,
      p_campaign_id: e.campaignId,
      p_company_id: e.companyId,
      p_reference_time: e.referenceTime,
      p_seller_context_selection_id: input.sellerContextSelectionId,
      p_target_truth_entity_snapshot_id: input.targetTruthEntitySnapshotId,
      p_constraint_truth_snapshot_map: input.constraintTruthSnapshotMap,
      p_engine_version: e.engineVersion,
      p_semantics_version: e.semanticsVersion,
      p_boundary_constitution_version: e.boundaryConstitutionVersion,
      p_reality_class: e.realityClass,
      p_decision_code: e.decision,
      p_boundaries_json: e.boundaries,
      p_next_revalidation_at: e.nextRevalidationAt,
    });
    const row = oneRow(result, "MARKETROUTE_R4_PERSIST_ROW_COUNT");
    return {
      r4RecordId: row.r4_record_id,
      authorityRecordId: row.authority_record_id,
      reasoningRunId: row.reasoning_run_id,
      reasoningArtifactId: row.reasoning_artifact_id,
      inputFingerprint: row.input_fingerprint,
      authorityFingerprint: row.authority_fingerprint,
      validUntil: row.valid_until,
      deduplicated: row.deduplicated,
    };
  }
}

export function commercialRealityRepositoryFromEnvironment(): CommercialRealityRepository {
  return CommercialRealityRepository.fromEnvironment();
}
