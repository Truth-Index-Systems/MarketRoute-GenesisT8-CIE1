import { AuthorityLifecycleRepository, authorityLifecycleRepositoryFromEnvironment, type AuthorityEnvelope } from "../../platform/database/authority-lifecycle-repository";

export class OpportunityLifecycleService {
  constructor(private readonly repository:AuthorityLifecycleRepository){}
  static fromEnvironment(){return new OpportunityLifecycleService(authorityLifecycleRepositoryFromEnvironment());}
  getAuthorityEnvelope(input:{organisationId:string;campaignId:string;companyId:string;at?:string}):Promise<AuthorityEnvelope>{
    return this.repository.getEnvelope({...input,at:input.at??new Date().toISOString()});
  }
  review(input:{opportunityId:string;reviewerUserId:string;decision:"APPROVE"|"REJECT"|"RETURN_TO_RESEARCH";note?:string|null;requestId:string;reviewedAt?:string}){
    return this.repository.recordReview({...input,reviewedAt:input.reviewedAt??new Date().toISOString()});
  }
  isExecutableNow(opportunityId:string,at?:string){return this.repository.isOpportunityExecutableNow(opportunityId,at??new Date().toISOString());}
}
