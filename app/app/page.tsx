import Link from "next/link";
import { resolveCampaignId } from "@/app/app/_lib/data";
import { workspaceSessionOrRedirect } from "@/app/app/_lib/session";
import { applicationReadServiceFromEnvironment } from "@/application/read-model/service";
import { asObjectArray,campaignListItem,companyProfile,countFromObject } from "@/application/read-model/presentation";
import { marketRouteConversationServiceFromEnvironment } from "@/application/conversation/service";
import { productPipeline } from "@/application/product-experience/pipeline";
import { EmptyState,Icon,MarketRouteNarrativeCard,MetricCard,PageHeader,Panel,ProductPipeline,SectionHeading,StatusBadge,commercialVerdict } from "@/ui";

export default async function CommandCentre(){
  const {workspace,activation}=await workspaceSessionOrRedirect();
  const read=applicationReadServiceFromEnvironment();
  const [model,commercial]=await Promise.all([read.commandCentre({organisationId:workspace.organisationId}),read.commercialAccess({organisationId:workspace.organisationId})]);
  const campaigns=asObjectArray(model.campaigns).map(campaignListItem);const activeCampaignId=resolveCampaignId(model,activation.campaignId);
  const campaign=activeCampaignId?await read.campaign({organisationId:workspace.organisationId,campaignId:activeCampaignId}):null;
  const profiles=campaign?asObjectArray(campaign.opportunities).map(companyProfile):[];const ready=profiles.filter(p=>p.executableNow);const researchNeeded=profiles.filter(p=>["RESEARCH_REQUIRED","REVALIDATION_REQUIRED"].includes(p.disposition));
  const scoped=campaigns.reduce((a,c)=>a+c.scopedCompanies,0),opps=campaigns.reduce((a,c)=>a+c.materialisedOpportunities,0),actionable=campaigns.reduce((a,c)=>a+countFromObject(c.dispositionCounts,"ACTIONABLE"),0);
  const narrative=await marketRouteConversationServiceFromEnvironment().commandCentre(model);const stages=productPipeline({activation,campaign});const current=stages.find(s=>s.status==="ACTIVE"||s.status==="ATTENTION")??stages.at(-1);
  const marketName=campaigns.find(c=>c.campaignId===activeCampaignId)?.name??campaigns[0]?.name??"your market";

  return <div className="mr-command-centre-v2">
    <PageHeader eyebrow="YOUR MARKETROUTE" title="I'm working" accent={`${marketName}.`} description="MarketRoute researches the market, reduces it to real opportunities and resolves the routes you can actually use. You can leave at any time — the work continues from persisted state." actions={<div className="mr-header-badge-row"><StatusBadge label={commercial.mode==="PAID"?(commercial.planName??"Paid plan"):commercial.mode==="DISCOVERY_FREE"?"Discovery access":"Full access"} tone={commercial.mode==="DISCOVERY_FREE"?"blue":"green"}/>{["OWNER","ADMIN"].includes(workspace.role)&&<Link className="mr-button mr-button--secondary" href="/app/campaigns/new" prefetch>Add campaign <Icon name="arrow" size={14}/></Link>}</div>}/>

    <ProductPipeline stages={stages}/>

    <section className="mr-command-centre-v2__brief-grid">
      <MarketRouteNarrativeCard narrative={narrative} eyebrow="MARKETROUTE BRIEF"/>
      <aside className="mr-now-card"><div className="mr-now-card__top"><span>CURRENT FOCUS</span><i className={`is-${(current?.status??"WAITING").toLowerCase()}`}/></div><h2>{current?.label??"Ready"}</h2><p>{current?.detail??"Your current market is saved."}</p><dl><div><dt>Ready now</dt><dd>{ready.length}</dd></div><div><dt>Ready opportunities</dt><dd>{ready.length}</dd></div><div><dt>Still researching</dt><dd>{researchNeeded.length}</dd></div><div><dt>Still checking</dt><dd>{researchNeeded.length}</dd></div></dl>{current&&<Link href={current.href} prefetch>Open current stage <Icon name="arrow" size={14}/></Link>}</aside>
    </section>

    {commercial.mode==="DISCOVERY_FREE"&&commercial.lockedCount>0&&<Link className="mr-upgrade-banner mr-upgrade-banner--premium" href="/app/opportunities" prefetch><div><Icon name="spark" size={18}/><span><strong>{commercial.lockedCount} new opportunit{commercial.lockedCount===1?"y is":"ies are"} waiting.</strong><small>MarketRoute has finished the research. Upgrade to reveal the company intelligence and contact routes.</small></span></div><b>Unlock now →</b></Link>}

    <section className="mr-command-centre-v2__metrics">
      <MetricCard label="Companies in market" value={String(scoped)} meta="Relevant organisations currently in scope" icon={<Icon name="companies"/>}/>
      <MetricCard label="Opportunities found" value={String(opps)} meta="Companies with a commercial case" icon={<Icon name="opportunities"/>}/>
      <MetricCard label="Ready to pursue" value={String(actionable)} meta="Current route and buyer access established" icon={<Icon name="route"/>} accent/>
      <MetricCard label="Ready opportunities" value={String(ready.length)} meta="MarketRoute has completed the commercial and route checks" icon={<Icon name="check"/>}/>
    </section>

    <Panel className="mr-ready-opportunity-panel"><SectionHeading eyebrow="WHAT I'VE FOUND" title={ready.length?`${ready.length} opportunit${ready.length===1?"y is":"ies are"} ready to pursue`:"I'm still resolving the strongest opportunities"} description={ready.length?"These have the current commercial case and contact route required to act. Start here.":"As routes become current, they will move here automatically."}/>{ready.length===0?<EmptyState icon="opportunities" title="No ready opportunity yet" body="MarketRoute is still evaluating the companies already in scope. You do not need to keep this page open."/>:<div className="mr-opportunity-spotlight-grid">{ready.slice(0,4).map(p=><Link className="mr-opportunity-spotlight" href={`/app/opportunities/${p.campaignId}/${p.companyId}`} prefetch key={p.companyId}><div className="mr-opportunity-spotlight__head"><span>READY</span><StatusBadge compact label={commercialVerdict(p.disposition,p.executableNow)} tone="green"/></div><h3>{p.companyName}</h3><p>{p.canonicalDomain??"Company identity established"}</p><div><span><Icon name="route" size={14}/>{p.authorisedRoutes} ready route{p.authorisedRoutes===1?"":"s"}</span><b>Open opportunity <Icon name="arrow" size={13}/></b></div></Link>)}</div>}</Panel>

    <Panel emphasis="quiet"><SectionHeading eyebrow="YOUR MARKET" title="The market briefs MarketRoute is working from" description="Each campaign keeps one commercial market focused. Add another whenever you want to pursue a separate market; your plan controls how many can stay live at once."/>{campaigns.length===0?<EmptyState icon="campaigns" title="No live market" body="Start a market brief and MarketRoute will build the pipeline from there."/>:<div className="mr-live-card-list">{campaigns.map(c=><Link className="mr-live-card" href={`/app/campaigns/${c.campaignId}`} prefetch key={c.campaignId}><div className="mr-live-card__main"><span className="mr-live-card__seller">{c.sellerName}</span><div className="mr-live-card__title"><strong>{c.name}</strong><StatusBadge compact label={c.workflowState==="ACTIVE"?"Working":"Paused"} title={c.workflowState} tone={c.workflowState==="ACTIVE"?"green":"slate"}/></div><p>{c.objectiveText??"Commercial objective pending."}</p></div><dl><div><dt>Companies</dt><dd>{c.scopedCompanies}</dd></div><div><dt>Opportunities</dt><dd>{c.materialisedOpportunities}</dd></div><div><dt>Routes ready</dt><dd>{countFromObject(c.dispositionCounts,"ACTIONABLE")}</dd></div><div><dt>Opportunities ready</dt><dd>{countFromObject(c.workflowCounts,"REVIEWABLE")+countFromObject(c.workflowCounts,"APPROVED")}</dd></div></dl><span className="mr-live-card__open">Open market →</span></Link>)}</div>}</Panel>
  </div>;
}
