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
  const error=rawError==="MARKETROUTE_CAMPAIGN_ADMIN_REQUIRED"?"Only workspace owners and admins can create a campaign.":rawError?"MarketRoute could not complete that campaign action.":null;
  return <div>
    <PageHeader eyebrow="CAMPAIGNS" title="The markets" accent="you are actively pursuing." description="Each campaign is a separate commercial brief with its own scope, research and opportunity pipeline." actions={canCreate?<Link className="mr-button mr-button--primary" href="/app/campaigns/new" prefetch>Add campaign <Icon name="arrow" size={16}/></Link>:undefined}/>
    <div className="mr-campaign-capacity-strip"><Icon name="campaigns" size={16}/><span><strong>{capacity.activeMarketCount} / {capacity.activeMarketLimit}</strong> active-market slots used on {capacity.planName??"current access"}.</span>{capacity.requiresUpgrade&&<Link href="/app/campaigns/new" prefetch>Configure another →</Link>}</div>
    {query.campaignAction==="archived"&&<div className="mr-alert mr-alert--success"><Icon name="check" size={16}/><span>Campaign deleted from normal views. Its evidence and audit lineage remain retained.</span></div>}
    {query.campaignAction==="processing"&&<div className="mr-alert mr-alert--success"><Icon name="check" size={16}/><span>Campaign brief accepted. Genesis will prepare this separate campaign on the next bootstrap run.</span></div>}
    {error&&<div className="mr-alert mr-alert--error"><Icon name="shield" size={16}/><span>{error}</span></div>}
    {activationVisible&&<CampaignActivationProgress state={activation}/>} 
    {campaigns.length===0?(activationVisible?null:<Panel><EmptyState icon="campaigns" title="No live campaign" body={canCreate?"Add a campaign to configure a fresh market brief. Archived campaigns keep their evidence and audit lineage.":"There is no live campaign in this workspace. Ask an owner or admin to add one."}/></Panel>):<div className="mr-campaign-grid">{campaigns.map(c=><Link className="mr-campaign-card" href={`/app/campaigns/${c.campaignId}`} prefetch key={c.campaignId}><header><div><span>{c.sellerName}</span><h2>{c.name}</h2></div><StatusBadge label={humanStatus(c.workflowState)} title={c.workflowState} tone={c.workflowState==="ACTIVE"?"green":"slate"}/></header><div className="mr-campaign-card__objective"><span>Commercial objective</span><p>{c.objectiveText??"Commercial objective pending."}</p></div><dl><div><dt>Companies</dt><dd>{c.scopedCompanies}</dd></div><div><dt>Opportunities</dt><dd>{c.materialisedOpportunities}</dd></div><div><dt>Ready to pursue</dt><dd>{countFromObject(c.dispositionCounts,"ACTIONABLE")}</dd></div><div><dt>System-ready</dt><dd>{countFromObject(c.workflowCounts,"REVIEWABLE")+countFromObject(c.workflowCounts,"APPROVED")}</dd></div></dl><footer><span>Assisted engagement</span><strong>View campaign →</strong></footer></Link>)}</div>}
  </div>;
}
