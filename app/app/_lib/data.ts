import { applicationReadServiceFromEnvironment } from "@/application/read-model/service";
import type { CommandCentreReadModel } from "@/application/read-model/contracts";
import { asObject, asObjectArray, text } from "@/application/read-model/presentation";

export async function commandCentre(organisationId:string){return applicationReadServiceFromEnvironment().commandCentre({organisationId});}
export function resolveCampaignId(model:CommandCentreReadModel,requested?:string|null):string|null{
  const campaigns=asObjectArray(model.campaigns); if(requested&&campaigns.some((item)=>text(asObject(item.campaign).campaignId,"")===requested))return requested;
  const active=campaigns.find((item)=>text(asObject(item.campaign).workflowState,"")==="ACTIVE");
  return text(asObject((active??campaigns[0]??{}).campaign).campaignId,"")||null;
}
