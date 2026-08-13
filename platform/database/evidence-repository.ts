import type {
  AcquisitionInput,
  CanonicalClaim,
  CanonicalEvidence,
  CanonicalSource,
  EvidencePolarity,
} from "@/core/evidence";
import { PostgrestRpcClient, databaseConfigFromEnvironment } from "./postgrest-rpc";

export interface PersistedEvidenceResult {
  sourceId: string;
  acquisitionId: string;
  evidenceItemId: string;
  sourceCreated: boolean;
  evidenceCreated: boolean;
}

export interface PersistedClaimLinkResult {
  claimId: string;
  claimEvidenceLinkId: string;
  claimCreated: boolean;
  linkCreated: boolean;
}

interface EvidenceRpcRow {
  source_id: string;
  acquisition_id: string;
  evidence_item_id: string;
  source_created: boolean;
  evidence_created: boolean;
}

interface ClaimRpcRow {
  claim_id: string;
  claim_evidence_link_id: string;
  claim_created: boolean;
  link_created: boolean;
}

function oneRow<T>(value: T[] | T, code: string): T {
  if (Array.isArray(value)) {
    if (value.length !== 1) throw new Error(`${code}:${value.length}`);
    return value[0]!;
  }
  if (!value) throw new Error(`${code}:0`);
  return value;
}

export class EvidenceRepository {
  constructor(private readonly rpc: PostgrestRpcClient) {}

  async ingest(source: CanonicalSource, acquisition: AcquisitionInput, evidence: CanonicalEvidence): Promise<PersistedEvidenceResult> {
    const result = await this.rpc.call<EvidenceRpcRow[] | EvidenceRpcRow>("marketroute_ingest_evidence_v1", {
      p_source_kind: source.sourceKind,
      p_canonical_url: source.canonicalUrl,
      p_publisher_domain: source.publisherDomain,
      p_title: source.title,
      p_source_published_at: source.publishedAt,
      p_stable_locator: source.stableLocator,
      p_source_identity_fingerprint: source.sourceIdentityFingerprint,
      p_dependence_family_key: source.dependenceFamilyKey,
      p_normalisation_version: source.normalisationVersion,
      p_source_metadata_json: source.metadata,
      p_acquired_at: acquisition.acquiredAt ?? null,
      p_acquisition_method: acquisition.method,
      p_observed_content_fingerprint: acquisition.observedContentFingerprint ?? null,
      p_http_status: acquisition.httpStatus ?? null,
      p_raw_locator: acquisition.rawLocator ?? null,
      p_parser_version: acquisition.parserVersion ?? null,
      p_request_id: acquisition.requestId ?? null,
      p_acquisition_metadata_json: acquisition.metadata ?? {},
      p_tenant_scope_organisation_id: evidence.tenantScopeOrganisationId,
      p_subject_type: evidence.subjectType,
      p_subject_id: evidence.subjectId,
      p_evidence_kind: evidence.evidenceKind,
      p_excerpt_text: evidence.excerptText,
      p_structured_value_json: evidence.structuredValue,
      p_observed_at: evidence.observedAt,
      p_origin_published_at: evidence.originPublishedAt,
      p_extraction_method: evidence.extractionMethod,
      p_extraction_version: evidence.extractionVersion,
      p_evidence_fingerprint: evidence.evidenceFingerprint,
      p_fingerprint_version: evidence.fingerprintVersion,
    });
    const row = oneRow(result, "MARKETROUTE_EVIDENCE_RPC_ROW_COUNT");
    return {
      sourceId: row.source_id,
      acquisitionId: row.acquisition_id,
      evidenceItemId: row.evidence_item_id,
      sourceCreated: row.source_created,
      evidenceCreated: row.evidence_created,
    };
  }

  async recordClaimEvidence(
    claim: CanonicalClaim,
    evidenceItemId: string,
    polarity: EvidencePolarity,
    linkMethod: "DETERMINISTIC" | "AI_EXTRACTED" | "USER_PROVIDED" | "MIGRATED",
    linkVersion?: string | null,
  ): Promise<PersistedClaimLinkResult> {
    const result = await this.rpc.call<ClaimRpcRow[] | ClaimRpcRow>("marketroute_record_claim_evidence_v1", {
      p_tenant_scope_organisation_id: claim.tenantScopeOrganisationId,
      p_subject_type: claim.subjectType,
      p_subject_id: claim.subjectId,
      p_claim_key: claim.claimKey,
      p_predicate: claim.predicate,
      p_object_json: claim.object,
      p_canonical_value_text: claim.canonicalValueText,
      p_claim_fingerprint: claim.claimFingerprint,
      p_claim_fingerprint_version: claim.fingerprintVersion,
      p_evidence_item_id: evidenceItemId,
      p_polarity: polarity,
      p_link_method: linkMethod,
      p_link_version: linkVersion ?? null,
    });
    const row = oneRow(result, "MARKETROUTE_CLAIM_RPC_ROW_COUNT");
    return {
      claimId: row.claim_id,
      claimEvidenceLinkId: row.claim_evidence_link_id,
      claimCreated: row.claim_created,
      linkCreated: row.link_created,
    };
  }

  async supersedeClaim(priorClaimId: string, replacementClaimId: string | null, reasonCode: string): Promise<string> {
    return this.rpc.call<string>("marketroute_supersede_claim_v1", {
      p_prior_claim_id: priorClaimId,
      p_replacement_claim_id: replacementClaimId,
      p_reason_code: reasonCode,
    });
  }
}

export function evidenceRepositoryFromEnvironment(): EvidenceRepository {
  return new EvidenceRepository(new PostgrestRpcClient(databaseConfigFromEnvironment()));
}
