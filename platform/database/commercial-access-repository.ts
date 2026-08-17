import { PostgrestRpcClient, databaseConfigFromEnvironment } from "./postgrest-rpc";

export interface LockedOpportunityTeaserRecord {
  opportunityId:string;
  companyId:string;
  companyName:string;
  canonicalDomain:string|null;
  discoveredAt:string;
  state:"READY_LOCKED";
}
export interface ResearchCapacityRecord {
  limitUnits:number|null;
  usedUnits:number;
  reservedUnits?:number;
  remainingUnits:number|null;
  periodStart:string|null;
  periodEnd:string|null;
}
export interface CommercialAccessRecord {
  mode:"FULL"|"PAID"|"DISCOVERY_FREE"|"UNENTITLED";
  planCode:string|null;
  planName:string|null;
  campaignId:string|null;
  freeLimit:number;
  unlockedCount:number|null;
  lockedCount:number;
  opportunityIds:string[];
  companyIds:string[];
  lockedOpportunities:LockedOpportunityTeaserRecord[];
  researchCapacity:ResearchCapacityRecord;
}
export interface PublicPlanRecord {
  planCode:"STARTER"|"GROWTH"|"SCALE";
  displayName:string;
  monthlyPriceGbp:number;
  researchCapacityUnits:number|null;
  activeMarketLimit:number;
  teamSeatLimit:number|null;
  metadata:Record<string,unknown>;
}

export class CommercialAccessRepository {
  constructor(private readonly rpc=new PostgrestRpcClient(databaseConfigFromEnvironment())){}
  access(organisationId:string){return this.rpc.call<CommercialAccessRecord>("marketroute_workspace_commercial_access_v1",{p_organisation_id:organisationId});}
  plans(){return this.rpc.call<PublicPlanRecord[]>("marketroute_public_plan_catalog_v1",{});}
}
export function commercialAccessRepositoryFromEnvironment(){return new CommercialAccessRepository();}
