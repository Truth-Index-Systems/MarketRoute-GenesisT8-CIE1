import { commandCentre,resolveCampaignId } from "@/app/app/_lib/data";
import { workspaceSessionOrRedirect } from "@/app/app/_lib/session";
import { applicationReadServiceFromEnvironment } from "@/application/read-model/service";
import { asObject,asObjectArray,campaignListItem,formatDateTime,money,statusTone,text } from "@/application/read-model/presentation";
import { CampaignSwitcher,EmptyState,humanStatus,IntelligenceTable,MetricCard,PageHeader,Panel,SectionHeading,StatusBadge } from "@/ui";

export default async function Research({searchParams}:{searchParams:Promise<Record<string,string|string[]|undefined>>}){
  const query=await searchParams;
  const {workspace}=await workspaceSessionOrRedirect();
  const cc=await commandCentre(workspace.organisationId);
  const campaigns=asObjectArray(cc.campaigns).map(campaignListItem);
  const campaignId=resolveCampaignId(cc,typeof query.campaign==="string"?query.campaign:null);
  if(!campaignId)return <div><PageHeader eyebrow="RESEARCH" title="Research the gaps" accent="that change a decision." description="MarketRoute uses Genesis to investigate explicit commercial, route and contact unknowns rather than researching indiscriminately."/><Panel><EmptyState icon="research" title="No campaign available" body="Research activity is campaign-scoped."/></Panel></div>;
  const model=await applicationReadServiceFromEnvironment().researchActivity({organisationId:workspace.organisationId,campaignId});
  const budget=asObject(model.budget),policy=asObject(model.policy),work=asObjectArray(model.workUnits),runs=asObjectArray(model.schedulerRuns);
  return <div>
    <PageHeader eyebrow="RESEARCH" title="Research only what" accent="changes the decision." description="Genesis spends against explicit knowledge gaps and currentness problems. Budget limits resource use; they never change the commercial reasoning itself." actions={<CampaignSwitcher campaigns={campaigns.map(c=>({campaignId:c.campaignId,name:c.name,workflowState:c.workflowState}))} current={campaignId} action="/app/research"/>}/>
    <section className="mr-metric-grid"><MetricCard label="Daily research budget" value={money(policy.dailyBudgetUsd)} meta="Maximum resource allowance"/><MetricCard label="Used today" value={money(budget.spentTodayUsd)} meta="Completed research spend"/><MetricCard label="Reserved" value={money(budget.reservedTodayUsd)} meta="Committed to queued work"/><MetricCard label="Jobs in progress" value={String(budget.activeJobs??0)} meta="Current active work units" accent/></section>
    <Panel><SectionHeading eyebrow="What Genesis is working on" title="Current research queue" description="Decision blockers come first, followed by currentness repair, expiring knowledge and useful enrichment."/>{work.length===0?<EmptyState icon="research" title="Research queue is clear" body="There are no recent work units for this campaign."/>:<IntelligenceTable head={["Area","Priority","What MarketRoute is doing","Why it matters","Status","Maximum cost"]}>{work.map(w=>{const job=asObject(w.job);const status=text(job.status,"NO JOB");return <tr key={text(w.workUnitId)}><td><span className="mr-table-state" title={text(w.layer)}>{humanStatus(text(w.layer))}</span></td><td>{humanStatus(text(w.tier))}</td><td><strong className="mr-table-primary">{humanStatus(text(w.action))}</strong></td><td>{humanStatus(text(w.reasonCode))}</td><td><StatusBadge compact label={humanStatus(status)} title={status} tone={statusTone(status)}/></td><td>{money(w.costCeilingUsd)}</td></tr>})}</IntelligenceTable>}</Panel>
    <Panel emphasis="quiet"><SectionHeading eyebrow="System history" title="Recent research cycles" description="The scheduler uses exclusive lease ownership so autonomous work remains single-owner and recoverable."/>{runs.length===0?<EmptyState icon="clock" title="No research cycles recorded" body="No Genesis research cycle has been recorded yet."/>:<div className="mr-run-list">{runs.map(r=>{const status=text(r.status);return <div key={text(r.runId)}><StatusBadge compact label={humanStatus(status)} title={status} tone={statusTone(status)}/><span>{formatDateTime(r.startedAt)}</span><strong>{text(r.runId).slice(0,8)}</strong></div>})}</div>}</Panel>
  </div>
}
