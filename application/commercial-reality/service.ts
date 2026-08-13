import { deriveHardConstraintRequirements, evaluateCommercialReality, type CommercialRealityEvaluation } from "../../core/commercial-reality/index.js";
import { CommercialRealityRepository, commercialRealityRepositoryFromEnvironment, type PersistedCommercialReality } from "../../platform/database/commercial-reality-repository.js";
import { SellerGenomeRepository } from "../../platform/database/seller-genome-repository.js";
import { TruthService, truthServiceFromEnvironment } from "../truth/service.js";

export interface CommercialRealityServiceDependencies {
  repository: CommercialRealityRepository;
  sellerRepository: SellerGenomeRepository;
  truthService: TruthService;
}

export interface CommercialRealityResult {
  evaluation: CommercialRealityEvaluation;
  persisted: PersistedCommercialReality;
}

function exactReferenceTime(value?: string): string {
  const date = value ? new Date(value) : new Date();
  if (Number.isNaN(date.getTime())) throw new Error("MARKETROUTE_R4_INVALID_REFERENCE_TIME");
  return date.toISOString();
}

export class CommercialRealityService {
  constructor(private readonly dependencies: CommercialRealityServiceDependencies) {}

  async evaluate(command: {
    organisationId: string;
    campaignId: string;
    companyId: string;
    referenceTime?: string;
  }): Promise<CommercialRealityResult> {
    const referenceTime = exactReferenceTime(command.referenceTime);
    const seller = await this.dependencies.sellerRepository.getCurrentCampaignContext(command.organisationId, command.campaignId);
    if (!seller) throw new Error("MARKETROUTE_R4_SELLER_CONTEXT_REQUIRED");

    const targetEntity = await this.dependencies.truthService.evaluateEntity({
      tenantScopeOrganisationId: command.organisationId,
      subjectType: "COMPANY",
      subjectId: command.companyId,
      profileKey: "COMPANY_CORE_V1",
      referenceTime,
    });

    const hardRequirements = deriveHardConstraintRequirements(seller.canonicalGenome.semantic);
    const constraintClaimKeys = [...new Set(hardRequirements.flatMap((item) => item.claimKey ? [item.claimKey] : []))].sort();
    const constraintTruthSnapshotMap: Record<string, string[]> = {};

    if (constraintClaimKeys.length > 0) {
      const claimIdsByKey = await this.dependencies.repository.getTargetClaimIds(command.organisationId, command.companyId, constraintClaimKeys);
      for (const claimKey of constraintClaimKeys) {
        const results = await Promise.all((claimIdsByKey[claimKey] ?? []).map((claimId) => this.dependencies.truthService.evaluateClaim(claimId, referenceTime)));
        constraintTruthSnapshotMap[claimKey] = results.map((item) => item.persisted.snapshotId).sort();
      }
    }

    const context = await this.dependencies.repository.getContext({
      organisationId: command.organisationId,
      campaignId: command.campaignId,
      companyId: command.companyId,
      referenceTime,
      sellerContextSelectionId: seller.selectionId,
      targetTruthEntitySnapshotId: targetEntity.persisted.snapshotId,
      constraintTruthSnapshotMap,
    });

    const evaluation = evaluateCommercialReality(context);
    const persisted = await this.dependencies.repository.persist({
      evaluation,
      sellerContextSelectionId: seller.selectionId,
      targetTruthEntitySnapshotId: targetEntity.persisted.snapshotId,
      constraintTruthSnapshotMap,
    });

    return { evaluation, persisted };
  }
}

export function commercialRealityServiceFromEnvironment(): CommercialRealityService {
  return new CommercialRealityService({
    repository: commercialRealityRepositoryFromEnvironment(),
    sellerRepository: SellerGenomeRepository.fromEnvironment(),
    truthService: truthServiceFromEnvironment(),
  });
}
