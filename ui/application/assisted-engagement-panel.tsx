import { asObject,booleanValue,formatDateTime,text } from "@/application/read-model/presentation";
import type { JsonObject } from "@/application/read-model/contracts";
import { CopyValueButton } from "@/ui/primitives/copy-value-button";
import { EmptyState } from "@/ui/application/empty-state";
import { humanStatus } from "@/ui/application/language";
import { Icon } from "@/ui/icons";
import { Panel,SectionHeading } from "@/ui/primitives/panel";
import { StatusBadge } from "@/ui/primitives/status-badge";

function safeActionHref(channel:string,value:string,subject:string|null,body:string|null):string|null{
  if(channel==="EMAIL"){
    if(!value.includes("@"))return null;
    const query=new URLSearchParams();if(subject)query.set("subject",subject);if(body)query.set("body",body);
    return `mailto:${value}${query.size?`?${query.toString()}`:""}`;
  }
  if(channel==="PHONE"){
    const cleaned=value.replace(/[^+0-9*#;,]/g,"");return cleaned?`tel:${cleaned}`:null;
  }
  if(["LINKEDIN","CONTACT_FORM","OTHER"].includes(channel)){
    try{const url=new URL(value);return ["http:","https:"].includes(url.protocol)?url.toString():null;}catch{return null;}
  }
  return null;
}
function actionLabel(channel:string){return channel==="EMAIL"?"Open email":channel==="PHONE"?"Call":channel==="LINKEDIN"?"Open LinkedIn":channel==="CONTACT_FORM"?"Open contact form":"Open route";}
function actionIcon(channel:string):"mail"|"phone"|"external"{return channel==="EMAIL"?"mail":channel==="PHONE"?"phone":"external";}

export function AssistedEngagementPanel({engagement,opportunityId,pathFingerprint,returnHref,canMutate,paidAccess}:{engagement:JsonObject;opportunityId:string|null;pathFingerprint:string|null;returnHref:string;canMutate:boolean;paidAccess:boolean}){
  const strategy=asObject(engagement.strategy),message=asObject(engagement.message),review=asObject(engagement.aiReview),approval=asObject(engagement.approval),manual=asObject(engagement.manualAction),actions=asObject(engagement.actions);
  const messageId=typeof message.messageId==="string"?message.messageId:null;
  const currentPath=typeof strategy.pathFingerprint==="string"?strategy.pathFingerprint:pathFingerprint;
  const channel=text(strategy.channel,"");
  const accessPoint=text(strategy.accessPointValue,"");
  const subject=typeof message.subjectText==="string"?message.subjectText:null;
  const body=typeof message.bodyText==="string"?message.bodyText:null;
  const reviewVerdict=text(review.verdict,"Pending");
  const approved=text(approval.decision,"")==="APPROVE"&&text(approval.mode,"")==="HUMAN";
  const actionHref=channel&&accessPoint?safeActionHref(channel,accessPoint,subject,body):null;
  const contacted=typeof manual.manualActionId==="string";
  const canGenerate=booleanValue(actions.canGenerateDraft)&&Boolean(opportunityId&&pathFingerprint);
  const canApprove=booleanValue(actions.canApproveMessage)&&Boolean(messageId&&opportunityId);
  const canMark=booleanValue(actions.canMarkContacted)&&Boolean(messageId&&opportunityId&&currentPath);

  return <Panel className="mr-assisted-engagement-panel">
    <div className="mr-assisted-engagement-heading">
      <SectionHeading eyebrow="ASSISTED ENGAGEMENT" title={contacted?"Contact recorded":"Prepare the next move"} description="MarketRoute prepares and checks the outreach. You choose the channel and make the final external contact yourself."/>
      <StatusBadge label="Human sends" tone="blue"/>
    </div>

    {contacted&&<div className="mr-assisted-engagement-success"><Icon name="check" size={18}/><div><strong>Marked contacted</strong><span>{formatDateTime(manual.occurredAt)} · {humanStatus(text(manual.channel,"manual contact"))}</span></div></div>}

    {!messageId&&!contacted&&<>
      {canGenerate&&paidAccess&&canMutate?<form className="mr-message-actions" action={`/api/engagement/opportunities/${opportunityId}/generate`} method="post"><input type="hidden" name="pathFingerprint" value={pathFingerprint??""}/><input type="hidden" name="returnTo" value={returnHref}/><button className="mr-button mr-button--primary" type="submit">Prepare message</button></form>:
      canGenerate&&!paidAccess?<div className="mr-assisted-engagement-note"><Icon name="shield" size={16}/><div><strong>Message preparation is included with a paid plan.</strong><span>Your free routes remain usable above; MarketRoute simply does not spend additional AI credits drafting outreach on the free run.</span></div></div>:
      <EmptyState icon="engagement" title="No message prepared yet" body="MarketRoute will prepare outreach as soon as this opportunity has a current authorised route and is system-ready."/>}
    </>}

    {messageId&&<div className="mr-assisted-draft">
      <div className="mr-assisted-draft__meta"><div><span>CHANNEL</span><strong>{humanStatus(channel||"Prepared")}</strong></div><div><span>LANGUAGE REVIEW</span><StatusBadge compact label={humanStatus(reviewVerdict)} tone={reviewVerdict==="PASS"?"green":reviewVerdict==="BLOCK"?"red":"amber"}/></div><div><span>HUMAN APPROVAL</span><strong>{approved?"Approved":text(approval.decision,"Pending")}</strong></div></div>
      {subject&&<div className="mr-assisted-draft__subject"><span>Subject</span><strong>{subject}</strong></div>}
      {body&&<div className="mr-assisted-draft__body"><span>Prepared message</span><p>{body}</p><CopyValueButton value={body} label="Copy message"/></div>}
      {canMutate&&canApprove&&!contacted&&<form className="mr-message-actions" action={`/api/engagement/messages/${messageId}/approval`} method="post"><input type="hidden" name="opportunityId" value={opportunityId??""}/><input type="hidden" name="returnTo" value={returnHref}/><button className="mr-button mr-button--primary" name="decision" value="APPROVE" type="submit">Approve message</button><button className="mr-button mr-button--ghost" name="decision" value="REJECT" type="submit">Reject</button></form>}
      {approved&&!contacted&&<div className="mr-assisted-action-desk">
        <div><span>YOUR ACTION</span><strong>Contact them yourself</strong><p>MarketRoute will never send this automatically in assisted mode.</p></div>
        <div className="mr-assisted-action-desk__buttons">
          {actionHref&&<a className="mr-button mr-button--primary" href={actionHref} target={channel==="EMAIL"||channel==="PHONE"?undefined:"_blank"} rel={channel==="EMAIL"||channel==="PHONE"?undefined:"noreferrer"}><Icon name={actionIcon(channel)} size={14}/>{actionLabel(channel)}</a>}
          {accessPoint&&<CopyValueButton value={accessPoint} label={channel==="EMAIL"?"Copy email":channel==="PHONE"?"Copy number":"Copy route"}/>} 
        </div>
        {canMutate&&canMark&&<form className="mr-assisted-mark-form" action={`/api/engagement/opportunities/${opportunityId}/manual`} method="post"><input type="hidden" name="pathFingerprint" value={currentPath??""}/><input type="hidden" name="messageId" value={messageId}/><input type="hidden" name="returnTo" value={returnHref}/><label><span>Optional note</span><input name="note" maxLength={1000} placeholder="e.g. Sent by email, follow up Friday"/></label><button className="mr-button mr-button--secondary" type="submit"><Icon name="check" size={14}/>Mark contacted</button></form>}
      </div>}
    </div>}
  </Panel>;
}
