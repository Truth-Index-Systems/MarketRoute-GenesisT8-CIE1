"use client";
import { useEffect,useRef,useState } from "react";
import { Icon } from "@/ui/icons";
import { MarketRouteNarrativeCard } from "@/ui/application/marketroute-narrative";
import type { AnonymousDiscoveryView,AnonymousPipelineStage } from "@/application/discovery/service";

function fingerprint(value:AnonymousDiscoveryView){return JSON.stringify({status:value.runStatus,activation:value.activation,metrics:value.metrics,pipeline:value.pipeline,narrative:value.narrative.sourceFingerprint});}
function pollDelay(value:AnonymousDiscoveryView){if(value.activation.status==="RUNNING")return 3000;if(value.activation.status==="PENDING")return 7000;if(value.metrics.authorisedRoutes>0)return 15000;return 8000;}
function stateLabel(status:string){if(status==="ACTIVE")return"Working";if(status==="COMPLETE")return"Complete";if(status==="ATTENTION")return"Needs attention";return"Waiting";}

export function AnonymousDiscoveryProgress({initial}:{initial:AnonymousDiscoveryView}){
  const [state,setState]=useState(initial);const ref=useRef(initial);
  useEffect(()=>{ref.current=initial;setState(initial)},[initial]);
  useEffect(()=>{let cancelled=false,timer:number|undefined;const schedule=(delay:number)=>{if(!cancelled)timer=window.setTimeout(poll,delay)};const poll=async()=>{if(cancelled)return;if(document.visibilityState!=="visible"){schedule(15000);return}try{const response=await fetch("/api/discovery/status",{cache:"no-store",headers:{Accept:"application/json"}});if(!response.ok){schedule(15000);return}const payload=await response.json() as {discovery?:AnonymousDiscoveryView};if(!payload.discovery){schedule(15000);return}if(fingerprint(ref.current)!==fingerprint(payload.discovery)){ref.current=payload.discovery;setState(payload.discovery)}schedule(pollDelay(payload.discovery));}catch{schedule(15000)}};schedule(pollDelay(ref.current));return()=>{cancelled=true;if(timer!==undefined)window.clearTimeout(timer)}},[]);
  const active=state.pipeline.find((stage:AnonymousPipelineStage)=>stage.status==="ACTIVE"||stage.status==="ATTENTION")??state.pipeline[state.pipeline.length-1];
  const complete=state.pipeline.filter((stage:AnonymousPipelineStage)=>stage.status==="COMPLETE").length;
  return <div className="mr-discovery-progress" aria-live="polite">
    <section className="mr-discovery-progress__hero">
      <div><span>YOUR MARKETROUTE</span><h1>Building routes for <em>{state.companyName}</em></h1><p>{state.currentMessage}</p></div>
      <div className="mr-discovery-progress__pulse"><i className={active?.status==="ATTENTION"?"is-attention":""}/><strong>{active?.label??"Discovery saved"}</strong><small>{complete} of {state.pipeline.length} stages complete</small></div>
    </section>
    <MarketRouteNarrativeCard narrative={state.narrative} eyebrow="WHAT I’VE ESTABLISHED"/>
    <section className="mr-discovery-pipeline">
      {state.pipeline.map((stage:AnonymousPipelineStage,index:number)=><article className={`mr-discovery-stage is-${stage.status.toLowerCase()}`} key={stage.key}>
        <div className="mr-discovery-stage__rail"><span>{stage.status==="COMPLETE"?<Icon name="check" size={14}/>:String(index+1).padStart(2,"0")}</span>{index<state.pipeline.length-1&&<i/>}</div>
        <div className="mr-discovery-stage__body"><header><div><small>{stateLabel(stage.status)}</small><h2>{stage.label}</h2></div>{stage.count&&<strong>{stage.count}</strong>}</header><p>{stage.detail}</p></div>
      </article>)}
    </section>
    <section className="mr-discovery-live">
      <div><span>LIVE DISCOVERY</span><h2>What MarketRoute has established so far</h2></div>
      <dl>
        <div><dt>Organisations found</dt><dd>{state.metrics.scopedCompanies}</dd></div>
        <div><dt>Research completed</dt><dd>{state.metrics.researchedCompanies}</dd></div>
        <div><dt>Opportunities emerging</dt><dd>{state.metrics.opportunities}</dd></div>
        <div><dt>Routes ready</dt><dd>{state.metrics.authorisedRoutes}</dd></div>
      </dl>
      <footer><Icon name="shield" size={14}/><span>This run is saved in this browser and continues automatically. Progress shown here comes from persisted engine state.</span></footer>
    </section>
  </div>;
}
