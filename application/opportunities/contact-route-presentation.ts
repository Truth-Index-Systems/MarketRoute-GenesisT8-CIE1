import type { JsonObject, RouteDisplayReadModel } from "../read-model/contracts";

export type ContactChannelKind="EMAIL"|"PHONE"|"PROFILE"|"WEB"|"OTHER";
export interface ContactChannelView{
  key:string;
  kind:ContactChannelKind;
  sourceKind:string;
  value:string;
  href:string|null;
  copyable:boolean;
  evidenceSnapshotId:string|null;
  pathFingerprint:string;
}
export interface ContactRouteView{
  key:string;
  mode:"NAMED_CONTACT"|"ORGANISATIONAL_ROUTE";
  personId:string|null;
  personName:string|null;
  roleTitles:string[];
  authorised:boolean;
  firstOrdinal:number;
  channels:ContactChannelView[];
  identityEvidenceSnapshotId:string|null;
  employmentEvidenceSnapshotId:string|null;
  roleEvidenceSnapshotId:string|null;
  routeNextRevalidationAt:string|null;
  contactNextRevalidationAt:string|null;
  explanation:string;
}
export interface ContactRoutePresentation{
  ready:ContactRouteView[];
  researching:ContactRouteView[];
  companyWebsiteHref:string|null;
}

function row(value:unknown):Record<string,unknown>{return value&&typeof value==="object"&&!Array.isArray(value)?value as Record<string,unknown>:{};}
function rows(value:unknown):Record<string,unknown>[] {return Array.isArray(value)?value.map(row):[];}
function text(value:unknown):string|null{return typeof value==="string"&&value.trim()?value.trim():null;}
function strings(value:unknown):string[]{return Array.isArray(value)?value.filter((v):v is string=>typeof v==="string"&&Boolean(v.trim())).map(v=>v.trim()):[];}
function bool(value:unknown):boolean{return value===true;}
function ordinal(value:unknown,index:number):number{const n=Number(value);return Number.isFinite(n)&&n>0?n:index+1;}
function first(values:unknown):string|null{return strings(values)[0]??null;}
function webHref(value:string|null):string|null{
  if(!value)return null;
  const candidate=/^https?:\/\//i.test(value)?value:`https://${value}`;
  try{const url=new URL(candidate);return url.protocol==="http:"||url.protocol==="https:"?url.toString():null;}catch{return null;}
}
function mailHref(value:string|null):string|null{return value&&/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value)?`mailto:${value}`:null;}
function phoneHref(value:string|null):string|null{return value&&/[0-9]/.test(value)?`tel:${value.replace(/[^+0-9*#pw,;]/gi,"")}`:null;}
function channelKind(kind:string):ContactChannelKind{
  if(["PERSONAL_EMAIL","GENERIC_EMAIL","DEPARTMENT_EMAIL"].includes(kind))return "EMAIL";
  if(["PERSONAL_PHONE","SWITCHBOARD"].includes(kind))return "PHONE";
  if(kind==="LINKEDIN")return "PROFILE";
  if(["CONTACT_FORM","DEPARTMENT_FORM"].includes(kind))return "WEB";
  return "OTHER";
}
function channelHref(kind:string,value:string|null):string|null{
  if(!value)return null;
  const category=channelKind(kind);
  if(category==="EMAIL")return mailHref(value);
  if(category==="PHONE")return phoneHref(value);
  if(category==="PROFILE"||category==="WEB")return webHref(value);
  return webHref(value);
}
function uniqueChannels(channels:ContactChannelView[]):ContactChannelView[]{
  const seen=new Set<string>();return channels.filter(channel=>{const key=`${channel.kind}:${channel.value.toLowerCase()}`;if(seen.has(key))return false;seen.add(key);return true;});
}
function explanation(mode:ContactRouteView["mode"],personName:string|null,roles:string[],channels:ContactChannelView[],authorised:boolean):string{
  if(!authorised)return personName?`I have identified ${personName} in the route, but I am still validating the current contact evidence before I mark it ready.`:"I have identified a structural way into this organisation, but I am still validating the contact route before I mark it ready.";
  if(mode==="ORGANISATIONAL_ROUTE")return "This is a current organisational route that can be used without relying on a named-person identity.";
  const role=roles.length?` as ${roles.join(" / ")}`:"";const methods=[...new Set(channels.map(c=>c.kind.toLowerCase()))];
  return `I have verified ${personName??"this contact"}${role} and bound the current ${methods.length?methods.join(" and "):"contact"} route${methods.length===1?"":"s"} to that identity.`;
}

