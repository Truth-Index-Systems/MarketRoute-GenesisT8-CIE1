import { commandCentre } from "@/app/app/_lib/data";
import { workspaceSessionOrRedirect } from "@/app/app/_lib/session";
import { asObjectArray,campaignListItem,countFromObject,money } from "@/application/read-model/presentation";
import { EmptyState,humanStatus,Icon,PageHeader,Panel,StatusBadge } from "@/ui";

export default async function Campaigns({searchParams}:{searchParams:Promise<Record<string,string|string[]|undefined>>}){
  const query=await searchParams;
  const {workspace}=await workspaceSessionOrRedirect();
  const model=await commandCentre(workspace.organisationId);
  const campaigns=asObjectArray(model.campaigns).map(campaignListItem);
  const canCreate=["OWNER","ADMIN"].includes(workspace.role);
  const rawError=typeof query.actionError==="string"?query.actionError:null;
  const error=rawError==="MARKETROUTE_CAMPAIGN_ADMIN_REQUIRED"?"Only workspace owners and admins can create a campaign.":rawError==="MARKETROUTE_LIVE_CAMPAIGN_ALREADY_EXISTS"?"This workspace already has a live campaign.":rawError?"MarketRoute could not complete that campaign action.":null;
  return <div>
    <PageHeader eyebrow="CAMPAIGNS" title="The markets" accent="you are actively pursuing." description="A campaign is the commercial brief MarketRoute works from: who you are selling as, what you want to achieve and which market should be researched." actions={campaigns.length===0&&canCreate?<a className="mr-button mr-button--primary" href="/app/campaigns/new">Start new campaign <Icon name="arrow" size={16}/></a>:undefined}/>
    {query.campaignAction==="archived"&&<div className="mr-alert mr-alert--success"><Icon name="check" size={16}/><span>Campaign deleted from normal views. Its evidence and audit lineage remain retained.</span></div>}
    {query.campaignAction==="processing"&&<div className="mr-alert mr-alert--success"><Icon name="check" size={16}/><span>Campaign brief accepted. Genesis will prepare the new campaign on the next bootstrap run.</span></div>}
    {error&&<div className="mr-alert mr-alert--error"><Icon name="shield" size={16}/><span>{error}</span></div>}
    {campaigns.length===0?<Panel><EmptyState icon="campaigns" title={query.campaignAction==="processing"?"Preparing your new campaign":"No live campaign"} body={query.campaignAction==="processing"?"The brief is queued. This page will show the campaign after the activation worker completes.":canCreate?"Your previous campaign remains archived with its evidence and audit lineage. Start a new campaign when you are ready.":"Your previous campaign remains archived. Ask a workspace owner or admin to start a new campaign."}/></Panel>:<div className="mr-campaign-grid">{campaigns.map(c=><a className="mr-campaign-card" href={`/app/campaigns/${c.campaignId}`} key={c.campaignId}><header><div><span>{c.sellerName}</span><h2>{c.name}</h2></div><StatusBadge label={humanStatus(c.workflowState)} title={c.workflowState} tone={c.workflowState==="ACTIVE"?"green":"slate"}/></header><div className="mr-campaign-card__objective"><span>Commercial objective</span><p>{c.objectiveText??"Commercial objective pending."}</p></div><dl><div><dt>Companies researched</dt><dd>{c.scopedCompanies}</dd></div><div><dt>Qualified opportunities</dt><dd>{c.materialisedOpportunities}</dd></div><div><dt>Ready to pursue</dt><dd>{countFromObject(c.dispositionCounts,"ACTIONABLE")}</dd></div><div><dt>Research today</dt><dd>{money(c.budget.spentTodayUsd)}</dd></div></dl><footer><span>{c.engagementPolicy==="AUTOPILOT"?"Autopilot engagement policy":"Human approval policy"}</span><strong>View campaign →</strong></footer></a>)}</div>}
  </div>
}
