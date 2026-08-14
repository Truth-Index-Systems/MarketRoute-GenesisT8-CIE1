import { PostgrestRpcClient,databaseConfigFromEnvironment } from "./postgrest-rpc";

export type GrowthPhase="SEED"|"BREADTH"|"DEPTH"|"REFRESH";
export type GrowthActionKind="DISCOVER_COMPANIES"|"RESEARCH_CORE_PROFILE"|"RESEARCH_ROUTES"|"RESEARCH_CONTACTS"|"REFRESH_CORE";
export interface GrowthAction{state:"ACTION";actionRunId:string;phase:GrowthPhase;actionKind:GrowthActionKind;industryKey:string|null;companyId:string|null;maxActionCostUsd:number;discoveryBatchSize:number;retryHours:number}
export interface GrowthBudgetExhausted{state:"BUDGET_EXHAUSTED";spentTodayUsd:number;dailyBudgetUsd:number}
export interface GrowthCompany{id:string;name:string;canonicalDomain:string|null;websiteUrl:string|null;countryCode:string|null}

function one<T>(v:T[]|T,code:string):T{if(Array.isArray(v)){if(v.length!==1)throw new Error(`${code}:${v.length}`);return v[0]!;}if(!v)throw new Error(`${code}:0`);return v;}
export class GenesisGrowthRepository{
 constructor(private readonly rpc=new PostgrestRpcClient(databaseConfigFromEnvironment())){}
 syncSettings(v:{enabled:boolean;seedTarget:number;launchTarget:number;dailyBudgetUsd:number;maxActionCostUsd:number;discoveryBatch:number;maxActions:number;retryHours:number;refreshDays:number}){return this.rpc.call<void>("marketroute_sync_growth_settings_v1",{p_enabled:v.enabled,p_seed_target:v.seedTarget,p_launch_target:v.launchTarget,p_daily_budget:v.dailyBudgetUsd,p_max_action_cost:v.maxActionCostUsd,p_discovery_batch:v.discoveryBatch,p_max_actions:v.maxActions,p_retry_hours:v.retryHours,p_refresh_days:v.refreshDays});}
 start(at:string){return this.rpc.call<string>("marketroute_start_growth_scheduler_run_v1",{p_at:at});}
 heartbeat(runId:string,at:string){return this.rpc.call<void>("marketroute_heartbeat_growth_scheduler_run_v1",{p_scheduler_run_id:runId,p_at:at});}
 finish(runId:string,status:"SUCCEEDED"|"PARTIAL"|"FAILED"|"CANCELLED",metadata:Record<string,unknown>,at:string){return this.rpc.call<void>("marketroute_finish_growth_scheduler_run_v1",{p_scheduler_run_id:runId,p_status:status,p_metadata:metadata,p_at:at});}
 nextAction(runId:string,at:string){return this.rpc.call<GrowthAction|GrowthBudgetExhausted|null>("marketroute_growth_next_action_v1",{p_scheduler_run_id:runId,p_at:at});}
 existingDomains(industryKey:string,limit=1000){return this.rpc.call<string[]>("marketroute_growth_existing_domains_v1",{p_industry_key:industryKey,p_limit:limit});}
 ensureCompany(input:{industryKey:string;name:string;domain:string;websiteUrl:string;countryCode:string|null;discoveryReason:string}){return this.rpc.call<string>("marketroute_growth_ensure_company_v1",{p_industry_key:input.industryKey,p_name:input.name,p_domain:input.domain,p_website_url:input.websiteUrl,p_country_code:input.countryCode,p_discovery_reason:input.discoveryReason});}
 ensurePerson(companyId:string,name:string){return this.rpc.call<string>("marketroute_growth_ensure_person_v1",{p_company_id:companyId,p_name:name});}
 markStage(companyId:string,stage:"CORE"|"PROFILE"|"ROUTES"|"CONTACTS",complete:boolean,errorCode:string|null,retryAfter:string|null,at:string){return this.rpc.call<void>("marketroute_growth_mark_stage_v1",{p_company_id:companyId,p_stage:stage,p_complete:complete,p_error_code:errorCode,p_retry_after:retryAfter,p_at:at});}
 complete(actionRunId:string,costUsd:number,result:Record<string,unknown>,at:string){return this.rpc.call<void>("marketroute_growth_complete_action_v1",{p_action_run_id:actionRunId,p_actual_cost_usd:costUsd,p_result:result,p_at:at});}
 fail(actionRunId:string,errorCode:string,costUsd:number,retryAfter:string|null,at:string){return this.rpc.call<void>("marketroute_growth_fail_action_v1",{p_action_run_id:actionRunId,p_error_code:errorCode,p_actual_cost_usd:costUsd,p_retry_after:retryAfter,p_at:at});}
}
export function genesisGrowthRepositoryFromEnvironment(){return new GenesisGrowthRepository();}
