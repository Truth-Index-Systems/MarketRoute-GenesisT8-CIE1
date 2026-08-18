import Link from "next/link";
import { workspaceSessionOrRedirect } from "@/app/app/_lib/session";
import { campaignOverviewFromSummary } from "@/app/app/_lib/data";
import { applicationReadServiceFromEnvironment } from "@/application/read-model/service";
import { asObject,asObjectArray,companyProfile,numberValue,statusTone,text } from "@/application/read-model/presentation";
import { CampaignDangerZone,EmptyState,humanStatus,Icon,IntelligenceTable,MarketRouteNarrativeCard,MetricCard,PageHeader,Panel,ProductPipeline,SectionHeading,StatusBadge } from "@/ui";
import { marketRouteConversationServiceFromEnvironment } from "@/application/conversation/service";
import { productPipeline } from "@/application/product-experience/pipeline";

function campaignErrorMessage(code:string):string{
  if(code.includes("MARKETROUTE_CAMPAIGN_CHANGE_BLOCKED_DURING_DELIVERY"))return "This market cannot be paused or deleted while a delivery is running. Try again after it finishes.";
  if(code.includes("MARKETROUTE_CAMPAIGN_ADMIN_REQUIRED"))return "Only workspace owners and admins can manage the market brief.";
  if(code.includes("MARKETROUTE_CAMPAIGN_NAME_CONFIRMATION_MISMATCH"))return "The market name did not match. Type it exactly as shown to delete it.";
  if(code.includes("MARKETROUTE_CAMPAIGN_PAUSE_STATE_INVALID"))return "This market cannot be paused from its current state.";
  if(code.includes("MARKETROUTE_CAMPAIGN_RESUME_STATE_INVALID"))return "This market cannot be resumed from its current state.";
  return "The market could not be updated. Please try again.";
}
export default async function CampaignPage({params,searchParams}:{params:Promise<{campaignId:string}>;searchParams:Promise<Record<string,string|string[]|undefined>>}){
  const {campaignId}=await params;const query=await searchParams;const {workspace,activation}=await workspaceSessionOrRedirect();
  const read=applicationReadServiceFromEnvironment();
  const [commandModel,commercial]=await Promise.all([read.commandCentre({organisationId:workspace.organisationId}),read.commercialAccess({organisationId:workspace.organisationId})]);
  const summaryExists=asObjectArray(commandModel.campaigns).some(row=>text(asObject(row.campaign).campaignId,"")===campaignId);
  const index=summaryExists?await read.opportunityIndex({organisationId:workspace.organisationId,campaignId,limit:200}):null;
  const model=summaryExists&&index?campaignOverviewFromSummary(commandModel,campaignId,index):await read.campaign({organisationId:workspace.organisationId,campaignId});
  if(!model)throw new Error("MARKETROUTE_CAMPAIGN_SUMMARY_NOT_FOUND");
  const campaign=asObject(model.campaign),metrics=asObject(model.metrics),profiles=asObjectArray(model.opportunities).map(companyProfile),state=text(campaign.workflowState,"UNKNOWN"),campaignName=text(campaign.name,"Market");
  const canManage=workspace.role==="OWNER"||workspace.role==="ADMIN",action=typeof query.campaignAction==="string"?query.campaignAction:null,actionError=typeof query.actionError==="string"?campaignErrorMessage(query.actionError):null;
  const narrative=await marketRouteConversationServiceFromEnvironment().campaign(model),stages=productPipeline({activation,campaign:model});const ready=profiles.filter(p=>p.executableNow).length,checking=profiles.filter(p=>["RESEARCH_REQUIRED","REVALIDATION_REQUIRED"].includes(p.disposition)).length;
  return <div>
    <PageHeader eyebrow="CURRENT MARKET" title={campaignName} description={text(campaign.objectiveText,"Goal not added yet.")} actions={<div className="mr-header-badge-row"><StatusBadge label={state==="ACTIVE"?"MarketRoute working":humanStatus(state)} title={state} tone={statusTone(state)}/></div>}/>
    {action==="paused"&&<div className="mr-alert mr-alert--success"><Icon name="check" size={16}/><span>Market paused. MarketRoute will not start new research for it.</span></div>}
    {action==="resumed"&&<div className="mr-alert mr-alert--success"><Icon name="check" size={16}/><span>Market resumed. MarketRoute can continue research.</span></div>}
    {actionError&&<div className="mr-alert mr-alert--error"><Icon name="warning" size={16}/><span>{actionError}</span></div>}

    <ProductPipeline stages={stages} title="How this market is progressing" compact/>
    <MarketRouteNarrativeCard narrative={narrative} eyebrow="MARKETROUTE VIEW"/>

    {commercial.mode==="DISCOVERY_FREE"&&commercial.campaignId===campaignId&&commercial.lockedCount>0&&<Link className="mr-upgrade-banner mr-upgrade-banner--premium" href="/app/opportunities" prefetch><div><Icon name="spark" size={18}/><span><strong>{commercial.lockedCount} additional opportunit{commercial.lockedCount===1?"y is":"ies are"} ready.</strong><small>MarketRoute has finished the research. Upgrade to reveal them.</small></span></div><b>Unlock opportunities →</b></Link>}

    <section className="mr-metric-grid"><MetricCard label="Companies researched" value={String(numberValue(metrics.scopedCompanies))} meta="Companies in this market" icon={<Icon name="companies"/>}/><MetricCard label="Opportunities found" value={String(numberValue(metrics.materialisedOpportunities))} meta="Companies worth your attention" icon={<Icon name="opportunities"/>}/><MetricCard label="Ready to contact" value={String(ready)} meta="Buyer and contact route ready" icon={<Icon name="route"/>} accent/><MetricCard label="Still checking" value={String(checking)} meta={checking?`${checking} opportunit${checking===1?"y is":"ies are"} still being resolved`:"No unresolved opportunity checks"} icon={<Icon name="check"/>}/></section>

    <Panel><SectionHeading eyebrow="OPPORTUNITIES" title="The companies worth your attention" description="See why each company matters, whether a usable contact route is ready and where MarketRoute is still checking."/>{profiles.length===0?<EmptyState icon="opportunities" title="No strong opportunities yet" body="MarketRoute is still researching this market. Strong opportunities will appear here as the picture becomes clear."/>:<IntelligenceTable head={["Company","MarketRoute view","Readiness","Ready to contact","Routes","Research"]}>{profiles.map(p=><tr key={p.companyId}><td><a href={`/app/opportunities/${campaignId}/${p.companyId}`}><strong>{p.companyName}</strong><small>{p.canonicalDomain??"Company website confirmed"}</small></a></td><td><StatusBadge compact label={p.executableNow?"Strong opportunity":humanStatus(p.disposition)} title={p.disposition} tone={statusTone(p.disposition)}/></td><td>{p.executableNow?"Ready":humanStatus(p.workflowState??"Researching")}</td><td><StatusBadge compact label={p.executableNow?"Yes":"Not yet"} tone={p.executableNow?"green":"slate"}/></td><td>{p.authorisedRoutes>0?`${p.authorisedRoutes} ready`:`${p.structuralRoutes} forming`}</td><td>{["RESEARCH_REQUIRED","REVALIDATION_REQUIRED"].includes(p.disposition)?"Still checking":"Current"}</td></tr>)}</IntelligenceTable>}</Panel>

    {canManage&&state!=="ARCHIVED"?<CampaignDangerZone campaignId={campaignId} campaignName={campaignName} workflowState={state}/>:null}
    {!canManage&&<div className="mr-readonly-note mr-campaign-readonly"><Icon name="shield" size={15}/><span>Market controls are available to workspace owners and admins.</span></div>}
  </div>;
}
