import type {
  TruthClaimContext,
  TruthClaimEvaluation,
  TruthEntityEvaluation,
  TruthEntityProfile,
} from "@/core/truth";
import { PostgrestRpcClient, databaseConfigFromEnvironment } from "./postgrest-rpc";

export interface PersistedTruthSnapshot {
  snapshotId: string;
  reasoningRunId: string;
  reasoningArtifactId: string;
  snapshotFingerprint: string;
}

export interface PersistedEntityTruthSnapshot extends PersistedTruthSnapshot {
  inputFingerprint: string;
}

export interface EntityTruthContextClaim {
  claimKey: string;
  claimIds: string[];
}

export interface EntityTruthContext {
  tenantScopeOrganisationId: string | null;
  subjectType: string;
  subjectId: string;
  referenceTime: string;
  profile: TruthEntityProfile;
  claims: EntityTruthContextClaim[];
}

interface ClaimPersistRow {
  snapshot_id: string;
  reasoning_run_id: string;
  reasoning_artifact_id: string;
  snapshot_fingerprint: string;
}

interface EntityPersistRow extends ClaimPersistRow {
  input_fingerprint: string;
}

function oneRow<T>(value: T[] | T, code: string): T {
  if (Array.isArray(value)) {
    if (value.length !== 1) throw new Error(`${code}:${value.length}`);
    return value[0]!;
  }
  if (!value) throw new Error(`${code}:0`);
  return value;
}

export class TruthRepository {
  constructor(private readonly rpc: PostgrestRpcClient) {}

  async getClaimContext(claimId: string, referenceTime: string): Promise<TruthClaimContext> {
    return this.rpc.call<TruthClaimContext>("marketroute_get_claim_truth_context_v1", {
      p_claim_id: claimId,
      p_reference_time: referenceTime,
    });
  }

  async persistClaimEvaluation(evaluation: TruthClaimEvaluation): Promise<PersistedTruthSnapshot> {
    const result = await this.rpc.call<ClaimPersistRow[] | ClaimPersistRow>("marketroute_persist_claim_truth_v1", {
      p_claim_id: evaluation.claimId,
      p_reference_time: evaluation.referenceTime,
      p_context_fingerprint: evaluation.inputFingerprint,
      p_engine_version: evaluation.engineVersion,
      p_semantics_version: evaluation.semanticsVersion,
      p_truth_state: evaluation.truthState,
      p_current_support_family_count: evaluation.currentSupportFamilyCount,
      p_current_contradiction_family_count: evaluation.currentContradictionFamilyCount,
      p_stale_family_count: evaluation.staleFamilyCount,
      p_temporal_anomaly_count: evaluation.temporalAnomalyCount,
      p_evidence_sufficiency: evaluation.evidenceSufficiency,
      p_support_strength: evaluation.supportStrength,
      p_contradiction_strength: evaluation.contradictionStrength,
      p_evidence_balance: evaluation.evidenceBalance,
      p_freshness_coverage: evaluation.freshnessCoverage,
      p_truth_probability: evaluation.truthProbability,
      p_probability_state: evaluation.probabilityState,
      p_next_revalidation_at: evaluation.nextRevalidationAt,
      p_payload_json: { familyDiagnostics: evaluation.familyDiagnostics },
    });
    const row = oneRow(result, "MARKETROUTE_TRUTH_PERSIST_ROW_COUNT");
    return {
      snapshotId: row.snapshot_id,
      reasoningRunId: row.reasoning_run_id,
      reasoningArtifactId: row.reasoning_artifact_id,
      snapshotFingerprint: row.snapshot_fingerprint,
    };
  }

  async getEntityContext(
    tenantScopeOrganisationId: string | null,
    subjectType: string,
    subjectId: string,
    profileKey: string,
    referenceTime: string,
  ): Promise<EntityTruthContext> {
    return this.rpc.call<EntityTruthContext>("marketroute_get_entity_truth_context_v1", {
      p_tenant_scope_organisation_id: tenantScopeOrganisationId,
      p_subject_type: subjectType,
      p_subject_id: subjectId,
      p_profile_key: profileKey,
      p_reference_time: referenceTime,
    });
  }

  async persistEntityEvaluation(
    tenantScopeOrganisationId: string | null,
    evaluation: TruthEntityEvaluation,
    claimSnapshotMap: Record<string, string[]>,
  ): Promise<PersistedEntityTruthSnapshot> {
    const result = await this.rpc.call<EntityPersistRow[] | EntityPersistRow>("marketroute_persist_entity_truth_v1", {
      p_tenant_scope_organisation_id: tenantScopeOrganisationId,
      p_subject_type: evaluation.subjectType,
      p_subject_id: evaluation.subjectId,
      p_profile_key: evaluation.profile.profileKey,
      p_reference_time: evaluation.referenceTime,
      p_claim_snapshot_map: claimSnapshotMap,
      p_aggregation_version: evaluation.aggregationVersion,
      p_semantics_version: evaluation.semanticsVersion,
      p_entity_state: evaluation.entityState,
      p_required_claim_count: evaluation.requiredClaimCount,
      p_known_claim_count: evaluation.knownClaimCount,
      p_supported_claim_count: evaluation.supportedClaimCount,
      p_contradicted_claim_count: evaluation.contradictedClaimCount,
      p_stale_claim_count: evaluation.staleClaimCount,
      p_unresolved_claim_count: evaluation.unresolvedClaimCount,
      p_coverage: evaluation.coverage,
      p_current_coverage: evaluation.currentCoverage,
      p_evidence_sufficiency: evaluation.evidenceSufficiency,
      p_freshness_coverage: evaluation.freshnessCoverage,
      p_coherence: evaluation.coherence,
      p_truth_index: evaluation.truthIndex,
      p_truth_probability: evaluation.truthProbability,
      p_probability_state: evaluation.probabilityState,
      p_next_revalidation_at: evaluation.nextRevalidationAt,
      p_payload_json: {},
    });
    const row = oneRow(result, "MARKETROUTE_ENTITY_TRUTH_PERSIST_ROW_COUNT");
    return {
      snapshotId: row.snapshot_id,
      reasoningRunId: row.reasoning_run_id,
      reasoningArtifactId: row.reasoning_artifact_id,
      inputFingerprint: row.input_fingerprint,
      snapshotFingerprint: row.snapshot_fingerprint,
    };
  }
}

export function truthRepositoryFromEnvironment(): TruthRepository {
  return new TruthRepository(new PostgrestRpcClient(databaseConfigFromEnvironment()));
}
