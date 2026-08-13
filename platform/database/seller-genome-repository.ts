import { PostgrestRpcClient, databaseConfigFromEnvironment } from "./postgrest-rpc.js";
import type { CanonicalSellerGenome } from "../../core/seller-genome/index.js";

export interface SellerGenomeSourceRecord {
  sourceMaterialId: string;
  materialFingerprint: string;
  deduplicated: boolean;
}

export interface SellerGenomeSnapshotRecord {
  genomeSnapshotId: string;
  contentFingerprint: string;
  semanticFingerprint: string;
  semanticCompleteness: "COMPLETE" | "PARTIAL";
  deduplicated: boolean;
}

export interface CampaignSellerContextSelectionRecord {
  selectionId: string;
  selectionRequestId: string;
  inputFingerprint: string;
  semanticContextFingerprint: string;
  deduplicated: boolean;
}

export interface CurrentCampaignSellerContext {
  selectionId: string;
  organisationId: string;
  campaignId: string;
  sellerBusinessId: string;
  genomeSnapshotId: string;
  objectiveKey: string;
  selectionRequestId: string;
  inputFingerprint: string;
  semanticContextFingerprint: string;
  semanticFingerprint: string;
  contentFingerprint: string;
  semanticCompleteness: "COMPLETE" | "PARTIAL";
  missingDimensions: string[];
  canonicalGenome: CanonicalSellerGenome;
  createdAt: string;
}

export class SellerGenomeRepository {
  constructor(private readonly rpc: PostgrestRpcClient) {}

  static fromEnvironment(): SellerGenomeRepository {
    return new SellerGenomeRepository(new PostgrestRpcClient(databaseConfigFromEnvironment()));
  }

  recordSourceMaterial(input: {
    organisationId: string;
    sellerBusinessId: string;
    materialKind: "USER_DECLARED" | "WEBSITE_ANALYSIS" | "IMPORT" | "COMPOSITE";
    content: unknown;
    createdByUserId?: string | null;
  }): Promise<SellerGenomeSourceRecord> {
    return this.rpc.call("marketroute_record_seller_genome_source_v1", {
      p_organisation_id: input.organisationId,
      p_seller_business_id: input.sellerBusinessId,
      p_material_kind: input.materialKind,
      p_content_json: input.content,
      p_created_by_user_id: input.createdByUserId ?? null,
    });
  }

  persistGenome(input: {
    organisationId: string;
    sellerBusinessId: string;
    sourceMaterialId: string;
    extractionContractVersion: string;
    extractorVersion: string;
    genome: CanonicalSellerGenome;
  }): Promise<SellerGenomeSnapshotRecord> {
    return this.rpc.call("marketroute_persist_seller_genome_v1", {
      p_organisation_id: input.organisationId,
      p_seller_business_id: input.sellerBusinessId,
      p_source_material_id: input.sourceMaterialId,
      p_schema_version: input.genome.schemaVersion,
      p_canonicalisation_version: input.genome.canonicalisationVersion,
      p_extraction_contract_version: input.extractionContractVersion,
      p_extractor_version: input.extractorVersion,
      p_canonical_genome_json: input.genome,
    });
  }

  selectCampaignContext(input: {
    organisationId: string;
    campaignId: string;
    genomeSnapshotId: string;
    objectiveKey: string;
    requestId: string;
  }): Promise<CampaignSellerContextSelectionRecord> {
    return this.rpc.call("marketroute_select_campaign_seller_context_v1", {
      p_organisation_id: input.organisationId,
      p_campaign_id: input.campaignId,
      p_genome_snapshot_id: input.genomeSnapshotId,
      p_objective_key: input.objectiveKey,
      p_request_id: input.requestId,
    });
  }

  getCurrentCampaignContext(organisationId: string, campaignId: string): Promise<CurrentCampaignSellerContext | null> {
    return this.rpc.call("marketroute_get_current_campaign_seller_context_v1", {
      p_organisation_id: organisationId,
      p_campaign_id: campaignId,
    });
  }
}
