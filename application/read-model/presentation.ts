import type { JsonObject, JsonValue } from "./contracts";

export function asObject(value:unknown):JsonObject { return value&&typeof value==="object"&&!Array.isArray(value)?value as JsonObject:{}; }
export function asArray(value:unknown):JsonValue[] { return Array.isArray(value)?value as JsonValue[]:[]; }
export function asObjectArray(value:unknown):JsonObject[] { return asArray(value).filter((v):v is JsonObject=>Boolean(v)&&typeof v==="object"&&!Array.isArray(v)); }
export function text(value:unknown,fallback="—"):string { return typeof value==="string"&&value.trim()?value:fallback; }
export function optionalText(value:unknown):string|null { return typeof value==="string"&&value.trim()?value:null; }
export function numberValue(value:unknown,fallback=0):number { return typeof value==="number"&&Number.isFinite(value)?value:typeof value==="string"&&value.trim()&&Number.isFinite(Number(value))?Number(value):fallback; }
export function booleanValue(value:unknown,fallback=false):boolean { return typeof value==="boolean"?value:fallback; }
export function percent(value:unknown):number { return Math.max(0,Math.min(100,numberValue(value,0))); }
export function shortFingerprint(value:unknown):string { const v=optionalText(value); return v?v.length>16?`${v.slice(0,8)}…${v.slice(-6)}`:v:"—"; }
export function formatDateTime(value:unknown):string { const v=optionalText(value); if(!v)return "—"; const d=new Date(v); if(!Number.isFinite(d.getTime()))return v; return new Intl.DateTimeFormat("en-GB",{day:"2-digit",month:"short",hour:"2-digit",minute:"2-digit",hour12:false,timeZoneName:"short"}).format(d); }
export function money(value:unknown):string { return `$${numberValue(value,0).toFixed(2)}`; }
export function countFromObject(value:unknown,key:string):number { return numberValue(asObject(value)[key],0); }

export function statusTone(value:string):"blue"|"green"|"amber"|"red"|"slate"|"violet" {
  if(["ACTIONABLE","AUTHORITY_READY","COMMERCIAL_CANDIDATE","ROUTE_STRUCTURALLY_OPEN","CONTACT_AUTHORISED","APPROVED","REVIEWABLE","SENT","SUCCEEDED","ACTIVE","KNOWN"].includes(value)) return "green";
  if(["SUPPORTED","RUNNING","RESERVED","PENDING","AUTOPILOT"].includes(value)) return "blue";
  if(["RESEARCH_REQUIRED","REVALIDATION_REQUIRED","CONTACT_RESEARCH_REQUIRED","ROUTE_RESEARCH_REQUIRED","RESEARCHING","PAUSED","DEFERRED","REWRITE"].includes(value)) return "amber";
  if(["NOT_ADMISSIBLE","CONTRADICTED","FAILED","BLOCK","REJECTED","BLOCKED_STALE","RECONCILIATION_REQUIRED","CLOSED","SUSPENDED"].includes(value)) return "red";
  if(["CONTACT_NOT_APPLICABLE","ROUTE_NOT_APPLICABLE","ARCHIVED","STALE","UNRESOLVED"].includes(value)) return "slate";
  return "violet";
}

export interface CampaignListItem { campaignId:string; name:string; workflowState:string; objectiveText:string|null; sellerName:string; scopedCompanies:number; materialisedOpportunities:number; lifecycleCounts:JsonObject; dispositionCounts:JsonObject; workflowCounts:JsonObject; engagementPolicy:string; budget:JsonObject; }
export function campaignListItem(value:JsonObject):CampaignListItem {
  const campaign=asObject(value.campaign),seller=asObject(value.seller),metrics=asObject(value.metrics),research=asObject(value.research);
  return {campaignId:text(campaign.campaignId,""),name:text(campaign.name,"Untitled campaign"),workflowState:text(campaign.workflowState,"UNKNOWN"),objectiveText:optionalText(campaign.objectiveText),sellerName:text(seller.name,"Seller context pending"),scopedCompanies:numberValue(metrics.scopedCompanies),materialisedOpportunities:numberValue(metrics.materialisedOpportunities),lifecycleCounts:asObject(metrics.lifecycleCounts),dispositionCounts:asObject(metrics.dispositionCounts),workflowCounts:asObject(metrics.workflowCounts),engagementPolicy:text(value.engagementPolicy,"HUMAN_ONLY"),budget:asObject(research.budget)};
}

export interface CompanyProfileView { organisationId:string;campaignId:string;companyId:string;opportunityId:string|null;companyName:string;canonicalDomain:string|null;workflowState:string|null;lifecycleState:string;disposition:string;researchPressure:string;authorityReady:boolean;reviewableNow:boolean;executableNow:boolean;reasonCode:string;nextRevalidationAt:string|null;commercialReality:string;routeAuthority:string;contactAuthority:string;truth:JsonObject;structuralRoutes:number;authorisedRoutes:number;routeRedundancy:string; }
export function companyProfile(value:JsonObject):CompanyProfileView {
  return {organisationId:text(value.organisationId,""),campaignId:text(value.campaignId,""),companyId:text(value.companyId,""),opportunityId:optionalText(value.opportunityId),companyName:text(value.companyName,"Unknown company"),canonicalDomain:optionalText(value.canonicalDomain),workflowState:optionalText(value.workflowState),lifecycleState:text(value.lifecycleState,"UNKNOWN"),disposition:text(value.disposition,"RESEARCH_REQUIRED"),researchPressure:text(value.researchPressure,"NONE"),authorityReady:booleanValue(value.authorityReady),reviewableNow:booleanValue(value.reviewableNow),executableNow:booleanValue(value.executableNow),reasonCode:text(value.reasonCode,"No current reason code"),nextRevalidationAt:optionalText(value.nextRevalidationAt),commercialReality:text(value.commercialReality,"NO_CURRENT_R4"),routeAuthority:text(value.routeAuthority,"NO_CURRENT_R5"),contactAuthority:text(value.contactAuthority,"NO_CURRENT_R6"),truth:asObject(value.truth),structuralRoutes:numberValue(value.structurallyOpenAccessPointCount),authorisedRoutes:numberValue(value.authorisedAccessPointCount),routeRedundancy:text(value.routeRedundancy,"NONE")};
}
