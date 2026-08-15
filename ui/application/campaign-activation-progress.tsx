"use client";

import { useEffect } from "react";
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
  {start:0,label:"Brief saved",detail:"Your campaign brief is safely stored."},
  {start:10,label:"Seller context",detail:"Checking your current website and offering."},
  {start:35,label:"Campaign structure",detail:"Creating the campaign and its research policy."},
  {start:55,label:"Genesis targets",detail:"Checking the intelligence bank before fresh discovery."},
  {start:70,label:"Company scope",detail:"Linking selected companies to this campaign."},
  {start:96,label:"Ready for research",detail:"Handing the campaign to autonomous research."}
];

function number(value:unknown){const parsed=Number(value);return Number.isFinite(parsed)?Math.max(0,Math.round(parsed)):null;}
function currentMessage(state:CampaignActivationProgressState){
  const linked=number(state.stageDetail.linkedCount),total=number(state.stageDetail.totalCount);
  const messages:Record<string,string>={
    QUEUED:"Brief saved. Waiting for the next automatic bootstrap run.",
    ANALYSING_SELLER:"Analysing your current website and seller declaration.",
    SELLER_CONTEXT_READY:"Seller context verified and ready for the campaign.",
    CREATING_CAMPAIGN:"Creating a separate campaign record.",
    CAMPAIGN_CREATED:"Campaign created. Applying its research policy.",
    SELECTING_TARGETS:"Searching Genesis for reusable market intelligence.",
    DISCOVERING_TARGETS:"Finding fresh targets because the Genesis bank needs more coverage.",
    LINKING_COMPANIES:linked!==null&&total!==null?`Linking companies ${linked} of ${total}.`:"Linking selected companies to the campaign.",
    FINALISING:"Finalising the company scope and research handoff.",
    READY:"Campaign ready. Genesis research can now begin.",
    FAILED:state.status==="FAILED"?"Preparation paused and will retry automatically.":"Preparation needs a corrected brief before it can continue."
  };
  return messages[state.stage]??"Campaign preparation is continuing in the background.";
}

function statusLabel(status:string){if(status==="PENDING")return"Queued";if(status==="RUNNING")return"Working";if(status==="FAILED")return"Retry scheduled";if(status==="NEEDS_INPUT")return"Needs input";return"Ready";}

export function CampaignActivationProgress({state}:{state:CampaignActivationProgressState}){
  const router=useRouter();
  const progress=Math.max(0,Math.min(100,state.progress));
  const activeIndex=state.status==="SUCCEEDED"?stages.length-1:Math.max(0,stages.findLastIndex(stage=>progress>=stage.start));
  const working=["PENDING","RUNNING","FAILED"].includes(state.status);

  useEffect(()=>{
    if(["PENDING","RUNNING","SUCCEEDED","NOT_REQUIRED"].includes(state.status))localStorage.removeItem("marketroute:new-campaign-draft:v1");
    if(!working)return;
    const delay=state.status==="FAILED"?12000:2200;
    const refresh=()=>{if(document.visibilityState==="visible")router.refresh();};
    const timer=window.setInterval(refresh,delay);
    window.addEventListener("focus",refresh);
    return()=>{window.clearInterval(timer);window.removeEventListener("focus",refresh);};
  },[router,state.status,working]);

  return <section className={`mr-activation-progress${state.stage==="FAILED"?" mr-activation-progress--error":""}`} aria-live="polite">
    <header className="mr-activation-progress__head">
      <div><span>CAMPAIGN PREPARATION</span><h2>{state.campaignName??"Your new campaign"}</h2><p>{currentMessage(state)}</p></div>
      <div className="mr-activation-progress__status"><span className={working&&state.stage!=="FAILED"?"is-working":""}/><strong>{statusLabel(state.status)}</strong><small>{progress}%</small></div>
    </header>
    <div className="mr-activation-progress__bar" aria-label={`${progress}% complete`}><span style={{width:`${progress}%`}}/></div>
    <ol className="mr-activation-progress__stages">
      {stages.map((stage,index)=>{
        const complete=state.status==="SUCCEEDED"||index<activeIndex;
        const active=!complete&&index===activeIndex;
        return <li className={complete?"is-complete":active?"is-active":""} key={stage.label}>
          <i>{complete?<Icon name="check" size={13}/>:active&&working&&state.stage!=="FAILED"?<span className="mr-activation-spinner"/>:index+1}</i>
          <div><strong>{stage.label}</strong><small>{stage.detail}</small></div>
        </li>;
      })}
    </ol>
    <footer><span>{working?"This continues if you leave this page.":"Preparation state is stored in your workspace."}</span>{state.updatedAt&&<small>Updated {new Date(state.updatedAt).toLocaleTimeString("en-GB",{hour:"2-digit",minute:"2-digit",second:"2-digit"})}</small>}</footer>
  </section>;
}
