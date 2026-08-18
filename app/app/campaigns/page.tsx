import Link from "next/link";
import { commandCentre } from "@/app/app/_lib/data";
import { workspaceSessionOrRedirect } from "@/app/app/_lib/session";
import { asObjectArray,campaignListItem,countFromObject } from "@/application/read-model/presentation";
import { commercialAccessServiceFromEnvironment } from "@/application/commercial/service";
import { CampaignActivationProgress,EmptyState,humanStatus,Icon,PageHeader,Panel,StatusBadge } from "@/ui";

export default async function Campaigns({searchParams}:{searchParams:Promise<Record<string,string|string[]|undefined>>}){
  const query=await searchParams;
  const {workspace,activation}=await workspaceSessionOrRedirect();
  const commercial=commercialAccessServiceFromEnvironment();
  const [model,capacity]=await Promise.all([commandCentre(workspace.organisationId),commercial.campaignCapacity(workspace.organisationId)]);
  const campaigns=asObjectArray(model.campaigns).map(campaignListItem);
  const canCreate=["OWNER","ADMIN"].includes(workspace.role);
  const activationVisible=["PENDING","RUNNING","FAILED","NEEDS_INPUT"].includes(activation.status);
  const rawError=typeof query.actionError==="string"?query.actionError:null;
  const error=rawError==="MARKETROUTE_CAMPAIGN_ADMIN_REQUIRED"?"Only workspace owners and admins can add a market.":rawError?"MarketRoute could not complete that market action.":null;
  return <div>
    <PageHeader eyebrow="MARKETS" title="The markets" accent="you want to win." description="Keep each audience separate so its companies, opportunities and routes stay easy to understand." actions={canCreate?<Link className="mr-button mr-button--primary" href="/app/campaigns/new" prefetch>Add market <Icon name="arrow" size={16}/></Link>:undefined}/>
    <div className="mr-campaign-capacity-strip"><Icon name="campaigns" size={16}/><span><strong>{capacity.activeMarketCount} / {capacity.activeMarketLimit}</strong> market slots used on {capacity.planName??"current access"}.</span>{capacity.requiresUpgrade&&<Link href="/app/campaigns/new" prefetch>Configure another →</Link>}</div>
    {query.campaignAction==="archived"&&<div className="mr-alert mr-alert--success"><Icon name="check" size={16}/><span>Market removed from normal views. Its research history remains safely retained.</span></div>}
    {query.campaignAction==="processing"&&<div className="mr-alert mr-alert--success"><Icon name="check" size={16}/><span>Market brief accepted. MarketRoute is preparing it now.</span></div>}
    {error&&<div className="mr-alert mr-alert--error"><Icon name="shield" size={16}/><span>{error}</span></div>}
    {activationVisible&&<CampaignActivationProgress state={activation}/>} 
    {campaigns.length===0?(activationVisible?null:<Panel><EmptyState icon="campaigns" title="No active market" body={canCreate?"Add a market to tell MarketRoute where you want to focus next.":"There is no active market in this workspace. Ask an owner or admin to add one."}/></Panel>):<div className="mr-campaign-grid">{campaigns.map(c=><Link className="mr-campaign-card" href={`/app/campaigns/${c.campaignId}`} prefetch key={c.campaignId}><header><div><span>{c.sellerName}</span><h2>{c.name}</h2></div><StatusBadge label={humanStatus(c.workflowState)} title={c.workflowState} tone={c.workflowState==="ACTIVE"?"green":"slate"}/></header><div className="mr-campaign-card__objective"><span>Goal</span><p>{c.objectiveText??"Goal pending."}</p></div><dl><div><dt>Companies</dt><dd>{c.scopedCompanies}</dd></div><div><dt>Opportunities</dt><dd>{c.materialisedOpportunities}</dd></div><div><dt>Ready to contact</dt><dd>{countFromObject(c.dispositionCounts,"ACTIONABLE")}</dd></div><div><dt>Ready now</dt><dd>{countFromObject(c.workflowCounts,"REVIEWABLE")+countFromObject(c.workflowCounts,"APPROVED")}</dd></div></dl><footer><span>You stay in control of outreach</span><strong>Open market →</strong></footer></Link>)}</div>}
  </div>;
}
