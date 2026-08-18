import { createHmac, randomBytes } from "node:crypto";
import { anonymousDiscoveryRepositoryFromEnvironment, type AnonymousDiscoveryStatusRecord, type DiscoveryFreeAccessRecord } from "../../platform/database/anonymous-discovery-repository";
import { marketRouteConversationServiceFromEnvironment } from "../conversation/service";
import type { MarketRouteNarrative } from "../conversation/contracts";
import type { CompanyIntelligenceReadModel,RouteDisplayReadModel } from "../read-model/contracts";
import { assertCanonicalApplicationRead } from "../read-model/validation";
import { contactRoutePresentation } from "../opportunities/contact-route-presentation";

export const ANONYMOUS_DISCOVERY_COOKIE="marketroute_anonymous_discovery_v1";
const DEFAULT_OBJECTIVE="Win new B2B customers.";
const DEFAULT_TARGET="Find organisations that are commercially relevant to the seller's current offering.";
export const ANONYMOUS_DISCOVERY_LAUNCH_POLICY=Object.freeze({freeOpportunityLimit:8,targetCount:10,lifetimeBudgetUsd:1,researchWindowHours:12});

export interface AnonymousPipelineStage {key:"UNDERSTAND"|"MAP"|"DISCOVER"|"RESEARCH"|"EVALUATE"|"ROUTE"|"READY";label:string;status:"PENDING"|"ACTIVE"|"COMPLETE"|"ATTENTION";detail:string;count?:string;}
export interface AnonymousRoutePreview {key:string;personName:string|null;roleTitles:string[];explanation:string;emailAvailable:boolean;phoneAvailable:boolean;profileAvailable:boolean;webRouteAvailable:boolean;}
export interface AnonymousOpportunityPreview {ordinal:number;opportunityId:string;companyId:string;companyName:string;canonicalDomain:string|null;unlockedAt:string;narrative:MarketRouteNarrative;routes:AnonymousRoutePreview[];}
export interface AnonymousDiscoveryView extends AnonymousDiscoveryStatusRecord {pipeline:AnonymousPipelineStage[];currentMessage:string;narrative:MarketRouteNarrative;freeOpportunityLimit:number;opportunities:AnonymousOpportunityPreview[];}

function requiredSecret(){const value=process.env.MARKETROUTE_ANONYMOUS_SESSION_SECRET?.trim();if(!value||value.length<32)throw new Error("MARKETROUTE_ANONYMOUS_SESSION_SECRET_MIN_32_CHARACTERS");return value;}
function boundedNumber(name:string,fallback:number,min:number,max:number){const value=Number(process.env[name]??fallback);return Number.isFinite(value)?Math.max(min,Math.min(max,value)):fallback;}
export function newAnonymousBrowserSecret(){return randomBytes(32).toString("base64url");}
export function anonymousDiscoveryCookieOptions(){return{httpOnly:true,sameSite:"lax" as const,secure:process.env.NODE_ENV==="production",path:"/",maxAge:60*60*24*30};}
export function anonymousDiscoveryHash(value:string){return createHmac("sha256",requiredSecret()).update(`MARKETROUTE_ANON_V1:${value}`).digest("hex");}
export function anonymousIpHash(value:string){return createHmac("sha256",requiredSecret()).update(`MARKETROUTE_ANON_IP_V1:${value}`).digest("hex");}

