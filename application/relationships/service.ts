import { canonicaliseGraphNode, canonicaliseRelationship, evaluateRouteAuthority, type RawRelationshipInput, type RouteAuthorityEvaluation } from "../../core/relationships/index.js";
import type { AcquisitionInput, EvidencePolarity, RawEvidenceInput, RawSourceInput } from "../../core/evidence/index.js";
import { RelationshipRepository, relationshipRepositoryFromEnvironment } from "../../platform/database/relationship-repository.js";
import { EvidenceService, evidenceServiceFromEnvironment } from "../evidence/service.js";
import { TruthService, truthServiceFromEnvironment } from "../truth/service.js";

export interface RelationshipServiceDependencies { repository:RelationshipRepository; evidenceService:EvidenceService; truthService:TruthService; }

export class RelationshipService {
  constructor(private readonly d:RelationshipServiceDependencies){}

  async recordEvidence(command:{relationship:RawRelationshipInput;source:RawSourceInput;acquisition:AcquisitionInput;evidence:Omit<RawEvidenceInput,"subjectType"|"subjectId"|"tenantScopeOrganisationId">;polarity:EvidencePolarity;linkMethod:"DETERMINISTIC"|"AI_EXTRACTED"|"USER_PROVIDED"|"MIGRATED";linkVersion?:string|null;referenceTime?:string}){
    const canonical=canonicaliseRelationship(command.relationship);
    const from=await this.d.repository.ensureNode(canonical.from); const to=await this.d.repository.ensureNode(canonical.to);
    const relation=await this.d.repository.ensureRelationship(canonical,from.node_id,to.node_id);
    const evidence=await this.d.evidenceService.ingest({source:command.source,acquisition:command.acquisition,evidence:{...command.evidence,tenantScopeOrganisationId:canonical.tenantScopeOrganisationId,subjectType:"RELATIONSHIP",subjectId:relation.relationship_id}});
    const link=await this.d.repository.linkEvidence(relation.relationship_id,evidence.evidenceItemId,command.polarity,command.linkMethod,command.linkVersion);
    const truth=await this.d.truthService.evaluateClaim(relation.claim_id,command.referenceTime);
    return {canonical,from,to,relation,evidence,link,truth};
  }

  async evaluateRoutes(command:{organisationId:string;campaignId:string;companyId:string;referenceTime?:string}):Promise<{evaluation:RouteAuthorityEvaluation;persisted:Awaited<ReturnType<RelationshipRepository["persistR5"]>>}>{
    const referenceTime=(command.referenceTime?new Date(command.referenceTime):new Date()).toISOString();
    await this.d.repository.ensureNode(canonicaliseGraphNode({nodeKind:"COMPANY",companyId:command.companyId}));
    const claimMap=await this.d.repository.getUniverseClaimIds(command.organisationId,command.campaignId,command.companyId);
    const snapshotMap:Record<string,string>={};
    for(const [relationshipId,claimId] of Object.entries(claimMap).sort(([a],[b])=>a.localeCompare(b))){
      const truth=await this.d.truthService.evaluateClaim(claimId,referenceTime); snapshotMap[relationshipId]=truth.persisted.snapshotId;
    }
    const context=await this.d.repository.getR5Context({organisationId:command.organisationId,campaignId:command.campaignId,companyId:command.companyId,referenceTime,relationshipTruthSnapshotMap:snapshotMap});
    const evaluation=evaluateRouteAuthority(context); const persisted=await this.d.repository.persistR5(evaluation,snapshotMap); return {evaluation,persisted};
  }
}
export function relationshipServiceFromEnvironment(){return new RelationshipService({repository:relationshipRepositoryFromEnvironment(),evidenceService:evidenceServiceFromEnvironment(),truthService:truthServiceFromEnvironment()});}
