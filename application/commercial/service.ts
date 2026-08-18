import { commercialAccessRepositoryFromEnvironment, type CampaignCapacityRecord, type CommercialAccessRecord, type LockedOpportunityTeaserRecord, type PublicPlanRecord } from "../../platform/database/commercial-access-repository";

export type CommercialAccess=CommercialAccessRecord;
export type LockedOpportunityTeaser=LockedOpportunityTeaserRecord;
export type PublicPlan=PublicPlanRecord;
export type CampaignCapacity=CampaignCapacityRecord;

function nonNegative(value:unknown,fallback=0){const n=Number(value);return Number.isFinite(n)?Math.max(0,n):fallback;}
function text(value:unknown){return typeof value==="string"&&value.trim()?value.trim():null;}
function object(value:unknown):Record<string,unknown>{return value&&typeof value==="object"&&!Array.isArray(value)?value as Record<string,unknown>:{};}

// Public acquisition pages must never become unavailable just because the plan-catalog
// RPC is temporarily unavailable. These values are the frozen launch catalogue and are
// used only as a server-side fail-soft fallback; authenticated entitlement checks still
// fail closed against Supabase.
const PLAN_CODES=["STARTER","GROWTH","SCALE"] as const;
const LAUNCH_PUBLIC_PLANS:ReadonlyArray<PublicPlan>=Object.freeze([
  {planCode:"STARTER",displayName:"Starter",monthlyPriceGbp:99,researchCapacityUnits:100,activeMarketLimit:1,teamSeatLimit:1,metadata:{capacityLabel:"Core research capacity",depthLabel:"Standard research depth",monitoringLabel:"Essential monitoring",marketLabel:"1 active market"}},
  {planCode:"GROWTH",displayName:"Growth",monthlyPriceGbp:249,researchCapacityUnits:400,activeMarketLimit:3,teamSeatLimit:5,metadata:{recommended:true,capacityLabel:"Expanded research capacity",depthLabel:"Deeper company research",monitoringLabel:"Continuous monitoring",marketLabel:"Up to 3 active markets"}},
  {planCode:"SCALE",displayName:"Scale",monthlyPriceGbp:599,researchCapacityUnits:1200,activeMarketLimit:10,teamSeatLimit:15,metadata:{capacityLabel:"Highest research capacity",depthLabel:"Priority research depth",monitoringLabel:"Priority monitoring",marketLabel:"Up to 10 active markets"}},
]);
function launchPlans(){return LAUNCH_PUBLIC_PLANS.map(plan=>({...plan,metadata:{...plan.metadata}}));}
function finiteNumber(value:unknown){return typeof value==="number"&&Number.isFinite(value)?value:null;}
function positiveInteger(value:unknown){const n=finiteNumber(value);return n!==null&&Number.isInteger(n)&&n>=1?n:null;}
function nullableNonNegativeInteger(value:unknown){if(value===null)return null;const n=finiteNumber(value);return n!==null&&Number.isInteger(n)&&n>=0?n:undefined;}
function normalisePlans(rows:unknown):PublicPlan[]|null{
  if(!Array.isArray(rows)||rows.length!==PLAN_CODES.length)return null;
  const byCode=new Map<PublicPlan["planCode"],PublicPlan>();
  for(const raw of rows){
    if(!raw||typeof raw!=="object"||Array.isArray(raw))return null;
    const row=raw as Record<string,unknown>;
    const planCode=String(row.planCode??"") as PublicPlan["planCode"];
    if(!PLAN_CODES.includes(planCode)||byCode.has(planCode))return null;
    const displayName=text(row.displayName);
    const monthlyPriceGbp=finiteNumber(row.monthlyPriceGbp);
    const researchCapacityUnits=nullableNonNegativeInteger(row.researchCapacityUnits);
    const activeMarketLimit=positiveInteger(row.activeMarketLimit);
    const teamSeatLimit=nullableNonNegativeInteger(row.teamSeatLimit);
    if(!displayName||monthlyPriceGbp===null||monthlyPriceGbp<=0||researchCapacityUnits===undefined||activeMarketLimit===null||teamSeatLimit===undefined||!row.metadata||typeof row.metadata!=="object"||Array.isArray(row.metadata))return null;
    byCode.set(planCode,{planCode,displayName,monthlyPriceGbp,researchCapacityUnits,activeMarketLimit,teamSeatLimit,metadata:{...(row.metadata as Record<string,unknown>)}});
  }
  if(PLAN_CODES.some(code=>!byCode.has(code)))return null;
  return PLAN_CODES.map(code=>byCode.get(code)!);
}
function planFallbackLog(reason:"RPC_FAILED"|"INVALID_OR_INCOMPLETE_CATALOG",error?:unknown){
  const errorCode=error instanceof Error?error.message:typeof error==="string"?error:null;
  console.error("MARKETROUTE_PUBLIC_PLAN_CATALOG_FALLBACK",{reason,errorCode,expectedPlanCodes:PLAN_CODES,at:new Date().toISOString()});
}

export class CommercialAccessService {
  private repository(){return commercialAccessRepositoryFromEnvironment();}
  async access(organisationId:string):Promise<CommercialAccess>{
    const value=await this.repository().access(organisationId);
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
    try{
      const plans=normalisePlans(await this.repository().plans());
      if(plans)return plans;
      planFallbackLog("INVALID_OR_INCOMPLETE_CATALOG");
      return launchPlans();
    }catch(error){
      planFallbackLog("RPC_FAILED",error);
      return launchPlans();
    }
  }

  async campaignCapacity(organisationId:string):Promise<CampaignCapacity>{
    const value=await this.repository().campaignCapacity(organisationId);
    const mode=["FULL","PAID","DISCOVERY_FREE","UNENTITLED"].includes(value?.mode)?value.mode:"UNENTITLED";
    return {...value,mode,activeMarketLimit:Math.max(1,nonNegative(value?.activeMarketLimit,1)),activeMarketCount:nonNegative(value?.activeMarketCount),remainingMarkets:nonNegative(value?.remainingMarkets),canCreate:value?.canCreate===true,requiresUpgrade:value?.requiresUpgrade!==false,nextPlanCode:text(value?.nextPlanCode),nextPlanName:text(value?.nextPlanName),nextPlanActiveMarketLimit:value?.nextPlanActiveMarketLimit===null?null:Math.max(1,nonNegative(value?.nextPlanActiveMarketLimit,1))};
  }
  canReadCampaign(access:CommercialAccess,campaignId:string){return access.mode==="FULL"||access.mode==="PAID"||(access.mode==="DISCOVERY_FREE"&&access.campaignId===campaignId);}
  lockedCompany(access:CommercialAccess,campaignId:string,companyId:string){if(access.mode!=="DISCOVERY_FREE"||access.campaignId!==campaignId)return null;return access.lockedOpportunities.find(item=>item.companyId===companyId)??null;}
  canReadOpportunity(access:CommercialAccess,opportunityId:string){return access.mode==="FULL"||access.mode==="PAID"||(access.mode==="DISCOVERY_FREE"&&access.opportunityIds.includes(opportunityId));}
  canReadCompany(access:CommercialAccess,campaignId:string,companyId:string){return access.mode==="FULL"||access.mode==="PAID"||(access.mode==="DISCOVERY_FREE"&&access.campaignId===campaignId&&access.companyIds.includes(companyId));}
}
export function commercialAccessServiceFromEnvironment(){return new CommercialAccessService();}
