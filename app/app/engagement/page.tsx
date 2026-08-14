import { commandCentre,resolveCampaignId } from "@/app/app/_lib/data";
import { workspaceSessionOrRedirect } from "@/app/app/_lib/session";
import { applicationReadServiceFromEnvironment } from "@/application/read-model/service";
import { asObject,asObjectArray,campaignListItem,formatDateTime,statusTone,text } from "@/application/read-model/presentation";
import { CampaignSwitcher,EmptyState,humanStatus,IntelligenceTable,PageHeader,Panel,StatusBadge } from "@/ui";

export default async function Engagement({searchParams}:{searchParams:Promise<Record<string,string|string[]|undefined>>}){
  const query=await searchParams;
  const {workspace}=await workspaceSessionOrRedirect();
  const cc=await commandCentre(workspace.organisationId);
  const campaigns=asObjectArray(cc.campaigns).map(campaignListItem);
  const campaignId=resolveCampaignId(cc,typeof query.campaign==="string"?query.campaign:null);
  if(!campaignId)return <div><PageHeader eyebrow="ENGAGEMENT" title="Outreach only when" accent="the opportunity is ready." description="Messages remain downstream of current commercial, route and contact authority."/><Panel><EmptyState icon="engagement" title="No campaign available" body="Engagement is scoped to a campaign."/></Panel></div>;
  const model=await applicationReadServiceFromEnvironment().engagementIndex({organisationId:workspace.organisationId,campaignId,limit:200});
  const items=asObjectArray(model.items);
  return <div>
    <PageHeader eyebrow="ENGAGEMENT" title="From approved opportunity" accent="to controlled outreach." description="See channel strategy, message review, approval and delivery without confusing any of them with the evidence that made the company worth pursuing." actions={<CampaignSwitcher campaigns={campaigns.map(c=>({campaignId:c.campaignId,name:c.name,workflowState:c.workflowState}))} current={campaignId} action="/app/engagement"/>}/>
    <div className="mr-policy-banner"><div><span>Message approval policy</span><strong>{model.policyMode==="AUTOPILOT"?"Autopilot after approval":"Human approval required"}</strong></div><StatusBadge label={humanStatus(model.policyMode)} title={model.policyMode} tone={model.policyMode==="AUTOPILOT"?"violet":"blue"}/><p>Autopilot never bypasses opportunity approval or the live R4 → R5 → R6 send-time authority check.</p></div>
    <Panel>{items.length===0?<EmptyState icon="engagement" title="No outreach in progress" body="Approved opportunities have not yet produced engagement strategies in this campaign."/>:<IntelligenceTable head={["Company","Opportunity state","Channel","Message review","Approval","Delivery"]}>{items.map(item=>{const e=asObject(item.engagement),strategy=asObject(e.strategy),review=asObject(e.aiReview),approval=asObject(e.approval),delivery=asObject(e.delivery);const reviewVerdict=review.verdict?text(review.verdict):null;const deliveryStatus=delivery.status?text(delivery.status):null;return <tr key={text(item.opportunityId)}><td><a href={`/app/opportunities/${campaignId}/${text(item.companyId)}`}><strong>{text(item.companyName)}</strong><small>{text(item.canonicalDomain,"No domain")}</small></a></td><td>{humanStatus(text(item.workflowState))}</td><td>{strategy.strategyId?humanStatus(text(strategy.channel)):"Not generated"}</td><td>{reviewVerdict?<StatusBadge compact label={humanStatus(reviewVerdict)} title={reviewVerdict} tone={statusTone(reviewVerdict)}/>:"Pending"}</td><td>{approval.decision?humanStatus(text(approval.decision)):"Pending"}</td><td>{deliveryStatus?<><StatusBadge compact label={humanStatus(deliveryStatus)} title={deliveryStatus} tone={statusTone(deliveryStatus)}/><small>{formatDateTime(delivery.finishedAt)}</small></>:"Not queued"}</td></tr>})}</IntelligenceTable>}</Panel>
  </div>
}
