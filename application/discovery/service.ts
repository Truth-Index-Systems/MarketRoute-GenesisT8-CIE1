import { createHmac, randomBytes } from "node:crypto";
import { anonymousDiscoveryRepositoryFromEnvironment, type AnonymousDiscoveryStatusRecord } from "../../platform/database/anonymous-discovery-repository";

export const ANONYMOUS_DISCOVERY_COOKIE="marketroute_anonymous_discovery_v1";
const DEFAULT_OBJECTIVE="Win new B2B customers.";
const DEFAULT_TARGET="Find organisations that are commercially relevant to the seller's current offering.";

export interface AnonymousPipelineStage {key:"UNDERSTAND"|"MAP"|"DISCOVER"|"RESEARCH"|"EVALUATE"|"ROUTE"|"READY";label:string;status:"PENDING"|"ACTIVE"|"COMPLETE"|"ATTENTION";detail:string;count?:string;}
export interface AnonymousDiscoveryView extends AnonymousDiscoveryStatusRecord {pipeline:AnonymousPipelineStage[];currentMessage:string;}

function requiredSecret(){const value=process.env.MARKETROUTE_ANONYMOUS_SESSION_SECRET?.trim();if(!value||value.length<32)throw new Error("MARKETROUTE_ANONYMOUS_SESSION_SECRET_MIN_32_CHARACTERS");return value;}
function boundedNumber(name:string,fallback:number,min:number,max:number){const value=Number(process.env[name]??fallback);return Number.isFinite(value)?Math.max(min,Math.min(max,value)):fallback;}
export function newAnonymousBrowserSecret(){return randomBytes(32).toString("base64url");}
export function anonymousDiscoveryCookieOptions(){return{httpOnly:true,sameSite:"lax" as const,secure:process.env.NODE_ENV==="production",path:"/",maxAge:60*60*24*30};}
export function anonymousDiscoveryHash(value:string){return createHmac("sha256",requiredSecret()).update(`MARKETROUTE_ANON_V1:${value}`).digest("hex");}
export function anonymousIpHash(value:string){return createHmac("sha256",requiredSecret()).update(`MARKETROUTE_ANON_IP_V1:${value}`).digest("hex");}

