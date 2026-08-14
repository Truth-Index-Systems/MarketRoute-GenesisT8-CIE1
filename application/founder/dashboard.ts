import { founderDashboardRepositoryFromEnvironment,type FounderDashboardSnapshot,type JsonObject } from "../../platform/database/founder-dashboard-repository";
import { productionEnvironmentStatus } from "../production/runtime";

export type FounderStageState="LIVE"|"WORKING"|"WAITING"|"ATTENTION"|"DISABLED";
export interface FounderStage{
  key:string;
  label:string;
  technicalLabel:string;
  state:FounderStageState;
  value:number;
  valueLabel:string;
  detail:string;
  latestAt:string|null;
  secondary?:string;
}
export interface FounderDashboardModel{
  snapshot:FounderDashboardSnapshot;
  environment:ReturnType<typeof productionEnvironmentStatus>&{founderAuthConfigured:boolean};
  stages:FounderStage[];
}

function obj(value:unknown):JsonObject{return value&&typeof value==="object"&&!Array.isArray(value)?value as JsonObject:{};}
function num(value:unknown){const n=Number(value??0);return Number.isFinite(n)?n:0;}
function text(value:unknown){return typeof value==="string"?value:"";}
function iso(value:unknown){const v=text(value);return v&&Number.isFinite(Date.parse(v))?v:null;}
function runtime(snapshot:FounderDashboardSnapshot,key:string){return obj(obj(snapshot.runtime)[key]);}
function runtimeState(snapshot:FounderDashboardSnapshot,key:string,staleMinutes:number){
  const row=runtime(snapshot,key);const event=text(row.eventType);const at=iso(row.occurredAt);
  if(event==="FAILED")return "ATTENTION" as const;
  if(event==="DISABLED")return "DISABLED" as const;
  if(event==="STARTED")return "LIVE" as const;
  if(event==="SUCCEEDED"&&at&&Date.now()-Date.parse(at)<=staleMinutes*60_000)return "LIVE" as const;
  if(event==="SUCCEEDED")return "WORKING" as const;
  return "WAITING" as const;
}
function dataState(count:number,attention=false){if(attention)return "ATTENTION" as const;return count>0?"WORKING" as const:"WAITING" as const;}
function money(value:number){return `$${value.toFixed(value<10?2:0)}`;}

