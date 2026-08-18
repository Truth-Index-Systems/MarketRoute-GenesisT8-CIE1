import type { ContactChannelView,ContactRouteView } from "@/application/opportunities/contact-route-presentation";
import { formatDateTime } from "@/application/read-model/presentation";
import { CopyValueButton } from "@/ui/primitives/copy-value-button";
import { Icon } from "@/ui/icons";

function evidenceLink(snapshotId:string|null,returnHref:string,label:string){
  return snapshotId?<a className="mr-contact-evidence-link" href={`${returnHref}?claim=${encodeURIComponent(snapshotId)}`}><Icon name="shield" size={13}/>{label}</a>:null;
}
function external(channel:ContactChannelView,label:string){
  return channel.href?<a className="mr-contact-external" href={channel.href} target={channel.kind==="EMAIL"||channel.kind==="PHONE"?undefined:"_blank"} rel={channel.kind==="EMAIL"||channel.kind==="PHONE"?undefined:"noreferrer"}><Icon name={channel.kind==="EMAIL"?"mail":channel.kind==="PHONE"?"phone":"external"} size={14}/>{label}</a>:null;
}
function ContactValues({label,channels,empty,returnHref}:{label:string;channels:ContactChannelView[];empty:string;returnHref:string}){
  return <div className="mr-contact-method"><span>{label}</span>{channels.length===0?<div className="mr-contact-method__empty">{empty}</div>:channels.map(channel=><div className="mr-contact-value" key={`${channel.key}:${channel.value}`}><code>{channel.value}</code><div>{channel.copyable&&<CopyValueButton value={channel.value}/>} {channel.kind==="EMAIL"&&external(channel,"Email")} {channel.kind==="PHONE"&&external(channel,"Call")} {channel.evidenceSnapshotId&&evidenceLink(channel.evidenceSnapshotId,returnHref,"Source")}</div></div>)}</div>;
}

export function ContactRouteCard({route,returnHref,companyWebsiteHref,index}:{route:ContactRouteView;returnHref:string;companyWebsiteHref:string|null;index:number}){
  const emails=route.channels.filter(channel=>channel.kind==="EMAIL");
  const phones=route.channels.filter(channel=>channel.kind==="PHONE");
  const profiles=route.channels.filter(channel=>channel.kind==="PROFILE");
  const web=route.channels.filter(channel=>channel.kind==="WEB"||channel.kind==="OTHER");
  const title=route.personName??(route.mode==="ORGANISATIONAL_ROUTE"?"Organisation route":`Route ${index+1}`);
  const role=route.roleTitles.length?route.roleTitles.join(" · "):route.personName?"Current role checked":"Direct company route";
  const freshUntil=route.contactNextRevalidationAt??route.routeNextRevalidationAt;
  return <article className="mr-contact-route-card">
    <header><div className="mr-contact-route-card__identity"><div className="mr-contact-route-card__avatar"><Icon name={route.personName?"user":"companies"} size={19}/></div><div><span>{`CONTACT ROUTE ${index+1}`}</span><h3>{title}</h3><p>{role}</p></div></div><div className="mr-contact-route-card__ready"><i/>Ready</div></header>
    <div className="mr-contact-route-card__why"><Icon name="route" size={15}/><div><strong>Why this route works</strong><p>{route.explanation}</p></div></div>
    <div className="mr-contact-route-card__methods">
      <ContactValues label="Email" channels={emails} empty="Email not found yet" returnHref={returnHref}/>
      <ContactValues label="Phone" channels={phones} empty="Phone not found yet" returnHref={returnHref}/>
    </div>
    {(profiles.length>0||web.length>0||companyWebsiteHref)&&<div className="mr-contact-route-card__links">
      {profiles.map(channel=><span key={`${channel.key}:${channel.value}`}>{external(channel,"Open professional profile")}{channel.evidenceSnapshotId&&evidenceLink(channel.evidenceSnapshotId,returnHref,"Source")}</span>)}
      {web.map(channel=><span key={`${channel.key}:${channel.value}`}>{external(channel,channel.sourceKind.includes("FORM")?"Open contact form":"Open route")}{channel.evidenceSnapshotId&&evidenceLink(channel.evidenceSnapshotId,returnHref,"Source")}</span>)}
      {companyWebsiteHref&&<a className="mr-contact-external" href={companyWebsiteHref} target="_blank" rel="noreferrer"><Icon name="external" size={14}/>Company website</a>}
    </div>}
    <footer><div><Icon name="clock" size={13}/><span>{freshUntil?`Current until ${formatDateTime(freshUntil)}`:"MarketRoute keeps this route under review"}</span></div><div>{evidenceLink(route.identityEvidenceSnapshotId,returnHref,"Company")}{evidenceLink(route.employmentEvidenceSnapshotId,returnHref,"Employment")}{evidenceLink(route.roleEvidenceSnapshotId,returnHref,"Role")}</div></footer>
  </article>;
}
