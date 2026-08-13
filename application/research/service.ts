import { planResearch } from "../../core/research/index.js";
import { ResearchRepository, researchRepositoryFromEnvironment } from "../../platform/database/research-repository.js";

export class ResearchPlanningService {
  constructor(private readonly repository:ResearchRepository){}
  async planCompany(command:{organisationId:string;campaignId:string;companyId:string;referenceTime?:string}){
    const referenceTime=(command.referenceTime?new Date(command.referenceTime):new Date()).toISOString();
    const context=await this.repository.getContext(command.organisationId,command.campaignId,command.companyId,referenceTime);
    const plan=planResearch(context);
    const persisted=await this.repository.persistPlan(context,plan);
    return {context,plan,persisted};
  }
}
export function researchPlanningServiceFromEnvironment(){return new ResearchPlanningService(researchRepositoryFromEnvironment());}
