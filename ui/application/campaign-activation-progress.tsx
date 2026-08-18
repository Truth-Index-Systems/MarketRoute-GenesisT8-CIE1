"use client";

import { useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { Icon } from "@/ui/icons";

export interface CampaignActivationProgressState {
  status:string;
  lastErrorCode:string|null;
  campaignName:string|null;
  stage:string;
  progress:number;
  stageDetail:Record<string,unknown>;
  updatedAt:string|null;
}

const stages=[
  {start:0,label:"Brief saved",detail:"Your market brief is safely stored."},
  {start:10,label:"Understand your offer",detail:"Checking your website and what you sell."},
  {start:35,label:"Set up the market",detail:"Turning your brief into a focused research plan."},
  {start:55,label:"Check existing research",detail:"Reusing useful knowledge before searching again."},
  {start:70,label:"Find companies",detail:"Building the first set of companies for this market."},
  {start:96,label:"Start research",detail:"MarketRoute is ready to research the market."}
];

function number(value:unknown){const parsed=Number(value);return Number.isFinite(parsed)?Math.max(0,Math.round(parsed)):null;}
function currentMessage(state:CampaignActivationProgressState){
  const linked=number(state.stageDetail.linkedCount),total=number(state.stageDetail.totalCount);
  const messages:Record<string,string>={
    QUEUED:"Brief saved. MarketRoute will start preparing it automatically.",
    ANALYSING_SELLER:"Reading your website and offer.",
    SELLER_CONTEXT_READY:"Your offer is understood and ready.",
    CREATING_CAMPAIGN:"Setting up this market.",
    CAMPAIGN_CREATED:"Market ready. Preparing the research.",
    SELECTING_TARGETS:"Checking what MarketRoute already knows before searching again.",
    DISCOVERING_TARGETS:"Finding fresh companies where more coverage is needed.",
    LINKING_COMPANIES:linked!==null&&total!==null?`Adding companies ${linked} of ${total}.`:"Adding selected companies to this market.",
    FINALISING:"Finishing the first company set and starting research.",
    READY:"Market ready. Research can now begin.",
    FAILED:state.status==="FAILED"?"Preparation paused and will retry automatically.":"Preparation needs a corrected brief before it can continue."
  };
  return messages[state.stage]??"Market preparation is continuing in the background.";
}

function statusLabel(status:string){if(status==="PENDING")return"Queued";if(status==="RUNNING")return"Working";if(status==="FAILED")return"Retry scheduled";if(status==="NEEDS_INPUT")return"Needs input";return"Ready";}
function isWorking(status:string){return["PENDING","RUNNING","FAILED"].includes(status);}
function pollDelay(status:string){if(status==="RUNNING")return 3000;if(status==="FAILED")return 30000;return 12000;}
function stateFingerprint(state:CampaignActivationProgressState){return`${state.status}|${state.stage}|${state.progress}|${state.updatedAt??""}`;}
function activationState(value:unknown):CampaignActivationProgressState|null{
  if(!value||typeof value!=="object"||Array.isArray(value))return null;
  const row=value as Record<string,unknown>,progress=Number(row.progress??0);
  if(typeof row.status!=="string"||typeof row.stage!=="string"||!Number.isFinite(progress))return null;
  return{status:row.status,lastErrorCode:typeof row.lastErrorCode==="string"?row.lastErrorCode:null,campaignName:typeof row.campaignName==="string"?row.campaignName:null,stage:row.stage,progress:Math.max(0,Math.min(100,Math.round(progress))),stageDetail:row.stageDetail&&typeof row.stageDetail==="object"&&!Array.isArray(row.stageDetail)?row.stageDetail as Record<string,unknown>:{},updatedAt:typeof row.updatedAt==="string"?row.updatedAt:null};
}

export function CampaignActivationProgress({state}:{state:CampaignActivationProgressState}){
  const router=useRouter();
  const [current,setCurrent]=useState(state);
  const currentRef=useRef(state);
  const refreshStarted=useRef(false);
  const progress=Math.max(0,Math.min(100,current.progress));
  const activeIndex=current.status==="SUCCEEDED"?stages.length-1:Math.max(0,stages.findLastIndex(stage=>progress>=stage.start));
  const working=isWorking(current.status);

  useEffect(()=>{
    currentRef.current=state;
    setCurrent(state);
  },[state]);
  useEffect(()=>{if(["PENDING","RUNNING","SUCCEEDED","NOT_REQUIRED"].includes(current.status))localStorage.removeItem("marketroute:new-campaign-draft:v1");},[current.status]);
  useEffect(()=>{
    let cancelled=false,timer:number|undefined;
    const schedule=(status:string,override?:number)=>{if(!cancelled&&isWorking(status))timer=window.setTimeout(poll,override??pollDelay(status));};
    const poll=async()=>{
      if(cancelled)return;
      if(document.visibilityState!=="visible"){schedule(currentRef.current.status,15000);return;}
      try{
        const response=await fetch("/api/campaigns/activation-status",{cache:"no-store",headers:{Accept:"application/json"}});
        if(response.status===401){
          if(!refreshStarted.current){refreshStarted.current=true;const next=`${window.location.pathname}${window.location.search}`;window.location.assign(`/api/session/refresh?next=${encodeURIComponent(next)}`);}
          return;
        }
        if(!response.ok){schedule(currentRef.current.status,15000);return;}
        const payload=await response.json() as {activation?:unknown};
        const next=activationState(payload.activation);
        if(!next){schedule(currentRef.current.status,15000);return;}
        const previous=currentRef.current;
        if(stateFingerprint(previous)!==stateFingerprint(next)){currentRef.current=next;setCurrent(next);}
        if(!isWorking(next.status)){
          if(!refreshStarted.current){refreshStarted.current=true;router.refresh();}
          return;
        }
        schedule(next.status);
      }catch{schedule(currentRef.current.status,15000);}
    };
    schedule(currentRef.current.status);
    return()=>{cancelled=true;if(timer!==undefined)window.clearTimeout(timer);};
  },[router]);

  return <section className={`mr-activation-progress${current.stage==="FAILED"?" mr-activation-progress--error":""}`} aria-live="polite">
    <header className="mr-activation-progress__head">
      <div><span>SETTING UP YOUR MARKET</span><h2>{current.campaignName??"Your new market"}</h2><p>{currentMessage(current)}</p></div>
      <div className="mr-activation-progress__status"><span className={working&&current.stage!=="FAILED"?"is-working":""}/><strong>{statusLabel(current.status)}</strong><small>{progress}%</small></div>
    </header>
    <div className="mr-activation-progress__bar" aria-label={`${progress}% complete`}><span style={{width:`${progress}%`}}/></div>
    <ol className="mr-activation-progress__stages">
      {stages.map((stage,index)=>{
        const complete=current.status==="SUCCEEDED"||index<activeIndex;
        const active=!complete&&index===activeIndex;
        return <li className={complete?"is-complete":active?"is-active":""} key={stage.label}>
          <i>{complete?<Icon name="check" size={13}/>:active&&working&&current.stage!=="FAILED"?<span className="mr-activation-spinner"/>:index+1}</i>
          <div><strong>{stage.label}</strong><small>{stage.detail}</small></div>
        </li>;
      })}
    </ol>
    <footer><span>{working?"You can leave this page. MarketRoute will keep going.":"Your progress is saved in this workspace."}</span>{current.updatedAt&&<small>Updated {new Date(current.updatedAt).toLocaleTimeString("en-GB",{hour:"2-digit",minute:"2-digit",second:"2-digit"})}</small>}</footer>
  </section>;
}