function cleanUrl(value:string){
  try{
    const raw=value.trim();const url=new URL(/^https?:\/\//i.test(raw)?raw:`https://${raw}`);
    if(!["http:","https:"].includes(url.protocol)||!url.hostname.includes("."))throw new Error("MARKETROUTE_ANONYMOUS_WEBSITE_INVALID");
    url.hash="";url.search="";return url.toString().replace(/\/$/,"");
  }catch(error){if(error instanceof Error&&error.message==="MARKETROUTE_ANONYMOUS_WEBSITE_INVALID")throw error;throw new Error("MARKETROUTE_ANONYMOUS_WEBSITE_INVALID");}
}
function string(value:string,min:number,max:number,code:string){const clean=value.normalize("NFKC").trim().replace(/\s+/g," ");if(clean.length<min||clean.length>max)throw new Error(code);return clean;}

export function anonymousPipelineFromStatus(raw:AnonymousDiscoveryStatusRecord):AnonymousPipelineStage[]{
  const a=raw.activation,m=raw.metrics;
  const failed=["FAILED","NEEDS_INPUT"].includes(a.status);
  const activationProgress=Math.max(0,Math.min(100,Number(a.progress)||0));
  const understandDone=activationProgress>=30||a.status==="SUCCEEDED";
  const mapDone=activationProgress>=58||a.status==="SUCCEEDED";
  const discoverDone=activationProgress>=94||a.status==="SUCCEEDED";
  const researchStarted=m.researchWorkTotal>0||m.researchedCompanies>0||m.opportunities>0;
  const researchDone=m.scopedCompanies>0&&m.researchedCompanies>=m.scopedCompanies;
  const evaluateStarted=m.opportunities>0||m.researchedCompanies>0;
  const routeStarted=m.structuralRoutes>0||m.authorisedRoutes>0||m.opportunities>0;
  const ready=m.authorisedRoutes>0;
  const stage=(key:AnonymousPipelineStage["key"],label:string,done:boolean,active:boolean,detail:string,count?:string):AnonymousPipelineStage=>({key,label,status:failed&&active?"ATTENTION":done?"COMPLETE":active?"ACTIVE":"PENDING",detail,count});
  return [
    stage("UNDERSTAND","Understand your business",understandDone,!understandDone,"Reading your website and turning what you sell into structured commercial context."),
    stage("MAP","Map your market",mapDone,understandDone&&!mapDone,"Working out the market and buyer context that actually matters to your offering."),
    stage("DISCOVER","Find relevant organisations",discoverDone,mapDone&&!discoverDone,"Checking Genesis first, then discovering missing companies only where your market needs them.",m.scopedCompanies?`${m.scopedCompanies} found`:undefined),
    stage("RESEARCH","Research the strongest companies",researchDone,discoverDone&&!researchDone,"Building evidence around the companies MarketRoute has found.",m.researchWorkTotal?`${m.researchWorkCompleted} / ${m.researchWorkTotal} work items`:m.researchedCompanies?`${m.researchedCompanies} researched`:undefined),
    stage("EVALUATE","Evaluate opportunities",m.opportunities>0&&researchDone,evaluateStarted&&!routeStarted,"Testing whether the evidence supports a real commercial opportunity.",m.opportunities?`${m.opportunities} opportunities`:undefined),
    stage("ROUTE","Find routes in",ready,routeStarted&&!ready,"Tracing the organisational route and validating usable contact access.",m.structuralRoutes?`${m.structuralRoutes} routes`:undefined),
    stage("READY","Ready to pursue",ready,ready,"Actionable routes appear here as soon as the engine has enough current evidence.",m.authorisedRoutes?`${m.authorisedRoutes} ready`:undefined),
  ];
}
function messageOf(raw:AnonymousDiscoveryStatusRecord,pipeline:AnonymousPipelineStage[]){
  if(["FAILED","NEEDS_INPUT"].includes(raw.activation.status))return "I hit a problem preparing this discovery. The run is saved, and MarketRoute can retry without losing the work already completed.";
  if(raw.metrics.authorisedRoutes>0)return `I've already found ${raw.metrics.authorisedRoutes} route${raw.metrics.authorisedRoutes===1?"":"s"} that are ready to pursue. Research is continuing within this discovery run.`;
  const active=pipeline.find(stage=>stage.status==="ACTIVE");
  return active?active.detail:"Your MarketRoute discovery is saved and waiting for the next research cycle.";
}

export class AnonymousDiscoveryService{
  private readonly repository=anonymousDiscoveryRepositoryFromEnvironment();
  async create(input:{browserSecret:string;ipAddress:string;companyName:string;websiteUrl:string;sellerOfferingText:string;targetMarketText?:string|null}){
    const companyName=string(input.companyName,2,160,"MARKETROUTE_ANONYMOUS_COMPANY_NAME_REQUIRED");
    const websiteUrl=cleanUrl(input.websiteUrl);
    const sellerOfferingText=string(input.sellerOfferingText,8,2000,"MARKETROUTE_ANONYMOUS_OFFERING_REQUIRED");
    const targetMarketText=input.targetMarketText?.trim()?string(input.targetMarketText,3,2000,"MARKETROUTE_ANONYMOUS_TARGET_INVALID"):DEFAULT_TARGET;
    return this.repository.create({browserKeyHash:anonymousDiscoveryHash(input.browserSecret),ipHash:anonymousIpHash(input.ipAddress||"unknown"),companyName,websiteUrl,sellerOfferingText,targetMarketText,objectiveText:DEFAULT_OBJECTIVE,lifetimeBudgetUsd:boundedNumber("MARKETROUTE_ANONYMOUS_RESEARCH_BUDGET_USD",3,0.5,25),researchWindowHours:Math.floor(boundedNumber("MARKETROUTE_ANONYMOUS_RESEARCH_WINDOW_HOURS",24,1,72)),targetCount:Math.floor(boundedNumber("MARKETROUTE_ANONYMOUS_TARGET_COUNT",12,8,20))});
  }
  async status(browserSecret:string):Promise<AnonymousDiscoveryView|null>{const raw=await this.repository.status(anonymousDiscoveryHash(browserSecret));if(!raw)return null;const pipeline=anonymousPipelineFromStatus(raw);return{...raw,pipeline,currentMessage:messageOf(raw,pipeline)};}
}
export function anonymousDiscoveryServiceFromEnvironment(){return new AnonymousDiscoveryService();}
