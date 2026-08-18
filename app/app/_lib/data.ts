import { applicationReadServiceFromEnvironment } from "@/application/read-model/service";
import type { CampaignReadModel, CommandCentreReadModel, OpportunityIndexReadModel } from "@/application/read-model/contracts";
import { asObject, asObjectArray, text } from "@/application/read-model/presentation";

export async function commandCentre(organisationId:string){return applicationReadServiceFromEnvironment().commandCentre({organisationId});}
export function resolveCampaignId(model:CommandCentreReadModel,requested?:string|null):string|null{
  const campaigns=asObjectArray(model.campaigns); if(requested&&campaigns.some((item)=>text(asObject(item.campaign).campaignId,"")===requested))return requested;
  const active=campaigns.find((item)=>text(asObject(item.campaign).workflowState,"")==="ACTIVE");
  return text(asObject((active??campaigns[0]??{}).campaign).campaignId,"")||null;
}

export function campaignOverviewFromSummary(model:CommandCentreReadModel,campaignId:string,index:OpportunityIndexReadModel):CampaignReadModel|null{
  const row=asObjectArray(model.campaigns).find(item=>text(asObject(item.campaign).campaignId,"")===campaignId);
  if(!row)return null;
  const sellerValue=row.seller;
  const policy=text(row.engagementPolicy,"HUMAN_ONLY")==="AUTOPILOT"?"AUTOPILOT":"HUMAN_ONLY";
  return {
    contractVersion:model.contractVersion,resourceType:"CAMPAIGN",evaluatedAt:index.evaluatedAt,
    campaign:asObject(row.campaign),seller:sellerValue&&typeof sellerValue==="object"&&!Array.isArray(sellerValue)?asObject(sellerValue):null,
    sellerContext:null,metrics:asObject(row.metrics),research:asObject(row.research),engagementPolicy:policy,
    opportunities:index.opportunities
  };
}
