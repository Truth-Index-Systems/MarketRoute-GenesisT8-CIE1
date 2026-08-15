import { commandCentre } from "@/app/app/_lib/data";
import { workspaceSessionOrRedirect } from "@/app/app/_lib/session";
import { asObjectArray,campaignListItem,countFromObject,money } from "@/application/read-model/presentation";
import { CampaignActivationProgress,EmptyState,humanStatus,Icon,MetricCard,PageHeader,Panel,SectionHeading,StatusBadge } from "@/ui";

export default async function CommandCentre(){
  const {workspace,activation}=await workspaceSessionOrRedirect();
  const model=await commandCentre(workspace.organisationId);
  const campaigns=asObjectArray(model.campaigns).map(campaignListItem);
  const scoped=campaigns.reduce((a,c)=>a+c.scopedCompanies,0);
  const opps=campaigns.reduce((a,c)=>a+c.materialisedOpportunities,0);
  const actionable=campaigns.reduce((a,c)=>a+countFromObject(c.dispositionCounts,"ACTIONABLE"),0);
  const reviewable=campaigns.reduce((a,c)=>a+countFromObject(c.workflowCounts,"REVIEWABLE"),0);
  const activationVisible=["PENDING","RUNNING","FAILED"].includes(activation.status);

  return <div>
    <PageHeader eyebrow="COMMAND CENTRE" title="Your market," accent="reduced to what matters." description="See what has been researched, which companies are worth pursuing, what is ready to act on and where MarketRoute still needs evidence."/>

    <section className="mr-metric-grid">
      <MetricCard label="Companies researched" value={String(scoped)} meta="Currently in campaign scope" icon={<Icon name="companies"/>}/>
      <MetricCard label="Qualified opportunities" value={String(opps)} meta="Companies that earned opportunity state" icon={<Icon name="opportunities"/>}/>
      <MetricCard label="Ready to pursue" value={String(actionable)} meta="Current commercial, route and contact authority" icon={<Icon name="shield"/>} accent/>
      <MetricCard label="Need your decision" value={String(reviewable)} meta="Commercially ready for human review" icon={<Icon name="check"/>}/>
    </section>

    <section className="mr-command-brief">
      <div><span>What can I act on?</span><strong>{actionable} compan{actionable===1?"y is":"ies are"} currently actionable.</strong><p>These opportunities have a current commercial case, route and contact authority.</p></div>
      <div><span>Where should I look next?</span><strong>{reviewable} opportunit{reviewable===1?"y needs":"ies need"} a decision.</strong><p>Review them before engagement moves forward.</p></div>
      <div><span>What is MarketRoute working on?</span><strong>{campaigns.length} active market view{campaigns.length===1?"":"s"}.</strong><p>Open a campaign to see its companies, research spend and opportunity population.</p></div>
    </section>

    {activationVisible&&<CampaignActivationProgress state={activation}/>} 

    <Panel>
      <SectionHeading eyebrow="Your markets" title="Active campaigns" description="Each campaign keeps one commercial objective, seller context and research policy together so the intelligence stays interpretable."/>
      {campaigns.length===0?(activationVisible?<EmptyState icon="campaigns" title="Campaign will appear here automatically" body="You can leave this page. The brief and preparation progress are stored in your workspace."/>:<div className="mr-command-empty"><EmptyState icon="campaigns" title="No live campaign" body="A deleted campaign remains archived with its evidence and audit lineage. Start a fresh brief when you are ready to pursue another market."/>{["OWNER","ADMIN"].includes(workspace.role)&&<a className="mr-button mr-button--primary" href="/app/campaigns/new">Start new campaign <Icon name="arrow" size={16}/></a>}</div>):<div className="mr-live-card-list">{campaigns.map((c)=><a className="mr-live-card" href={`/app/campaigns/${c.campaignId}`} key={c.campaignId}><div className="mr-live-card__main"><span className="mr-live-card__seller">{c.sellerName}</span><div className="mr-live-card__title"><strong>{c.name}</strong><StatusBadge compact label={humanStatus(c.workflowState)} title={c.workflowState} tone={c.workflowState==="ACTIVE"?"green":"slate"}/></div><p>{c.objectiveText??"Commercial objective pending."}</p></div><dl><div><dt>Companies</dt><dd>{c.scopedCompanies}</dd></div><div><dt>Ready to pursue</dt><dd>{countFromObject(c.dispositionCounts,"ACTIONABLE")}</dd></div><div><dt>Need review</dt><dd>{countFromObject(c.workflowCounts,"REVIEWABLE")}</dd></div><div><dt>Research today</dt><dd>{money(c.budget.spentTodayUsd)}</dd></div></dl><span className="mr-live-card__open">Open campaign →</span></a>)}</div>}
    </Panel>
  </div>
}
