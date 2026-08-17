"use client";
import { useEffect,useRef,useState } from "react";
import { Icon } from "@/ui/icons";
import { MarketRouteNarrativeCard } from "@/ui/application/marketroute-narrative";
import type { AnonymousDiscoveryView,AnonymousPipelineStage,AnonymousOpportunityPreview } from "@/application/discovery/service";

function fingerprint(value:AnonymousDiscoveryView){return JSON.stringify({status:value.runStatus,activation:value.activation,metrics:value.metrics,pipeline:value.pipeline,narrative:value.narrative.sourceFingerprint,opportunities:value.opportunities.map(o=>[o.opportunityId,o.narrative.sourceFingerprint,o.routes])});}
function pollDelay(value:AnonymousDiscoveryView){if(value.activation.status==="RUNNING")return 3000;if(value.activation.status==="PENDING")return 7000;if(value.metrics.freeUnlocked>=value.freeOpportunityLimit)return 20000;if(value.metrics.authorisedRoutes>0)return 12000;return 8000;}
function stateLabel(status:string){if(status==="ACTIVE")return"Working";if(status==="COMPLETE")return"Complete";if(status==="ATTENTION")return"Needs attention";return"Waiting";}
function GateButton({label,onOpen,icon}:{label:string;onOpen:()=>void;icon:"mail"|"phone"|"external"}){return <button type="button" className="mr-discovery-contact-gate" onClick={onOpen}><Icon name={icon} size={13}/>{label}</button>;}
function OpportunityCard({opportunity,onGate}:{opportunity:AnonymousOpportunityPreview;onGate:()=>void}){
  const primary=opportunity.routes[0];
  return <article className="mr-discovery-opportunity">
    <header><div><span>FREE OPPORTUNITY {opportunity.ordinal}</span><h3>{opportunity.companyName}</h3><small>{opportunity.canonicalDomain??"Commercial route verified"}</small></div><div className="mr-discovery-opportunity__status"><i/>Ready</div></header>
    <p className="mr-discovery-opportunity__summary">{opportunity.narrative.summary}</p>
    {primary?<div className="mr-discovery-route-preview"><div className="mr-discovery-route-preview__identity"><div><Icon name={primary.personName?"user":"companies"} size={17}/></div><span><strong>{primary.personName??"Organisation route"}</strong><small>{primary.roleTitles.length?primary.roleTitles.join(" · "):"Direct commercial access"}</small></span></div><p>{primary.explanation}</p><div className="mr-discovery-route-preview__channels">
      {primary.emailAvailable?<GateButton label="Access email" onOpen={onGate} icon="mail"/>:<span><Icon name="mail" size={13}/>Email not found yet</span>}
      {primary.phoneAvailable?<GateButton label="Access phone" onOpen={onGate} icon="phone"/>:<span><Icon name="phone" size={13}/>Phone not found yet</span>}
      {(primary.profileAvailable||primary.webRouteAvailable)&&<GateButton label="Open contact route" onOpen={onGate} icon="external"/>}
    </div></div>:<div className="mr-discovery-route-preview mr-discovery-route-preview--empty"><Icon name="route" size={15}/><span>The opportunity is free and MarketRoute is still resolving the clearest contact presentation.</span></div>}
    {opportunity.routes.length>1&&<footer>{opportunity.routes.length-1} additional authorised route{opportunity.routes.length===2?"":"s"} will be saved with this opportunity.</footer>}
  </article>;
}

