import { canonicaliseContactClaim, evaluateContactAuthority, type RawContactClaimInput } from "../../core/contacts/index.js";
import type { AcquisitionInput, EvidencePolarity, RawEvidenceInput, RawSourceInput } from "../../core/evidence/index.js";
import { ContactAuthorityRepository, contactAuthorityRepositoryFromEnvironment } from "../../platform/database/contact-authority-repository.js";
import { EvidenceService, evidenceServiceFromEnvironment } from "../evidence/service.js";
import { TruthService, truthServiceFromEnvironment } from "../truth/service.js";

export class ContactAuthorityService {
  constructor(private readonly repository:ContactAuthorityRepository,private readonly evidence:EvidenceService,private readonly truth:TruthService){}
  async recordEvidence(command:{claim:RawContactClaimInput;source:RawSourceInput;acquisition:AcquisitionInput;evidence:Omit<RawEvidenceInput,"tenantScopeOrganisationId"|"subjectType"|"subjectId">;polarity:EvidencePolarity;linkMethod:"DETERMINISTIC"|"AI_EXTRACTED"|"USER_PROVIDED"|"MIGRATED";linkVersion?:string|null;referenceTime?:string}){
    const claim=canonicaliseContactClaim(command.claim);
    const ingested=await this.evidence.ingest({source:command.source,acquisition:command.acquisition,evidence:{...command.evidence,tenantScopeOrganisationId:claim.tenantScopeOrganisationId,subjectType:claim.subjectType,subjectId:claim.subjectId}});
    const linked=await this.evidence.recordClaimEvidence({claim:{tenantScopeOrganisationId:claim.tenantScopeOrganisationId,subjectType:claim.subjectType,subjectId:claim.subjectId,claimKey:claim.claimKey,predicate:claim.predicate,object:claim.object,canonicalValueText:claim.canonicalValueText},evidenceItemId:ingested.evidenceItemId,polarity:command.polarity,linkMethod:command.linkMethod,linkVersion:command.linkVersion});
    const evaluated=await this.truth.evaluateClaim(linked.claimId,command.referenceTime);
    return {claim,ingested,linked,evaluated};
  }
  async evaluate(command:{organisationId:string;campaignId:string;companyId:string;referenceTime?:string}){
    const referenceTime=(command.referenceTime?new Date(command.referenceTime):new Date()).toISOString();
    const claimIds=await this.repository.getClaimIds({...command,referenceTime});
    const snapshotMap:Record<string,string>={};
    for(const claimId of Object.keys(claimIds).sort()){
      const truth=await this.truth.evaluateClaim(claimId,referenceTime);snapshotMap[claimId]=truth.persisted.snapshotId;
    }
    const context=await this.repository.getContext({...command,referenceTime,claimTruthSnapshotMap:snapshotMap});
    const evaluation=evaluateContactAuthority(context);
    const persisted=await this.repository.persist(evaluation,snapshotMap);
    return {evaluation,persisted};
  }
}
export function contactAuthorityServiceFromEnvironment(){return new ContactAuthorityService(contactAuthorityRepositoryFromEnvironment(),evidenceServiceFromEnvironment(),truthServiceFromEnvironment());}
