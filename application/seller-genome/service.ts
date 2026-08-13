import {
  SELLER_GENOME_EXTRACTION_CONTRACT_VERSION,
  canonicaliseSellerGenome,
  type CanonicalSellerGenome,
  type SellerGenomeExtractionEnvelope,
} from "../../core/seller-genome/index.js";
import {
  validateSellerGenomeExtractionEnvelope,
  type SellerGenomeSemanticExtractor,
  type SellerGenomeSourceMaterial,
} from "../../platform/ai/seller-genome-extractor.js";
import { SellerGenomeRepository } from "../../platform/database/seller-genome-repository.js";

export interface PersistedSellerGenome {
  genome: CanonicalSellerGenome;
  sourceMaterialId: string;
  materialFingerprint: string;
  genomeSnapshotId: string;
  contentFingerprint: string;
  semanticFingerprint: string;
  semanticCompleteness: "COMPLETE" | "PARTIAL";
}

export class SellerGenomeService {
  constructor(private readonly repository: SellerGenomeRepository) {}

  async persistSemanticExtraction(input: {
    organisationId: string;
    sellerBusinessId: string;
    sellerDisplayName: string;
    materialKind: SellerGenomeSourceMaterial["materialKind"];
    sourceContent: unknown;
    extraction: SellerGenomeExtractionEnvelope;
    createdByUserId?: string | null;
  }): Promise<PersistedSellerGenome> {
    const extraction = validateSellerGenomeExtractionEnvelope(input.extraction);
    const genome = canonicaliseSellerGenome(input.sellerBusinessId, input.sellerDisplayName, extraction.candidate);
    const source = await this.repository.recordSourceMaterial({
      organisationId: input.organisationId,
      sellerBusinessId: input.sellerBusinessId,
      materialKind: input.materialKind,
      content: input.sourceContent,
      createdByUserId: input.createdByUserId,
    });
    const snapshot = await this.repository.persistGenome({
      organisationId: input.organisationId,
      sellerBusinessId: input.sellerBusinessId,
      sourceMaterialId: source.sourceMaterialId,
      extractionContractVersion: extraction.contractVersion,
      extractorVersion: extraction.extractorVersion,
      genome,
    });
    return {
      genome,
      sourceMaterialId: source.sourceMaterialId,
      materialFingerprint: source.materialFingerprint,
      genomeSnapshotId: snapshot.genomeSnapshotId,
      contentFingerprint: snapshot.contentFingerprint,
      semanticFingerprint: snapshot.semanticFingerprint,
      semanticCompleteness: snapshot.semanticCompleteness,
    };
  }

  async extractAndPersist(input: {
    organisationId: string;
    sellerBusinessId: string;
    sellerDisplayName: string;
    materialKind: SellerGenomeSourceMaterial["materialKind"];
    sourceContent: unknown;
    extractor: SellerGenomeSemanticExtractor;
    createdByUserId?: string | null;
  }): Promise<PersistedSellerGenome> {
    const extraction = await input.extractor.extract({
      sellerBusinessId: input.sellerBusinessId,
      sellerDisplayName: input.sellerDisplayName,
      materialKind: input.materialKind,
      content: input.sourceContent,
    });
    return this.persistSemanticExtraction({ ...input, extraction });
  }

  selectCampaignObjective(input: { organisationId: string; campaignId: string; genomeSnapshotId: string; objectiveKey: string; requestId: string }) {
    return this.repository.selectCampaignContext(input);
  }

  currentCampaignContext(organisationId: string, campaignId: string) {
    return this.repository.getCurrentCampaignContext(organisationId, campaignId);
  }
}

export const SELLER_GENOME_APPLICATION_EXTRACTION_CONTRACT = SELLER_GENOME_EXTRACTION_CONTRACT_VERSION;
