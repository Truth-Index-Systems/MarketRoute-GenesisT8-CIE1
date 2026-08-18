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
    {key:"UNDERSTAND",label:"Understand",detail:"Your business, offering and commercial objective.",status:status(understandDone,!understandDone&&activation.status==="RUNNING",activationAttention&&!understandDone),value:understandDone?"Business understood":"Reading your business",href:"/app/campaigns"},
    {key:"MAP",label:"Map",detail:"The market that fits what you actually sell.",status:status(mapDone,understandDone&&!mapDone,activationAttention&&understandDone&&!mapDone),value:mapDone?"Market defined":"Mapping market",href:"/app/campaigns"},
    {key:"DISCOVER",label:"Discover",detail:"Relevant organisations, using Genesis knowledge first.",status:status(discoverDone,mapDone&&!discoverDone,activationAttention&&mapDone&&!discoverDone),value:scoped>0?`${scoped} in scope`:discoverDone?"Scope ready":"Finding companies",href:"/app/companies"},
    {key:"RESEARCH",label:"Research",detail:"Evidence that changes whether a company matters.",status:status(researchDone,discoverDone&&!researchDone),value:researched>0?`${researched} evidenced`:discoverDone?"Researching":"Waiting",href:"/app/research"},
    {key:"EVALUATE",label:"Evaluate",detail:"Which companies have a real commercial case.",status:status(evalDone,researchDone&&!evalDone),value:opps>0?`${opps} opportunities`:researched>0?"Evaluating":"Waiting",href:"/app/opportunities"},
    {key:"ROUTE",label:"Route",detail:"The organisational path and buyer access point.",status:status(routeDone,evalDone&&!routeDone),value:routed>0?`${routed} routed`:evalDone?"Finding routes":"Waiting",href:"/app/opportunities"},
    {key:"READY",label:"Ready",detail:"Opportunities with a current route you can use.",status:status(readyDone,routeDone&&!readyDone),value:ready>0?`${ready} ready`:routeDone?"Verifying access":"Waiting",href:"/app/opportunities"},
  ];
}
