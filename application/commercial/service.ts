import { commercialAccessRepositoryFromEnvironment, type CampaignCapacityRecord, type CommercialAccessRecord, type LockedOpportunityTeaserRecord, type PublicPlanRecord } from "../../platform/database/commercial-access-repository";

export type CommercialAccess=CommercialAccessRecord;
export type LockedOpportunityTeaser=LockedOpportunityTeaserRecord;
export type PublicPlan=PublicPlanRecord;
export type CampaignCapacity=CampaignCapacityRecord;

function nonNegative(value:unknown,fallback=0){const n=Number(value);return Number.isFinite(n)?Math.max(0,n):fallback;}
function text(value:unknown){return typeof value==="string"&&value.trim()?value.trim():null;}
function object(value:unknown):Record<string,unknown>{return value&&typeof value==="object"&&!Array.isArray(value)?value as Record<string,unknown>:{};}

export class CommercialAccessService {
  private readonly repository=commercialAccessRepositoryFromEnvironment();
  async access(organisationId:string):Promise<CommercialAccess>{
    const value=await this.repository.access(organisationId);
    const mode=["FULL","PAID","DISCOVERY_FREE","UNENTITLED"].includes(value?.mode)?value.mode:"UNENTITLED";
    const locked=Array.isArray(value?.lockedOpportunities)?value.lockedOpportunities.map((row)=>({
      opportunityId:String(row.opportunityId??""),companyId:String(row.companyId??""),companyName:String(row.companyName??"Opportunity"),
      canonicalDomain:text(row.canonicalDomain),discoveredAt:String(row.discoveredAt??""),state:"READY_LOCKED" as const,
    })).filter(row=>row.opportunityId&&row.companyId):[];
    const capacity=object(value?.researchCapacity);
    return {...value,mode,freeLimit:nonNegative(value?.freeLimit,8),lockedCount:nonNegative(value?.lockedCount,locked.length),lockedOpportunities:locked,
      opportunityIds:Array.isArray(value?.opportunityIds)?value.opportunityIds.map(String):[],companyIds:Array.isArray(value?.companyIds)?value.companyIds.map(String):[],
      researchCapacity:{limitUnits:capacity.limitUnits===null?null:nonNegative(capacity.limitUnits),usedUnits:nonNegative(capacity.usedUnits),reservedUnits:nonNegative(capacity.reservedUnits),remainingUnits:capacity.remainingUnits===null?null:nonNegative(capacity.remainingUnits),periodStart:text(capacity.periodStart),periodEnd:text(capacity.periodEnd)}};
  }
  async plans():Promise<PublicPlan[]>{
    const rows=await this.repository.plans();
    return (Array.isArray(rows)?rows:[]).filter(row=>["STARTER","GROWTH","SCALE"].includes(row.planCode)).map(row=>({...row,monthlyPriceGbp:nonNegative(row.monthlyPriceGbp),researchCapacityUnits:row.researchCapacityUnits===null?null:nonNegative(row.researchCapacityUnits),activeMarketLimit:Math.max(1,nonNegative(row.activeMarketLimit,1)),teamSeatLimit:row.teamSeatLimit===null?null:Math.max(1,nonNegative(row.teamSeatLimit,1)),metadata:object(row.metadata)}));
  }

  async campaignCapacity(organisationId:string):Promise<CampaignCapacity>{
    const value=await this.repository.campaignCapacity(organisationId);
    const mode=["FULL","PAID","DISCOVERY_FREE","UNENTITLED"].includes(value?.mode)?value.mode:"UNENTITLED";
    return {...value,mode,activeMarketLimit:Math.max(1,nonNegative(value?.activeMarketLimit,1)),activeMarketCount:nonNegative(value?.activeMarketCount),remainingMarkets:nonNegative(value?.remainingMarkets),canCreate:value?.canCreate===true,requiresUpgrade:value?.requiresUpgrade!==false,nextPlanCode:text(value?.nextPlanCode),nextPlanName:text(value?.nextPlanName),nextPlanActiveMarketLimit:value?.nextPlanActiveMarketLimit===null?null:Math.max(1,nonNegative(value?.nextPlanActiveMarketLimit,1))};
  }
  lockedCompany(access:CommercialAccess,companyId:string){return access.lockedOpportunities.find(item=>item.companyId===companyId)??null;}
  canReadOpportunity(access:CommercialAccess,opportunityId:string){return access.mode==="FULL"||access.mode==="PAID"||(access.mode==="DISCOVERY_FREE"&&access.opportunityIds.includes(opportunityId));}
  canReadCompany(access:CommercialAccess,companyId:string){return access.mode==="FULL"||access.mode==="PAID"||(access.mode==="DISCOVERY_FREE"&&access.companyIds.includes(companyId));}
}
export function commercialAccessServiceFromEnvironment(){return new CommercialAccessService();}
