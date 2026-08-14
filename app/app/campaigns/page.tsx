import { commandCentre } from "@/app/app/_lib/data";
import { workspaceSessionOrRedirect } from "@/app/app/_lib/session";
import { asObjectArray,campaignListItem,countFromObject,money } from "@/application/read-model/presentation";
import { EmptyState,humanStatus,PageHeader,Panel,StatusBadge } from "@/ui";

export default async function Campaigns(){
  const {workspace}=await workspaceSessionOrRedirect();
  const model=await commandCentre(workspace.organisationId);
  const campaigns=asObjectArray(model.campaigns).map(campaignListItem);
  return <div>
    <PageHeader eyebrow="CAMPAIGNS" title="The markets" accent="you are actively pursuing." description="A campaign is the commercial brief MarketRoute works from: who you are selling as, what you want to achieve and which market should be researched."/>
    {campaigns.length===0?<Panel><EmptyState icon="campaigns" title="No campaigns yet" body="No campaign records exist in this workspace yet."/></Panel>:<div className="mr-campaign-grid">{campaigns.map(c=><a className="mr-campaign-card" href={`/app/campaigns/${c.campaignId}`} key={c.campaignId}><header><div><span>{c.sellerName}</span><h2>{c.name}</h2></div><StatusBadge label={humanStatus(c.workflowState)} title={c.workflowState} tone={c.workflowState==="ACTIVE"?"green":"slate"}/></header><div className="mr-campaign-card__objective"><span>Commercial objective</span><p>{c.objectiveText??"Commercial objective pending."}</p></div><dl><div><dt>Companies researched</dt><dd>{c.scopedCompanies}</dd></div><div><dt>Qualified opportunities</dt><dd>{c.materialisedOpportunities}</dd></div><div><dt>Ready to pursue</dt><dd>{countFromObject(c.dispositionCounts,"ACTIONABLE")}</dd></div><div><dt>Research today</dt><dd>{money(c.budget.spentTodayUsd)}</dd></div></dl><footer><span>{c.engagementPolicy==="AUTOPILOT"?"Autopilot engagement policy":"Human approval policy"}</span><strong>View campaign →</strong></footer></a>)}</div>}
  </div>
}
