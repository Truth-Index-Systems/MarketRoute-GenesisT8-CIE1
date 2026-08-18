import type { ResearchProvider } from "../../core/research/index";
import { ResearchRepository, researchRepositoryFromEnvironment } from "../../platform/database/research-repository";
import { evidenceServiceFromEnvironment } from "../evidence/service";
import { relationshipServiceFromEnvironment } from "../relationships/service";
import { contactAuthorityServiceFromEnvironment } from "../contacts/service";
import { commercialRealityServiceFromEnvironment } from "../commercial-reality/service";
import { ResearchPlanningService } from "./service";
import { ResearchWorker } from "./worker";
import { OpportunityService, opportunityServiceFromEnvironment } from "../opportunities/opportunity-service";

export class ResearchAutomationService {
  constructor(private readonly repository:ResearchRepository,private readonly planner:ResearchPlanningService,private readonly worker:ResearchWorker,private readonly opportunities:OpportunityService){}
  async runCycle(command:{maxPlanningTargets?:number;maxWorkExecutions?:number;referenceTime?:string}={}){
    const at=(command.referenceTime?new Date(command.referenceTime):new Date()).toISOString();
    const maxPlanning=Math.max(0,Math.min(command.maxPlanningTargets??100,1000));const maxExec=Math.max(0,Math.min(command.maxWorkExecutions??20,100));
    const runId=await this.repository.startRun("GENESIS_RESEARCH_V1",at);let planned=0,executed=0,emptyPlans=0;
    try{
      const targets=await this.repository.planningTargets(maxPlanning);
      for(let i=0;i<targets.length;i++){if(i%25===0)await this.repository.heartbeatRun(runId,new Date().toISOString());const target=targets[i]!;const result=await this.planner.planCompany({organisationId:target.organisation_id,campaignId:target.campaign_id,companyId:target.company_id,referenceTime:command.referenceTime?at:new Date().toISOString()});planned+=result.persisted.createdWorkUnits; if(result.plan.workUnits.length===0)emptyPlans++;}
      for(let i=0;i<maxExec;i++){await this.repository.heartbeatRun(runId,new Date().toISOString());const result=await this.worker.runOne(runId);if(!result)break;executed++;}
      const queueDiagnostics=executed===0?await this.repository.queueDiagnostics(new Date().toISOString()).catch(error=>({diagnosticError:error instanceof Error?error.message:"UNKNOWN"})):null;
      const opportunitySync=await this.opportunities.syncCurrentTargets(Math.max(1,Math.min(maxPlanning,250)));
      const finalStatus=opportunitySync.errors.length?"PARTIAL":"SUCCEEDED";
      await this.repository.finishRun(runId,finalStatus,{planningTargets:targets.length,plannedWorkUnits:planned,executedWorkUnits:executed,emptyPlans,queueDiagnostics,opportunitySyncCount:opportunitySync.results.length,opportunitySyncErrors:opportunitySync.errors},new Date().toISOString());
      return {runId,status:finalStatus,planningTargets:targets.length,plannedWorkUnits:planned,executedWorkUnits:executed,emptyPlans,queueDiagnostics,opportunitySyncCount:opportunitySync.results.length,opportunitySyncErrors:opportunitySync.errors};
    }catch(error){await this.repository.finishRun(runId,"FAILED",{plannedWorkUnits:planned,executedWorkUnits:executed,error:error instanceof Error?error.message:"UNKNOWN"},new Date().toISOString()).catch(()=>undefined);throw error;}
  }
}
export function researchAutomationServiceFromEnvironment(provider:ResearchProvider){
  const repository=researchRepositoryFromEnvironment();const planner=new ResearchPlanningService(repository);
  const worker=new ResearchWorker({repository,provider,evidence:evidenceServiceFromEnvironment(),relationships:relationshipServiceFromEnvironment(),contacts:contactAuthorityServiceFromEnvironment(),r4:commercialRealityServiceFromEnvironment()});
  return new ResearchAutomationService(repository,planner,worker,opportunityServiceFromEnvironment());
}
