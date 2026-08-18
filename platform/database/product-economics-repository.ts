import { PostgrestRpcClient,databaseConfigFromEnvironment } from "./postgrest-rpc";

export interface ProductEconomicsSnapshot{
  generatedAt:string;anonymousRuns:number;claimedRuns:number;claimRatePct:number;checkoutAttempts:number;checkoutCompleted:number;checkoutCompletionPct:number;
  activePaidWorkspaces:number;mrrGbp:number;activePlanCounts:Record<string,number>;anonymousAiSpendUsd:number;averageAnonymousRunCostUsd:number;aiSpend30dUsd:number;paidWorkspaceAiSpend30dUsd:number;
}
export class ProductEconomicsRepository{
  constructor(private readonly rpc=new PostgrestRpcClient(databaseConfigFromEnvironment())){}
  snapshot(at=new Date().toISOString()){return this.rpc.call<ProductEconomicsSnapshot>("marketroute_product_economics_snapshot_v1",{p_at:at});}
}
export function productEconomicsRepositoryFromEnvironment(){return new ProductEconomicsRepository();}
