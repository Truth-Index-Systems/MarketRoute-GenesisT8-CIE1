import { PostgrestRpcClient,databaseConfigFromEnvironment } from "./postgrest-rpc";

export type RuntimeKind="BOOTSTRAP"|"GROWTH"|"RESEARCH"|"DELIVERY"|"PREFLIGHT"|"SMOKE";
export type RuntimeEventType="STARTED"|"SUCCEEDED"|"FAILED"|"DISABLED";

export interface RuntimeEventInput{
  correlationId:string;
  runtimeKind:RuntimeKind;
  eventType:RuntimeEventType;
  durationMs?:number|null;
  errorCode?:string|null;
  metadata?:Record<string,unknown>;
  at?:string;
}

export class ProductionObservabilityRepository{
  constructor(private readonly rpc=new PostgrestRpcClient(databaseConfigFromEnvironment())){}
  record(input:RuntimeEventInput){
    return this.rpc.call<string>("marketroute_record_runtime_event_v1",{
      p_correlation_id:input.correlationId,
      p_runtime_kind:input.runtimeKind,
      p_event_type:input.eventType,
      p_duration_ms:input.durationMs??null,
      p_error_code:input.errorCode??null,
      p_metadata_json:input.metadata??{},
      p_at:input.at??new Date().toISOString(),
    });
  }
}
export function productionObservabilityRepositoryFromEnvironment(){return new ProductionObservabilityRepository();}
