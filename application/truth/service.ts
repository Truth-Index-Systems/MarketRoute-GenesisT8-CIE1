import { evaluateTruthClaim, evaluateTruthEntity, type TruthClaimEvaluation } from "@/core/truth";
import {
  TruthRepository,
  truthRepositoryFromEnvironment,
  type PersistedEntityTruthSnapshot,
  type PersistedTruthSnapshot,
} from "@/platform/database/truth-repository";

export interface TruthServiceDependencies {
  repository: TruthRepository;
}

export interface ClaimTruthResult {
  evaluation: TruthClaimEvaluation;
  persisted: PersistedTruthSnapshot;
}

export interface EntityTruthResult {
  evaluation: ReturnType<typeof evaluateTruthEntity>;
  persisted: PersistedEntityTruthSnapshot;
  claimResults: Record<string, ClaimTruthResult[]>;
}

function exactReferenceTime(value?: string): string {
  const date = value ? new Date(value) : new Date();
  if (Number.isNaN(date.getTime())) throw new Error("MARKETROUTE_TRUTH_INVALID_REFERENCE_TIME");
  return date.toISOString();
}

export class TruthService {
  constructor(private readonly dependencies: TruthServiceDependencies) {}

  async evaluateClaim(claimId: string, referenceTime?: string): Promise<ClaimTruthResult> {
    const reference = exactReferenceTime(referenceTime);
    const context = await this.dependencies.repository.getClaimContext(claimId, reference);
    const evaluation = evaluateTruthClaim(context);
    const persisted = await this.dependencies.repository.persistClaimEvaluation(evaluation);
    return { evaluation, persisted };
  }

  async evaluateEntity(command: {
    tenantScopeOrganisationId: string | null;
    subjectType: string;
    subjectId: string;
    profileKey: string;
    referenceTime?: string;
  }): Promise<EntityTruthResult> {
    const reference = exactReferenceTime(command.referenceTime);
    const context = await this.dependencies.repository.getEntityContext(
      command.tenantScopeOrganisationId,
      command.subjectType,
      command.subjectId,
      command.profileKey,
      reference,
    );

    const claimResults: Record<string, ClaimTruthResult[]> = {};
    const claimSnapshotMap: Record<string, string[]> = {};

    await Promise.all(context.claims.map(async (claimGroup) => {
      const results = await Promise.all(claimGroup.claimIds.map((claimId) => this.evaluateClaim(claimId, reference)));
      results.sort((a, b) => a.persisted.snapshotId.localeCompare(b.persisted.snapshotId));
      claimResults[claimGroup.claimKey] = results;
      claimSnapshotMap[claimGroup.claimKey] = results.map((result) => result.persisted.snapshotId);
    }));

    for (const requiredKey of context.profile.requiredClaimKeys) {
      claimResults[requiredKey] ??= [];
      claimSnapshotMap[requiredKey] ??= [];
    }

    const evaluation = evaluateTruthEntity(
      command.subjectId,
      reference,
      context.profile,
      context.profile.requiredClaimKeys.map((claimKey) => ({
        claimKey,
        evaluations: (claimResults[claimKey] ?? []).map((result) => result.evaluation),
      })),
    );
    const persisted = await this.dependencies.repository.persistEntityEvaluation(
      command.tenantScopeOrganisationId,
      evaluation,
      claimSnapshotMap,
    );

    return { evaluation, persisted, claimResults };
  }
}

export function truthServiceFromEnvironment(): TruthService {
  return new TruthService({ repository: truthRepositoryFromEnvironment() });
}
