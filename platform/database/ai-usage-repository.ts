import { PostgrestRpcClient,databaseConfigFromEnvironment } from "./postgrest-rpc";

export interface AIUsageRecordInput{
  organisationId?:string|null;
  campaignId?:string|null;
  provider:string;
  model:string;
  requestKind:string;
  inputTokens:number;
  outputTokens:number;
  costUsd:number;
  latencyMs:number;
  status:"SUCCEEDED"|"FAILED"|"TIMED_OUT"|"CANCELLED";
  metadata?:Record<string,unknown>;
}
export class AIUsageRepository{
  constructor(private readonly rpc=new PostgrestRpcClient(databaseConfigFromEnvironment())){}
  record(input:AIUsageRecordInput){return this.rpc.call<string>("marketroute_record_ai_usage_v1",{
    p_organisation_id:input.organisationId??null,p_campaign_id:input.campaignId??null,p_provider:input.provider,p_model:input.model,p_request_kind:input.requestKind,p_input_tokens:Math.max(0,Math.floor(input.inputTokens)),p_output_tokens:Math.max(0,Math.floor(input.outputTokens)),p_cost_usd:Math.max(0,input.costUsd),p_latency_ms:Math.max(0,Math.floor(input.latencyMs)),p_status:input.status,p_metadata_json:input.metadata??{}
  });}
}
export function aiUsageRepositoryFromEnvironment(){return new AIUsageRepository();}
