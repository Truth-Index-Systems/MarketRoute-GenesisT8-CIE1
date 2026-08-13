import type { ResearchPlan, ResearchPlannerContext } from "../../core/research/index.js";
import { PostgrestRpcClient, databaseConfigFromEnvironment } from "./postgrest-rpc.js";

export interface PersistedResearchPlan { planId:string; createdWorkUnits:number; planFingerprint:string; deduplicated:boolean; }
export interface ClaimedResearchWork {
  workUnitId:string; jobId:string; planId:string; organisationId:string; campaignId:string; companyId:string;
  gapKey:string; layer:"R4"|"R5"|"R6"; tier:"DECISION_BLOCKER"|"CURRENTNESS_REPAIR"|"EXPIRING_SOON"|"ENRICHMENT"; action:"ACQUIRE_CLAIM_EVIDENCE"|"DISCOVER_ROUTE_STRUCTURE"|"RESEARCH_CONTACT_BINDING"|"REVALIDATE_R4"|"REVALIDATE_R5"|"REVALIDATE_R6"; subjectType:"COMPANY"|"PERSON"|"RELATIONSHIP"|"CHANNEL"|"CAMPAIGN"; subjectId:string; claimKey:string|null;
  reasonCode:string; queryHints:string[]; payload:Record<string,unknown>; costCeilingUsd:number; attemptNumber:number;
}
interface PersistRow {plan_id:string;created_work_units:number;plan_fingerprint:string;deduplicated:boolean}
function one<T>(v:T[]|T):T{if(Array.isArray(v)){if(v.length!==1)throw new Error(`MARKETROUTE_RESEARCH_PERSIST_ROW_COUNT:${v.length}`);return v[0]!}return v}

export class ResearchRepository {
  constructor(private readonly rpc:PostgrestRpcClient){}
  static fromEnvironment(){return new ResearchRepository(new PostgrestRpcClient(databaseConfigFromEnvironment()));}
  getContext(organisationId:string,campaignId:string,companyId:string,referenceTime:string):Promise<ResearchPlannerContext>{return this.rpc.call("marketroute_research_gap_context_v1",{p_organisation_id:organisationId,p_campaign_id:campaignId,p_company_id:companyId,p_at:referenceTime});}
  async persistPlan(context:ResearchPlannerContext,plan:ResearchPlan):Promise<PersistedResearchPlan>{
    const raw=await this.rpc.call<PersistRow[]|PersistRow>("marketroute_persist_research_plan_v1",{p_context:context,p_planner_version:plan.plannerVersion,p_semantics_version:plan.semanticsVersion,p_gap_set_fingerprint:plan.gapSetFingerprint,p_work_units:plan.workUnits});const r=one(raw);return{planId:r.plan_id,createdWorkUnits:r.created_work_units,planFingerprint:r.plan_fingerprint,deduplicated:r.deduplicated};
  }
  planningTargets(limit=100):Promise<Array<{organisation_id:string;campaign_id:string;company_id:string}>>{return this.rpc.call("marketroute_research_planning_targets_v1",{p_limit:limit});}
  startRun(runnerKey:string,at:string):Promise<string>{return this.rpc.call("marketroute_start_research_scheduler_run_v1",{p_runner_key:runnerKey,p_at:at});}
  heartbeatRun(schedulerRunId:string,at:string):Promise<void>{return this.rpc.call("marketroute_heartbeat_research_scheduler_run_v1",{p_scheduler_run_id:schedulerRunId,p_at:at});}
  finishRun(schedulerRunId:string,status:"SUCCEEDED"|"PARTIAL"|"FAILED"|"CANCELLED",metadata:Record<string,unknown>,at:string):Promise<void>{return this.rpc.call("marketroute_finish_research_scheduler_run_v1",{p_scheduler_run_id:schedulerRunId,p_status:status,p_metadata:metadata,p_at:at});}
  claimNext(schedulerRunId:string,at:string):Promise<ClaimedResearchWork|null>{return this.rpc.call("marketroute_claim_research_work_v1",{p_scheduler_run_id:schedulerRunId,p_at:at});}
  complete(workUnitId:string,schedulerRunId:string,actualCostUsd:number,metadata:Record<string,unknown>,at:string):Promise<void>{return this.rpc.call("marketroute_complete_research_work_v1",{p_work_unit_id:workUnitId,p_scheduler_run_id:schedulerRunId,p_actual_cost_usd:actualCostUsd,p_metadata:metadata,p_at:at});}
  fail(workUnitId:string,schedulerRunId:string,errorCode:string,actualCostUsd:number,retryable:boolean,at:string):Promise<void>{return this.rpc.call("marketroute_fail_research_work_v1",{p_work_unit_id:workUnitId,p_scheduler_run_id:schedulerRunId,p_error_code:errorCode,p_actual_cost_usd:actualCostUsd,p_retryable:retryable,p_at:at});}
}
export function researchRepositoryFromEnvironment(){return ResearchRepository.fromEnvironment();}
