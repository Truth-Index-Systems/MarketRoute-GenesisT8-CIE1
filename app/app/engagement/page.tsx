import Link from "next/link";
import { commandCentre,resolveCampaignId } from "@/app/app/_lib/data";
import { workspaceSessionOrRedirect } from "@/app/app/_lib/session";
import { applicationReadServiceFromEnvironment } from "@/application/read-model/service";
import { commercialAccessServiceFromEnvironment } from "@/application/commercial/service";
import { asObject,asObjectArray,booleanValue,campaignListItem,formatDateTime,text } from "@/application/read-model/presentation";
import { CampaignSwitcher,CopyValueButton,EmptyState,humanStatus,Icon,MetricCard,PageHeader,Panel,StatusBadge } from "@/ui";

function safeActionHref(channel:string,value:string,subject:string|null,body:string|null):string|null{
  if(channel==="EMAIL"){
    if(!value.includes("@"))return null;const q=new URLSearchParams();if(subject)q.set("subject",subject);if(body)q.set("body",body);return `mailto:${value}${q.size?`?${q.toString()}`:""}`;
  }
  if(channel==="PHONE"){const cleaned=value.replace(/[^+0-9*#;,]/g,"");return cleaned?`tel:${cleaned}`:null;}
  if(["LINKEDIN","CONTACT_FORM","OTHER"].includes(channel)){try{const u=new URL(value);return ["https:","http:"].includes(u.protocol)?u.toString():null;}catch{return null;}}
  return null;
}
function actionLabel(channel:string){return channel==="EMAIL"?"Open email":channel==="PHONE"?"Call":channel==="LINKEDIN"?"Open LinkedIn":channel==="CONTACT_FORM"?"Open contact form":"Open route";}

export default async function Engagement({searchParams}:{searchParams:Promise<Record<string,string|string[]|undefined>>}){
  const query=await searchParams;
  const {workspace}=await workspaceSessionOrRedirect();
  const cc=await commandCentre(workspace.organisationId);
  const campaigns=asObjectArray(cc.campaigns).map(campaignListItem);
  const campaignId=resolveCampaignId(cc,typeof query.campaign==="string"?query.campaign:null);
  if(!campaignId)return <div><PageHeader eyebrow="OUTREACH" title="Your" accent="outreach desk." description="Use the routes MarketRoute has found, prepare messages and keep every external contact under your control."/><Panel><EmptyState icon="engagement" title="No active market" body="Outreach becomes available when an opportunity is ready to contact."/></Panel></div>;

  const [model,access]=await Promise.all([
    applicationReadServiceFromEnvironment().engagementIndex({organisationId:workspace.organisationId,campaignId,limit:200}),
    commercialAccessServiceFromEnvironment().access(workspace.organisationId)
  ]);
  const canMutate=workspace.role!=="VIEWER";
  const paidAccess=access.mode==="PAID"||access.mode==="FULL";
  const all=asObjectArray(model.items);
  const items=all.filter(item=>{const e=asObject(item.engagement);return ["REVIEWABLE","APPROVED","ENGAGED"].includes(text(item.workflowState,""))||Object.keys(e).length>0;});
  const prepared=items.filter(item=>typeof asObject(asObject(item.engagement).message).messageId==="string").length;
  const ready=items.filter(item=>booleanValue(asObject(asObject(item.engagement).actions).canMarkContacted)).length;
  const contacted=items.filter(item=>typeof asObject(asObject(item.engagement).manualAction).manualActionId==="string").length;
  const awaiting=items.filter(item=>{const e=asObject(item.engagement),review=asObject(e.aiReview),approval=asObject(e.approval);return text(review.verdict,"")==="PASS"&&text(approval.decision,"")!=="APPROVE"&&typeof asObject(e.message).messageId==="string";}).length;
  const actionError=typeof query.actionError==="string"?decodeURIComponent(query.actionError):null;

  return <div>
    <PageHeader eyebrow="OUTREACH" title="Turn strong opportunities" accent="into conversations." description="MarketRoute can prepare the message and put a usable contact route in front of you. Nothing is sent automatically." actions={<CampaignSwitcher campaigns={campaigns.map(c=>({campaignId:c.campaignId,name:c.name,workflowState:c.workflowState}))} current={campaignId} action="/app/engagement"/>}/>
    {actionError&&<div className="mr-alert mr-alert--error"><Icon name="shield" size={16}/><span>{actionError}</span></div>}
    <div className="mr-assisted-mode-banner"><div><Icon name="shield" size={18}/><span>YOU STAY IN CONTROL</span><strong>Nothing gets sent without you.</strong></div><p>MarketRoute can prepare and check the message. You choose when, where and whether to send it.</p></div>

    <section className="mr-metric-grid">
      <MetricCard label="Ready to contact" value={String(ready)} meta="Message and route ready" icon={<Icon name="engagement"/>} accent/>
      <MetricCard label="Prepared" value={String(prepared)} meta="Messages ready to review" icon={<Icon name="mail"/>}/>
      <MetricCard label="Needs approval" value={String(awaiting)} meta="Waiting for your approval" icon={<Icon name="shield"/>}/>
      <MetricCard label="Contacted" value={String(contacted)} meta="Conversations you recorded" icon={<Icon name="check"/>}/>
    </section>

    {!paidAccess&&<div className="mr-assisted-engagement-note"><Icon name="shield" size={16}/><div><strong>Your free contact routes are yours to use.</strong><span>Message preparation is available on paid plans. You can still use email, phone and LinkedIn routes directly from Opportunities.</span></div></div>}

    {items.length===0?<Panel><EmptyState icon="engagement" title="Nothing is ready for outreach yet" body="When an opportunity has a usable contact route, it will appear here."/></Panel>:
    <section className="mr-engagement-desk-grid">{items.map(item=>{
      const e=asObject(item.engagement),strategy=asObject(e.strategy),message=asObject(e.message),review=asObject(e.aiReview),approval=asObject(e.approval),manual=asObject(e.manualAction),actions=asObject(e.actions);
      const opportunityId=text(item.opportunityId,"");const companyId=text(item.companyId,"");const href=`/app/opportunities/${campaignId}/${companyId}`;
      const messageId=typeof message.messageId==="string"?message.messageId:null;const path=typeof strategy.pathFingerprint==="string"?strategy.pathFingerprint:null;
      const channel=text(strategy.channel,"");const accessPoint=text(strategy.accessPointValue,"");const subject=typeof message.subjectText==="string"?message.subjectText:null;const body=typeof message.bodyText==="string"?message.bodyText:null;
      const approved=text(approval.decision,"")==="APPROVE"&&text(approval.mode,"")==="HUMAN";const contactedNow=typeof manual.manualActionId==="string";
      const external=channel&&accessPoint?safeActionHref(channel,accessPoint,subject,body):null;
      return <article className={`mr-engagement-desk-card${contactedNow?" mr-engagement-desk-card--done":""}`} key={opportunityId}>
        <header><div><span>{contactedNow?"CONTACTED":approved?"READY TO ACT":messageId?"MESSAGE PREPARED":"READY TO CONTACT"}</span><h2>{text(item.companyName)}</h2><p>{text(item.canonicalDomain,"Direct company route")}</p></div><StatusBadge label={contactedNow?"Contacted":humanStatus(text(item.workflowState))} tone={contactedNow?"green":approved?"blue":"slate"}/></header>
        {contactedNow?<div className="mr-engagement-desk-card__done"><Icon name="check" size={18}/><div><strong>Contact recorded</strong><span>{formatDateTime(manual.occurredAt)} · {humanStatus(text(manual.channel,"Manual contact"))}</span></div></div>:
        !messageId?<div className="mr-engagement-desk-card__empty"><p>{paidAccess?"Open the opportunity and choose the authorised route MarketRoute should use to prepare the message.":"Use the contact route directly, or upgrade if you want MarketRoute to prepare the message too."}</p><Link className="mr-button mr-button--secondary" href={href}>{paidAccess?"Prepare message":"See contact routes"}<Icon name="arrow" size={14}/></Link></div>:
        <>
          <div className="mr-engagement-desk-card__status"><span>{humanStatus(channel)}</span><span>Message check: <strong>{humanStatus(text(review.verdict,"Pending"))}</strong></span><span>Your approval: <strong>{approved?"Approved":humanStatus(text(approval.decision,"Pending"))}</strong></span></div>
          {subject&&<div className="mr-engagement-desk-card__subject"><span>Subject</span><strong>{subject}</strong></div>}
          {body&&<div className="mr-engagement-desk-card__message"><p>{body}</p><CopyValueButton value={body} label="Copy message"/></div>}
          <div className="mr-engagement-desk-card__actions">
            {canMutate&&booleanValue(actions.canApproveMessage)&&<form action={`/api/engagement/messages/${messageId}/approval`} method="post"><input type="hidden" name="opportunityId" value={opportunityId}/><input type="hidden" name="returnTo" value={`/app/engagement?campaign=${campaignId}`}/><button className="mr-button mr-button--primary" name="decision" value="APPROVE" type="submit">Approve message</button><button className="mr-button mr-button--ghost" name="decision" value="REJECT" type="submit">Reject</button></form>}
            {approved&&external&&<a className="mr-button mr-button--primary" href={external} target={channel==="EMAIL"||channel==="PHONE"?undefined:"_blank"} rel={channel==="EMAIL"||channel==="PHONE"?undefined:"noreferrer"}>{actionLabel(channel)}<Icon name="external" size={14}/></a>}
            {approved&&accessPoint&&<CopyValueButton value={accessPoint} label={channel==="EMAIL"?"Copy email":channel==="PHONE"?"Copy number":"Copy route"}/>} 
            <Link className="mr-button mr-button--ghost" href={href}>Open opportunity</Link>
          </div>
          {canMutate&&booleanValue(actions.canMarkContacted)&&messageId&&path&&<form className="mr-assisted-mark-form" action={`/api/engagement/opportunities/${opportunityId}/manual`} method="post"><input type="hidden" name="pathFingerprint" value={path}/><input type="hidden" name="messageId" value={messageId}/><input type="hidden" name="returnTo" value={`/app/engagement?campaign=${campaignId}`}/><label><span>Optional note</span><input name="note" maxLength={1000} placeholder="e.g. Sent by email, follow up Friday"/></label><button className="mr-button mr-button--secondary" type="submit"><Icon name="check" size={14}/>Mark contacted</button></form>}
        </>}
      </article>})}</section>}
  </div>;
}