export async function loadFounderDashboard():Promise<FounderDashboardModel>{
  const snapshot=await founderDashboardRepositoryFromEnvironment().snapshot();
  const growth=obj(snapshot.growth),activation=obj(snapshot.activation),discovery=obj(snapshot.discovery),research=obj(snapshot.research),evidence=obj(snapshot.evidence),truth=obj(snapshot.truth),r4=obj(snapshot.r4),r5=obj(snapshot.r5),r6=obj(snapshot.r6),opportunity=obj(snapshot.opportunity),engagement=obj(snapshot.engagement),ai=obj(snapshot.ai);
  const env=productionEnvironmentStatus();
  const stages:FounderStage[]=[
    {key:"growth",label:"Genesis database growth",technicalLabel:"Autonomous intelligence builder",state:runtimeState(snapshot,"GROWTH",8)==="ATTENTION"||num(growth.actionsFailed)>0?"ATTENTION":runtimeState(snapshot,"GROWTH",8),value:num(growth.companies),valueLabel:"shared intelligence companies",detail:`${num(growth.dense80)} at ≥80% data density · ${num(growth.dense100)} fully dense · ${text(growth.phase)||"SEED"} phase`,latestAt:iso(growth.latestAt),secondary:`${money(num(growth.spentTodayUsd))} today`},
    {key:"bootstrap",label:"Workspace activation",technicalLabel:"Bootstrap",state:runtimeState(snapshot,"BOOTSTRAP",25),value:num(activation.succeeded),valueLabel:"activated workspaces",detail:`${num(activation.pending)} pending · ${num(activation.running)} running · ${num(activation.failed)+num(activation.needsInput)} attention`,latestAt:iso(activation.latestAt)},
    {key:"discovery",label:"Company discovery",technicalLabel:"Target acquisition",state:dataState(num(discovery.scopedCompanies)),value:num(discovery.scopedCompanies),valueLabel:"companies in campaign scope",detail:`${num(discovery.companies)} canonical companies · ${num(discovery.people)} people discovered`,latestAt:iso(discovery.latestCompanyAt)},
    {key:"research",label:"Genesis research",technicalLabel:"Research planner + worker",state:runtimeState(snapshot,"RESEARCH",15)==="ATTENTION"||num(research.failed)>0?"ATTENTION":runtimeState(snapshot,"RESEARCH",15),value:num(research.succeeded),valueLabel:"research jobs completed",detail:`${num(research.pending)} queued · ${num(research.running)} running · ${num(research.workUnits)} work units`,latestAt:iso(research.latestWorkAt),secondary:`${money(num(research.spentTodayUsd))} today`},
    {key:"evidence",label:"Evidence collected",technicalLabel:"Evidence + provenance",state:dataState(num(evidence.items)),value:num(evidence.items),valueLabel:"evidence items",detail:`${num(evidence.sources)} sources · ${num(evidence.acquisitions)} acquisitions · ${num(evidence.claims)} claims`,latestAt:iso(evidence.latestAt)},
    {key:"truth",label:"Truth qualification",technicalLabel:"Truth Engine V2",state:dataState(num(truth.entitySnapshots)),value:num(truth.researchedCompanies),valueLabel:"companies with Truth",detail:`${num(truth.entitySnapshots)} entity snapshots · ${num(truth.claimSnapshots)} claim snapshots`,latestAt:iso(truth.latestAt)},
    {key:"r4",label:"Commercial reality",technicalLabel:"R4",state:dataState(num(r4.records)),value:num(r4.candidates),valueLabel:"commercial candidates",detail:`${num(r4.companies)} evaluated · ${num(r4.researchRequired)} need more research · ${num(r4.notAdmissible)} not admissible`,latestAt:iso(r4.latestAt)},
    {key:"r5",label:"Route intelligence",technicalLabel:"R5",state:dataState(num(r5.records)),value:num(r5.reachableCompanies),valueLabel:"reachable companies",detail:`${num(r5.relationships)} relationships · ${num(r5.graphNodes)} graph nodes · ${num(r5.researchRequired)} need route research`,latestAt:iso(r5.latestAt)},
    {key:"r6",label:"Contact qualification",technicalLabel:"R6",state:dataState(num(r6.records)),value:num(r6.contactQualifiedCompanies),valueLabel:"contact-qualified companies",detail:`${num(r6.authorisedAccessPoints)} authorised access points · ${num(r6.researchRequired)} need contact research`,latestAt:iso(r6.latestAt)},
    {key:"opportunity",label:"Opportunities",technicalLabel:"Opportunity projection",state:dataState(num(opportunity.total)),value:num(opportunity.total),valueLabel:"materialised opportunities",detail:`${num(opportunity.reviewable)} reviewable · ${num(opportunity.approved)} approved · ${num(opportunity.engaged)} engaged`,latestAt:iso(opportunity.latestAt)},
    {key:"engagement",label:"Engagement",technicalLabel:"Strategy + generation",state:dataState(num(engagement.messages),num(engagement.reviewBlock)>0),value:num(engagement.messages),valueLabel:"messages generated",detail:`${num(engagement.reviewPass)} passed review · ${num(engagement.approvals)} approved · ${num(engagement.queued)} queued`,latestAt:iso(engagement.latestAt)},
    {key:"delivery",label:"Outbound delivery",technicalLabel:"Send-time authority gate",state:env.deliveryEnabled?runtimeState(snapshot,"DELIVERY",10):"DISABLED",value:num(engagement.deliverySent),valueLabel:"messages sent",detail:env.deliveryEnabled?`${num(engagement.deliveryPending)} pending · ${num(engagement.deliveryFailed)} failed · ${num(engagement.deliveryBlockedStale)} blocked stale`:`Email delivery intentionally disabled`,latestAt:iso(runtime(snapshot,"DELIVERY").occurredAt)},
  ];
  return{snapshot,environment:{...env,founderAuthConfigured:Boolean(process.env.FOUNDER_DASHBOARD_PASSWORD?.trim()&&process.env.FOUNDER_DASHBOARD_SESSION_SECRET?.trim())},stages};
}
