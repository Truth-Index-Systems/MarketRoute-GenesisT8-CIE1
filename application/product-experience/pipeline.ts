import type { CampaignReadModel } from "../read-model/contracts";
import type { WorkspaceActivationStatus } from "../session/service";
import { asObject,asObjectArray,numberValue,text } from "../read-model/presentation";

export type ProductPipelineStatus="COMPLETE"|"ACTIVE"|"WAITING"|"ATTENTION";
export interface ProductPipelineStage{key:"UNDERSTAND"|"MAP"|"DISCOVER"|"RESEARCH"|"EVALUATE"|"ROUTE"|"READY";label:string;detail:string;status:ProductPipelineStatus;value:string;href:string;}

function activationComplete(activation:WorkspaceActivationStatus,minimum:number){return activation.status==="SUCCEEDED"||activation.status==="NOT_REQUIRED"||activation.progress>=minimum;}
function status(done:boolean,active:boolean,attention=false):ProductPipelineStatus{if(attention)return"ATTENTION";if(done)return"COMPLETE";if(active)return"ACTIVE";return"WAITING";}

export function productPipeline(input:{activation:WorkspaceActivationStatus;campaign:CampaignReadModel|null}):ProductPipelineStage[]{
  const {activation,campaign}=input;const metrics=asObject(campaign?.metrics),profiles=asObjectArray(campaign?.opportunities);
  const scoped=numberValue(metrics.scopedCompanies),opps=numberValue(metrics.materialisedOpportunities);
  const researched=profiles.filter(p=>{const t=asObject(p.truth);return numberValue(t.truthIndex)>0||text(p.lifecycleState,"")!=="UNRESOLVED";}).length;
  const evaluated=profiles.filter(p=>["ACTIONABLE","RESEARCH_REQUIRED","REVALIDATION_REQUIRED","NOT_ADMISSIBLE"].includes(text(p.disposition,""))).length;
  const routed=profiles.filter(p=>numberValue(p.structurallyOpenAccessPointCount)>0).length;
  const ready=profiles.filter(p=>p.executableNow===true).length;
  const activationAttention=activation.status==="FAILED"||activation.status==="NEEDS_INPUT";
  const understandDone=activationComplete(activation,35),mapDone=activationComplete(activation,55),discoverDone=scoped>0||activationComplete(activation,96);
  const researchDone=researched>0,evalDone=opps>0,routeDone=routed>0,readyDone=ready>0;
  return [
    {key:"UNDERSTAND",label:"Your offer",detail:"What you sell, who it helps and what you want to achieve.",status:status(understandDone,!understandDone&&activation.status==="RUNNING",activationAttention&&!understandDone),value:understandDone?"Brief understood":"Understanding your offer",href:"/app/campaigns"},
    {key:"MAP",label:"Target market",detail:"The audience that best matches your offer and goal.",status:status(mapDone,understandDone&&!mapDone,activationAttention&&understandDone&&!mapDone),value:mapDone?"Market defined":"Shaping the market",href:"/app/campaigns"},
    {key:"DISCOVER",label:"Find companies",detail:"Companies that genuinely fit the brief.",status:status(discoverDone,mapDone&&!discoverDone,activationAttention&&mapDone&&!discoverDone),value:scoped>0?`${scoped} companies`:discoverDone?"Companies found":"Finding companies",href:"/app/companies"},
    {key:"RESEARCH",label:"Check fit",detail:"Why each company may be worth your time.",status:status(researchDone,discoverDone&&!researchDone),value:researched>0?`${researched} researched`:discoverDone?"Researching":"Waiting",href:"/app/companies"},
    {key:"EVALUATE",label:"Find opportunities",detail:"Which companies have a strong reason to buy.",status:status(evalDone,researchDone&&!evalDone),value:opps>0?`${opps} opportunities`:researched>0?"Comparing companies":"Waiting",href:"/app/opportunities"},
    {key:"ROUTE",label:"Find buyers",detail:"Who owns the decision and how to reach them.",status:status(routeDone,evalDone&&!routeDone),value:routed>0?`${routed} routes ready`:evalDone?"Finding buyers":"Waiting",href:"/app/opportunities"},
    {key:"READY",label:"Ready to contact",detail:"Opportunities with a buyer and usable contact route.",status:status(readyDone,routeDone&&!readyDone),value:ready>0?`${ready} ready`:routeDone?"Checking contact routes":"Waiting",href:"/app/opportunities"},
  ];
}
