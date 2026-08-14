import { PostgrestRpcClient,databaseConfigFromEnvironment } from "./postgrest-rpc";

export type JsonObject=Record<string,unknown>;
export interface FounderDashboardSnapshot extends JsonObject{
  generatedAt:string;
  schemaRelease:JsonObject;
  runtime:JsonObject;
  platform:JsonObject;
  growth:JsonObject;
  activation:JsonObject;
  discovery:JsonObject;
  research:JsonObject;
  evidence:JsonObject;
  truth:JsonObject;
  r4:JsonObject;
  r5:JsonObject;
  r6:JsonObject;
  opportunity:JsonObject;
  engagement:JsonObject;
  ai:JsonObject;
}

export class FounderDashboardRepository{
  constructor(private readonly rpc=new PostgrestRpcClient(databaseConfigFromEnvironment())){}
  snapshot(at=new Date().toISOString()){
    return this.rpc.call<FounderDashboardSnapshot>("marketroute_founder_dashboard_snapshot_v1",{p_at:at});
  }
}
export function founderDashboardRepositoryFromEnvironment(){return new FounderDashboardRepository();}