function cleanUrl(value:string){
  try{const raw=value.trim();const url=new URL(/^https?:\/\//i.test(raw)?raw:`https://${raw}`);if(!["http:","https:"].includes(url.protocol)||!url.hostname.includes("."))throw new Error("MARKETROUTE_ANONYMOUS_WEBSITE_INVALID");url.hash="";url.search="";return url.toString().replace(/\/$/,"");}
  catch(error){if(error instanceof Error&&error.message==="MARKETROUTE_ANONYMOUS_WEBSITE_INVALID")throw error;throw new Error("MARKETROUTE_ANONYMOUS_WEBSITE_INVALID");}
}
function string(value:string,min:number,max:number,code:string){const clean=value.normalize("NFKC").trim().replace(/\s+/g," ");if(clean.length<min||clean.length>max)throw new Error(code);return clean;}
function object(value:unknown):Record<string,unknown>{return value&&typeof value==="object"&&!Array.isArray(value)?value as Record<string,unknown>:{};}
function text(value:unknown):string|null{return typeof value==="string"&&value.trim()?value.trim():null;}

export function anonymousPipelineFromStatus(raw:AnonymousDiscoveryStatusRecord):AnonymousPipelineStage[]{
  const a=raw.activation,m=raw.metrics;const failed=["FAILED","NEEDS_INPUT"].includes(a.status);const activationProgress=Math.max(0,Math.min(100,Number(a.progress)||0));const understandDone=activationProgress>=30||a.status==="SUCCEEDED";const mapDone=activationProgress>=58||a.status==="SUCCEEDED";const discoverDone=activationProgress>=94||a.status==="SUCCEEDED";const researchDone=m.scopedCompanies>0&&m.researchedCompanies>=m.scopedCompanies;const evaluateStarted=m.opportunities>0||m.researchedCompanies>0;const routeStarted=m.structuralRoutes>0||m.authorisedRoutes>0||m.opportunities>0;const ready=m.freeUnlocked>0||m.authorisedRoutes>0;
  const stage=(key:AnonymousPipelineStage["key"],label:string,done:boolean,active:boolean,detail:string,count?:string):AnonymousPipelineStage=>({key,label,status:failed&&active?"ATTENTION":done?"COMPLETE":active?"ACTIVE":"PENDING",detail,count});
  return [
    stage("UNDERSTAND","Understand your business",understandDone,!understandDone,"Reading your website and turning what you sell into structured commercial context."),
    stage("MAP","Map your market",mapDone,understandDone&&!mapDone,"Working out the market and buyer context that actually matters to your offering."),
    stage("DISCOVER","Find relevant organisations",discoverDone,mapDone&&!discoverDone,"Checking Genesis first, then discovering missing companies only where your market needs them.",m.scopedCompanies?`${m.scopedCompanies} found`:undefined),
    stage("RESEARCH","Research the strongest companies",researchDone,discoverDone&&!researchDone,"Building evidence around the companies MarketRoute has found.",m.researchWorkTotal?`${m.researchWorkCompleted} / ${m.researchWorkTotal} work items`:m.researchedCompanies?`${m.researchedCompanies} researched`:undefined),
    stage("EVALUATE","Evaluate opportunities",m.opportunities>0&&researchDone,evaluateStarted&&!routeStarted,"Testing whether the evidence supports a real commercial opportunity.",m.opportunities?`${m.opportunities} opportunities`:undefined),
    stage("ROUTE","Find routes in",ready,routeStarted&&!ready,"Tracing the organisational route and validating usable contact access.",m.structuralRoutes?`${m.structuralRoutes} routes`:undefined),
    stage("READY","Ready to pursue",ready,ready,"Your first eight qualifying opportunities become permanently free as soon as their routes are ready.",m.freeUnlocked?`${m.freeUnlocked} of 8 free`:undefined),
  ];
}
function messageOf(raw:AnonymousDiscoveryStatusRecord,pipeline:AnonymousPipelineStage[]){if(["FAILED","NEEDS_INPUT"].includes(raw.activation.status))return"I hit a problem preparing this discovery. The run is saved, and MarketRoute can retry without losing the work already completed.";if(raw.metrics.freeUnlocked>0)return`I've made ${raw.metrics.freeUnlocked} of your first 8 opportunities ready. They stay free when you save this MarketRoute.`;const active=pipeline.find(stage=>stage.status==="ACTIVE");return active?active.detail:"Your MarketRoute discovery is saved and waiting for the next research cycle.";}

export class AnonymousDiscoveryService{
  private readonly repository=anonymousDiscoveryRepositoryFromEnvironment();
  async create(input:{browserSecret:string;ipAddress:string;companyName:string;websiteUrl:string;sellerOfferingText:string;targetMarketText?:string|null}){const companyName=string(input.companyName,2,160,"MARKETROUTE_ANONYMOUS_COMPANY_NAME_REQUIRED");const websiteUrl=cleanUrl(input.websiteUrl);const sellerOfferingText=string(input.sellerOfferingText,8,2000,"MARKETROUTE_ANONYMOUS_OFFERING_REQUIRED");const targetMarketText=input.targetMarketText?.trim()?string(input.targetMarketText,3,2000,"MARKETROUTE_ANONYMOUS_TARGET_INVALID"):DEFAULT_TARGET;return this.repository.create({browserKeyHash:anonymousDiscoveryHash(input.browserSecret),ipHash:anonymousIpHash(input.ipAddress||"unknown"),companyName,websiteUrl,sellerOfferingText,targetMarketText,objectiveText:DEFAULT_OBJECTIVE,lifetimeBudgetUsd:boundedNumber("MARKETROUTE_ANONYMOUS_RESEARCH_BUDGET_USD",ANONYMOUS_DISCOVERY_LAUNCH_POLICY.lifetimeBudgetUsd,0.5,ANONYMOUS_DISCOVERY_LAUNCH_POLICY.lifetimeBudgetUsd),researchWindowHours:Math.floor(boundedNumber("MARKETROUTE_ANONYMOUS_RESEARCH_WINDOW_HOURS",ANONYMOUS_DISCOVERY_LAUNCH_POLICY.researchWindowHours,1,ANONYMOUS_DISCOVERY_LAUNCH_POLICY.researchWindowHours)),targetCount:Math.floor(boundedNumber("MARKETROUTE_ANONYMOUS_TARGET_COUNT",ANONYMOUS_DISCOVERY_LAUNCH_POLICY.targetCount,ANONYMOUS_DISCOVERY_LAUNCH_POLICY.freeOpportunityLimit,ANONYMOUS_DISCOVERY_LAUNCH_POLICY.targetCount))});}
  async claim(accessToken:string,browserSecret:string){return this.repository.claim(accessToken,anonymousDiscoveryHash(browserSecret));}
  async access(organisationId:string):Promise<DiscoveryFreeAccessRecord>{return this.repository.access(organisationId);}
  async status(browserSecret:string):Promise<AnonymousDiscoveryView|null>{
    const browserKeyHash=anonymousDiscoveryHash(browserSecret);let raw=await this.repository.status(browserKeyHash);if(!raw)return null;
    const bundles=await this.repository.unlocked(browserKeyHash).catch(()=>[]);if(bundles.length!==raw.metrics.freeUnlocked)raw={...raw,metrics:{...raw.metrics,freeUnlocked:bundles.length}};
    const conversation=marketRouteConversationServiceFromEnvironment();
    const opportunities=(await Promise.all(bundles.slice(0,8).map(async bundle=>{
      const company=assertCanonicalApplicationRead<CompanyIntelligenceReadModel>(bundle.company,"COMPANY_INTELLIGENCE");
      const routes=assertCanonicalApplicationRead<RouteDisplayReadModel>(bundle.routes,"ROUTE_DISPLAY");
      const presentation=contactRoutePresentation(routes);const profile=object(company.profile);
      const safeRoutes=presentation.ready.map(route=>({key:route.key,personName:route.personName,roleTitles:route.roleTitles,explanation:route.explanation,emailAvailable:route.channels.some(c=>c.kind==="EMAIL"),phoneAvailable:route.channels.some(c=>c.kind==="PHONE"),profileAvailable:route.channels.some(c=>c.kind==="PROFILE"),webRouteAvailable:route.channels.some(c=>c.kind==="WEB"||c.kind==="OTHER")}));
      return {ordinal:Number(bundle.ordinal),opportunityId:String(bundle.opportunityId),companyId:String(bundle.companyId),companyName:text(profile.companyName)??text(object(routes.company).companyName)??"Opportunity",canonicalDomain:text(profile.canonicalDomain)??text(object(routes.company).canonicalDomain),unlockedAt:String(bundle.unlockedAt),narrative:await conversation.opportunity(company,routes),routes:safeRoutes} satisfies AnonymousOpportunityPreview;
    }))).sort((a,b)=>a.ordinal-b.ordinal);
    const pipeline=anonymousPipelineFromStatus(raw);const narrative=await conversation.discovery(raw,pipeline);return{...raw,pipeline,currentMessage:narrative.summary||messageOf(raw,pipeline),narrative,freeOpportunityLimit:ANONYMOUS_DISCOVERY_LAUNCH_POLICY.freeOpportunityLimit,opportunities};
  }
}
export function anonymousDiscoveryServiceFromEnvironment(){return new AnonymousDiscoveryService();}