export function AnonymousDiscoveryProgress({initial}:{initial:AnonymousDiscoveryView}){
  const [state,setState]=useState(initial);const [gateOpen,setGateOpen]=useState(false);const ref=useRef(initial);
  useEffect(()=>{ref.current=initial;setState(initial)},[initial]);
  useEffect(()=>{let cancelled=false,timer:number|undefined;const schedule=(delay:number)=>{if(!cancelled)timer=window.setTimeout(poll,delay)};const poll=async()=>{if(cancelled)return;if(document.visibilityState!=="visible"){schedule(15000);return}try{const response=await fetch("/api/discovery/status",{cache:"no-store",headers:{Accept:"application/json"}});if(!response.ok){schedule(15000);return}const payload=await response.json() as {discovery?:AnonymousDiscoveryView};if(!payload.discovery){schedule(15000);return}if(fingerprint(ref.current)!==fingerprint(payload.discovery)){ref.current=payload.discovery;setState(payload.discovery)}schedule(pollDelay(payload.discovery));}catch{schedule(15000)}};schedule(pollDelay(ref.current));return()=>{cancelled=true;if(timer!==undefined)window.clearTimeout(timer)}},[]);
  const active=state.pipeline.find((stage:AnonymousPipelineStage)=>stage.status==="ACTIVE"||stage.status==="ATTENTION")??state.pipeline[state.pipeline.length-1];const complete=state.pipeline.filter((stage:AnonymousPipelineStage)=>stage.status==="COMPLETE").length;
  return <div className="mr-discovery-progress" aria-live="polite">
    <section className="mr-discovery-progress__hero"><div><span>YOUR MARKETROUTE</span><h1>Building routes for <em>{state.companyName}</em></h1><p>{state.currentMessage}</p></div><div className="mr-discovery-progress__pulse"><i className={active?.status==="ATTENTION"?"is-attention":""}/><strong>{active?.label??"Discovery saved"}</strong><small>{complete} of {state.pipeline.length} stages complete</small></div></section>
    <MarketRouteNarrativeCard narrative={state.narrative} eyebrow="WHAT I’VE ESTABLISHED"/>
    <section className="mr-discovery-pipeline">{state.pipeline.map((stage:AnonymousPipelineStage,index:number)=><article className={`mr-discovery-stage is-${stage.status.toLowerCase()}`} key={stage.key}><div className="mr-discovery-stage__rail"><span>{stage.status==="COMPLETE"?<Icon name="check" size={14}/>:String(index+1).padStart(2,"0")}</span>{index<state.pipeline.length-1&&<i/>}</div><div className="mr-discovery-stage__body"><header><div><small>{stateLabel(stage.status)}</small><h2>{stage.label}</h2></div>{stage.count&&<strong>{stage.count}</strong>}</header><p>{stage.detail}</p></div></article>)}</section>

    <section className="mr-discovery-free-eight">
      <div className="mr-discovery-free-eight__head"><div><span>YOUR FIRST 8</span><h2>Opportunities that are yours to keep.</h2><p>As soon as an opportunity has current commercial and contact authority, MarketRoute assigns it one of your eight permanent free slots.</p></div><strong>{state.opportunities.length} / {state.freeOpportunityLimit}</strong></div>
      {state.opportunities.length?<div className="mr-discovery-opportunity-grid">{state.opportunities.map(opportunity=><OpportunityCard key={opportunity.opportunityId} opportunity={opportunity} onGate={()=>setGateOpen(true)}/>)}</div>:<div className="mr-discovery-free-eight__waiting"><Icon name="search" size={18}/><div><strong>I’m still qualifying the first route.</strong><span>The cards will appear here automatically when the engine has enough current evidence.</span></div></div>}
    </section>

    <section className="mr-discovery-live"><div><span>LIVE DISCOVERY</span><h2>What MarketRoute has established so far</h2></div><dl><div><dt>Organisations found</dt><dd>{state.metrics.scopedCompanies}</dd></div><div><dt>Research completed</dt><dd>{state.metrics.researchedCompanies}</dd></div><div><dt>Opportunities emerging</dt><dd>{state.metrics.opportunities}</dd></div><div><dt>Your free opportunities</dt><dd>{state.metrics.freeUnlocked}</dd></div></dl><footer><Icon name="shield" size={14}/><span>This run is saved in this browser and continues automatically. Your first eight free opportunity IDs are persisted server-side.</span></footer></section>

    {gateOpen&&<div className="mr-discovery-gate" role="dialog" aria-modal="true" aria-labelledby="mr-discovery-gate-title"><button className="mr-discovery-gate__backdrop" aria-label="Close" onClick={()=>setGateOpen(false)}/><div className="mr-discovery-gate__panel"><button className="mr-discovery-gate__close" onClick={()=>setGateOpen(false)} aria-label="Close">×</button><div className="mr-kicker"><span/> SAVE YOUR MARKETROUTE</div><h2 id="mr-discovery-gate-title">These routes are yours. Save them.</h2><p>I’ve built this MarketRoute specifically for {state.companyName}. Create a free account to save the research and unlock the contact actions on your first eight opportunities.</p><ul><li><Icon name="check" size={13}/>No research restarts</li><li><Icon name="check" size={13}/>Your first eight stay free</li><li><Icon name="check" size={13}/>Email, phone and direct route actions unlock after sign-in</li></ul><a className="mr-button mr-button--primary" href="/signup?claim=discovery&next=%2Fapp%2Fopportunities">Create free account <Icon name="arrow" size={15}/></a><a className="mr-discovery-gate__signin" href="/login?claim=discovery&next=%2Fapp%2Fopportunities">Already have an account? Sign in and save this run.</a></div></div>}
  </div>;
}
