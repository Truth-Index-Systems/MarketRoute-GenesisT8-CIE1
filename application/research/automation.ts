import type { ResearchProvider } from "../../core/research/index";
import { ResearchRepository, researchRepositoryFromEnvironment } from "../../platform/database/research-repository";
import { evidenceServiceFromEnvironment } from "../evidence/service";
import { relationshipServiceFromEnvironment } from "../relationships/service";
import { contactAuthorityServiceFromEnvironment } from "../contacts/service";
import { commercialRealityServiceFromEnvironment } from "../commercial-reality/service";
import { ResearchPlanningService } from "./service";
import { ResearchWorker } from "./worker";
import { OpportunityService, opportunityServiceFromEnvironment } from "../opportunities/opportunity-service";
import { ResearchPlanningAutomationService } from "./planning-automation";

export class ResearchAutomationService {
  private readonly planningAutomation:ResearchPlanningAutomationService;
  constructor(private readonly repository:ResearchRepository,planner:ResearchPlanningService,private readonly worker:ResearchWorker,private readonly opportunities:OpportunityService){this.planningAutomation=new ResearchPlanningAutomationService(repository,planner);}
  async runCycle(command:{maxPlanningTargets?:number;maxWorkExecutions?:number;referenceTime?:string}={}){
    const at=(command.referenceTime?new Date(command.referenceTime):new Date()).toISOString();
    const maxPlanning=Math.max(0,Math.min(command.maxPlanningTargets??100,1000));const maxExec=Math.max(0,Math.min(command.maxWorkExecutions??20,100));
    const planning=await this.planningAutomation.runCycle({maxPlanningTargets:maxPlanning,referenceTime:command.referenceTime?at:undefined});
    if(maxExec===0){const opportunitySync=await this.opportunities.syncCurrentTargets(Math.max(1,Math.min(maxPlanning,250)));return{runId:null,status:opportunitySync.errors.length?"PARTIAL" as const:"SUCCEEDED" as const,planningTargets:planning.planningTargets,plannedWorkUnits:planning.plannedWorkUnits,executedWorkUnits:0,emptyPlans:planning.emptyPlans,queueDiagnostics:null,opportunitySyncCount:opportunitySync.results.length,opportunitySyncErrors:opportunitySync.errors,workersRequired:false as const};}
    const runId=await this.repository.startRun("GENESIS_RESEARCH_V1",at);let executed=0;
    try{
      for(let i=0;i<maxExec;i++){await this.repository.heartbeatRun(runId,new Date().toISOString());const result=await this.worker.runOne(runId);if(!result)break;executed++;}
      const queueDiagnostics=executed===0?await this.repository.queueDiagnostics(new Date().toISOString()).catch(error=>({diagnosticError:error instanceof Error?error.message:"UNKNOWN"})):null;
      const opportunitySync=await this.opportunities.syncCurrentTargets(Math.max(1,Math.min(maxPlanning,250)));
      const finalStatus=opportunitySync.errors.length?"PARTIAL":"SUCCEEDED";
      await this.repository.finishRun(runId,finalStatus,{planningTargets:planning.planningTargets,plannedWorkUnits:planning.plannedWorkUnits,executedWorkUnits:executed,emptyPlans:planning.emptyPlans,queueDiagnostics,opportunitySyncCount:opportunitySync.results.length,opportunitySyncErrors:opportunitySync.errors},new Date().toISOString());
      return {runId,status:finalStatus,planningTargets:planning.planningTargets,plannedWorkUnits:planning.plannedWorkUnits,executedWorkUnits:executed,emptyPlans:planning.emptyPlans,queueDiagnostics,opportunitySyncCount:opportunitySync.results.length,opportunitySyncErrors:opportunitySync.errors};
    }catch(error){await this.repository.finishRun(runId,"FAILED",{plannedWorkUnits:planning.plannedWorkUnits,executedWorkUnits:executed,error:error instanceof Error?error.message:"UNKNOWN"},new Date().toISOString()).catch(()=>undefined);throw error;}
  }
}
export function researchAutomationServiceFromEnvironment(provider:ResearchProvider){
  const repository=researchRepositoryFromEnvironment();const planner=new ResearchPlanningService(repository);
  const worker=new ResearchWorker({repository,provider,evidence:evidenceServiceFromEnvironment(),relationships:relationshipServiceFromEnvironment(),contacts:contactAuthorityServiceFromEnvironment(),r4:commercialRealityServiceFromEnvironment()});
  return new ResearchAutomationService(repository,planner,worker,opportunityServiceFromEnvironment());
}
