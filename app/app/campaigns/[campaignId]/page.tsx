import { workspaceSessionOrRedirect } from "@/app/app/_lib/session";
import { applicationReadServiceFromEnvironment } from "@/application/read-model/service";
import { asObject,asObjectArray,companyProfile,money,numberValue,statusTone,text } from "@/application/read-model/presentation";
import { CampaignDangerZone,EmptyState,humanStatus,Icon,IntelligenceTable,MarketRouteNarrativeCard,MetricCard,PageHeader,Panel,SectionHeading,StatusBadge } from "@/ui";
import { marketRouteConversationServiceFromEnvironment } from "@/application/conversation/service";
import { commercialAccessServiceFromEnvironment } from "@/application/commercial/service";

function campaignErrorMessage(code:string):string{
  if(code.includes("MARKETROUTE_CAMPAIGN_CHANGE_BLOCKED_DURING_DELIVERY"))return "This campaign cannot be paused or deleted while an outreach delivery is running. Try again after it finishes.";
  if(code.includes("MARKETROUTE_CAMPAIGN_ADMIN_REQUIRED"))return "Only workspace owners and admins can manage campaigns.";
  if(code.includes("MARKETROUTE_CAMPAIGN_NAME_CONFIRMATION_MISMATCH"))return "The campaign name did not match. Type it exactly as shown to delete the campaign.";
  if(code.includes("MARKETROUTE_CAMPAIGN_PAUSE_STATE_INVALID"))return "This campaign cannot be paused from its current state.";
  if(code.includes("MARKETROUTE_CAMPAIGN_RESUME_STATE_INVALID"))return "This campaign cannot be resumed from its current state.";
  return "The campaign could not be updated. Please try again.";
}

export default async function CampaignPage({params,searchParams}:{params:Promise<{campaignId:string}>;searchParams:Promise<Record<string,string|string[]|undefined>>}){
  const {campaignId}=await params;
  const query=await searchParams;
  const {workspace}=await workspaceSessionOrRedirect();
  const [model,commercial]=await Promise.all([applicationReadServiceFromEnvironment().campaign({organisationId:workspace.organisationId,campaignId}),commercialAccessServiceFromEnvironment().access(workspace.organisationId)]);
  const campaign=asObject(model.campaign),metrics=asObject(model.metrics),research=asObject(model.research),budget=asObject(research.budget),profiles=asObjectArray(model.opportunities).map(companyProfile);
  const state=text(campaign.workflowState,"UNKNOWN");
  const campaignName=text(campaign.name,"Campaign");
  const canManage=workspace.role==="OWNER"||workspace.role==="ADMIN";
  const action=typeof query.campaignAction==="string"?query.campaignAction:null;
  const actionError=typeof query.actionError==="string"?campaignErrorMessage(query.actionError):null;
  const narrative=await marketRouteConversationServiceFromEnvironment().campaign(model);
  return <div>
    <PageHeader eyebrow="CAMPAIGN OVERVIEW" title={campaignName} description={text(campaign.objectiveText,"Commercial objective not yet declared.")} actions={<div className="mr-header-badge-row"><StatusBadge label={humanStatus(state)} title={state} tone={statusTone(state)}/><StatusBadge label={model.engagementPolicy==="AUTOPILOT"?"Autopilot engagement":"Human approval"} tone="slate"/></div>}/>
    {action==="paused"&&<div className="mr-alert mr-alert--success"><Icon name="check" size={16}/><span>Campaign paused. Genesis will not claim new research work for it.</span></div>}
    {action==="resumed"&&<div className="mr-alert mr-alert--success"><Icon name="check" size={16}/><span>Campaign resumed. Genesis can claim new research work again.</span></div>}
    {actionError&&<div className="mr-alert mr-alert--error"><Icon name="shield" size={16}/><span>{actionError}</span></div>}
    <MarketRouteNarrativeCard narrative={narrative} eyebrow="MARKETROUTE VIEW"/>
    {commercial.mode==="DISCOVERY_FREE"&&commercial.campaignId===campaignId&&commercial.lockedCount>0&&<a className="mr-upgrade-banner" href="/app/opportunities"><div><Icon name="spark" size={18}/><span><strong>{commercial.lockedCount} additional opportunit{commercial.lockedCount===1?"y has":"ies have"} become ready.</strong><small>They are server-locked until this workspace is upgraded.</small></span></div><b>Unlock opportunities →</b></a>}
    <section className="mr-metric-grid"><MetricCard label="Companies in scope" value={String(numberValue(metrics.scopedCompanies))} meta="Currently being evaluated"/><MetricCard label="Qualified opportunities" value={String(numberValue(metrics.materialisedOpportunities))} meta="Commercially materialised"/><MetricCard label="Research used today" value={money(budget.spentTodayUsd)} meta="AI and acquisition spend"/><MetricCard label="Research budget remaining" value={money(budget.remainingTodayUsd)} meta="Available today" accent/></section>
    <Panel><SectionHeading eyebrow="Commercial pipeline" title="Companies that have earned opportunity state" description="A company appears here only after MarketRoute can represent the commercial case and its current authority chain. Technical R4/R5/R6 states remain available in the row for auditability."/>{profiles.length===0?<EmptyState icon="opportunities" title="No qualified opportunities yet" body="MarketRoute is still researching this campaign, or no company has yet earned the required commercial, route and contact authority."/>:<IntelligenceTable head={["Company","Commercial status","Your workflow","Commercial case","Route","Contact","Access"]}>{profiles.map(p=><tr key={p.companyId}><td><a href={`/app/opportunities/${campaignId}/${p.companyId}`}><strong>{p.companyName}</strong><small>{p.canonicalDomain??"No domain"}</small></a></td><td><StatusBadge compact label={humanStatus(p.disposition)} title={p.disposition} tone={statusTone(p.disposition)}/></td><td>{humanStatus(p.workflowState,"Not reviewed")}</td><td><span className="mr-table-state" title={p.commercialReality}>{humanStatus(p.commercialReality)}</span></td><td><span className="mr-table-state" title={p.routeAuthority}>{humanStatus(p.routeAuthority)}</span></td><td><span className="mr-table-state" title={p.contactAuthority}>{humanStatus(p.contactAuthority)}</span></td><td>{p.authorisedRoutes} qualified / {p.structuralRoutes} structural</td></tr>)}</IntelligenceTable>}</Panel>
    {canManage&&state!=="ARCHIVED"?<CampaignDangerZone campaignId={campaignId} campaignName={campaignName} workflowState={state}/>:null}
    {!canManage&&<div className="mr-readonly-note mr-campaign-readonly"><Icon name="shield" size={15}/><span>Campaign controls are available to workspace owners and admins.</span></div>}
  </div>
}