export function contactRoutePresentation(model:RouteDisplayReadModel):ContactRoutePresentation{
  const grouped=new Map<string,ContactRouteView>();
  rows(model.paths).forEach((path,index)=>{
    const bindingMode=text(path.mode)==="ORGANISATIONAL_ROUTE"?"ORGANISATIONAL_ROUTE":"NAMED_CONTACT";
    const personId=text(path.personId),personName=text(path.personName),roleTitles=strings(path.roleTitles),authorised=bool(path.authorised);
    const terminal=row(path.terminalAccessPoint);const accessPointId=text(terminal.accessPointId)??text(path.terminalAccessPointId)??`path-${index}`;const sourceKind=text(terminal.accessPointKind)??"OTHER";const value=text(terminal.canonicalValue);
    const evidence=row(path.evidence);const channelEvidence=first(evidence.channelSnapshotIds);
    const fingerprint=text(path.pathFingerprint)??`path-${index}`;
    const statusKey=authorised?"ready":"research";
    const groupKey=personId?`${statusKey}:person:${personId}`:bindingMode==="ORGANISATIONAL_ROUTE"?`${statusKey}:org:${accessPointId}`:`${statusKey}:path:${fingerprint}`;
    const existing=grouped.get(groupKey);
    const channel:ContactChannelView|null=value?{key:accessPointId,kind:channelKind(sourceKind),sourceKind,value,href:channelHref(sourceKind,value),copyable:["EMAIL","PHONE"].includes(channelKind(sourceKind)),evidenceSnapshotId:channelEvidence,pathFingerprint:fingerprint}:null;
    if(existing){
      existing.authorised=existing.authorised||authorised;existing.firstOrdinal=Math.min(existing.firstOrdinal,ordinal(path.ordinal,index));
      if(channel)existing.channels=uniqueChannels([...existing.channels,channel]);
      if(!existing.identityEvidenceSnapshotId)existing.identityEvidenceSnapshotId=first(evidence.identitySnapshotIds);
      if(!existing.employmentEvidenceSnapshotId)existing.employmentEvidenceSnapshotId=first(evidence.employmentSnapshotIds);
      if(!existing.roleEvidenceSnapshotId)existing.roleEvidenceSnapshotId=first(evidence.roleSnapshotIds);
      if(!existing.routeNextRevalidationAt)existing.routeNextRevalidationAt=text(path.routeNextRevalidationAt);
      if(!existing.contactNextRevalidationAt)existing.contactNextRevalidationAt=text(path.contactNextRevalidationAt);
      existing.explanation=explanation(existing.mode,existing.personName,existing.roleTitles,existing.channels,existing.authorised);
      return;
    }
    const channels=channel?[channel]:[];
    grouped.set(groupKey,{key:groupKey,mode:bindingMode,personId,personName,roleTitles,authorised,firstOrdinal:ordinal(path.ordinal,index),channels,identityEvidenceSnapshotId:first(evidence.identitySnapshotIds),employmentEvidenceSnapshotId:first(evidence.employmentSnapshotIds),roleEvidenceSnapshotId:first(evidence.roleSnapshotIds),routeNextRevalidationAt:text(path.routeNextRevalidationAt),contactNextRevalidationAt:text(path.contactNextRevalidationAt),explanation:explanation(bindingMode,personName,roleTitles,channels,authorised)});
  });
  const all=[...grouped.values()].sort((a,b)=>a.firstOrdinal-b.firstOrdinal);
  const company=row((model as RouteDisplayReadModel&{company?:JsonObject}).company);const website=text(company.websiteUrl)??text(company.canonicalDomain);
  return {ready:all.filter(route=>route.authorised),researching:all.filter(route=>!route.authorised),companyWebsiteHref:webHref(website)};
}
