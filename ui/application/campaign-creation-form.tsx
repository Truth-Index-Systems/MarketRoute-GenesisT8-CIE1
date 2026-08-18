"use client";

import { useEffect, useMemo, useState } from "react";
import type { CampaignCapacity,PublicPlan } from "@/application/commercial/service";
import { Icon } from "@/ui/icons";

const draftKey="marketroute:new-campaign-draft:v3";
interface CampaignDraft {campaignName:string;sellerOfferingText:string;objectiveText:string;targetMarketText:string;constraintMode:string;hardConstraintsText:string}
const emptyDraft:CampaignDraft={campaignName:"",sellerOfferingText:"",objectiveText:"",targetMarketText:"",constraintMode:"NONE",hardConstraintsText:""};

function marketLabel(limit:number){return `${limit} active market${limit===1?"":"s"}`;}

export function CampaignCreationForm({capacity,plans,processing=false,initialPaywallOpen=false}:{capacity:CampaignCapacity;plans:PublicPlan[];processing?:boolean;initialPaywallOpen?:boolean}){
  const [draft,setDraft]=useState<CampaignDraft>(emptyDraft);
  const [loaded,setLoaded]=useState(false);
  const [paywallOpen,setPaywallOpen]=useState(initialPaywallOpen);
  const eligiblePlans=useMemo(()=>plans.filter(plan=>plan.activeMarketLimit>=capacity.activeMarketCount+1),[plans,capacity.activeMarketCount]);

  useEffect(()=>{
    try{
      const stored=localStorage.getItem(draftKey)??localStorage.getItem("marketroute:new-campaign-draft:v2");
      if(stored){
        const value=JSON.parse(stored) as Partial<CampaignDraft>;
        const restored={...emptyDraft,...Object.fromEntries(Object.entries(value).filter(([,item])=>typeof item==="string"))} as CampaignDraft;
        if(!["DESCRIBED","NONE"].includes(restored.constraintMode))restored.constraintMode="NONE";
        setDraft(restored);
      }
    }catch{
      localStorage.removeItem(draftKey);
      localStorage.removeItem("marketroute:new-campaign-draft:v2");
    }
    setLoaded(true);
  },[]);
  useEffect(()=>{if(loaded)localStorage.setItem(draftKey,JSON.stringify(draft));},[draft,loaded]);

  const field=(name:keyof CampaignDraft)=>(event:React.ChangeEvent<HTMLInputElement|HTMLTextAreaElement>)=>setDraft(current=>({...current,[name]:event.target.value}));
  const advanced=draft.constraintMode==="DESCRIBED";
  const gated=!capacity.canCreate;
  const paid=capacity.mode==="PAID"||capacity.mode==="FULL";
  function submit(event:React.FormEvent<HTMLFormElement>){if(gated){event.preventDefault();setPaywallOpen(true);}}
  function toggleAdvanced(){setDraft(current=>({...current,constraintMode:current.constraintMode==="DESCRIBED"?"NONE":"DESCRIBED",hardConstraintsText:current.constraintMode==="DESCRIBED"?"":current.hardConstraintsText}));}

  const capacityCopy=capacity.mode==="FULL"
    ? "Grandfathered full access is active. This campaign can start now; standard plan limits apply only if you move to a subscription."
    : capacity.mode==="DISCOVERY_FREE"
      ? "Your original Discovery market is preserved. Configure this new campaign first; MarketRoute will ask you to choose access only when you start it."
      : capacity.mode==="UNENTITLED"
        ? "Configure the campaign first. MarketRoute will ask you to choose a plan only when you start it."
        : gated
          ? `${capacity.planName??"Your plan"} is using ${capacity.activeMarketCount} of ${capacity.activeMarketLimit} active markets. Your brief stays saved while you upgrade.`
          : `${capacity.activeMarketCount} of ${capacity.activeMarketLimit} active markets are currently in use.`;

  return <>
    <section className="mr-campaign-entry-card">
      <span>START A NEW MARKET</span>
      <h2>What should MarketRoute work on?</h2>
      <p>Keep it simple. Give MarketRoute the offer, the market and the outcome; Genesis will structure the research from there.</p>

      <form action="/api/campaigns" method="post" className="mr-campaign-entry-form" onSubmit={submit}>
        <div className="mr-campaign-entry-meta">
          <div className="mr-campaign-draft-state"><Icon name="check" size={14}/><span>{loaded?"Draft saved on this device":"Restoring draft…"}</span></div>
          <div className={`mr-campaign-capacity-note ${gated?"is-gated":""}`}><Icon name={gated?"shield":"campaigns"} size={16}/><span>{capacityCopy}</span></div>
        </div>

        <label><span>Campaign name</span><input name="campaignName" required minLength={3} maxLength={120} autoComplete="off" placeholder="UK operations leaders" value={draft.campaignName} onChange={field("campaignName")}/><small>Give this market a name you will recognise later.</small></label>
        <label><span>What do you sell?</span><textarea name="sellerOfferingText" required minLength={8} maxLength={2000} rows={4} placeholder="Handover and shift-continuation software for operational teams." value={draft.sellerOfferingText} onChange={field("sellerOfferingText")}/><small>MarketRoute rechecks your current seller context before this campaign starts.</small></label>
        <label><span>Who do you want to sell to?</span><textarea name="targetMarketText" required minLength={3} maxLength={2000} rows={3} placeholder="UK logistics, manufacturing and warehouse operations teams." value={draft.targetMarketText} onChange={field("targetMarketText")}/></label>
        <label><span>What do you want MarketRoute to achieve?</span><textarea name="objectiveText" required minLength={8} maxLength={2000} rows={3} placeholder="Find organisations with a strong reason to improve shift handovers and a route to the operational buyer." value={draft.objectiveText} onChange={field("objectiveText")}/></label>

        <div className={`mr-campaign-advanced ${advanced?"is-open":""}`}>
          <input type="hidden" name="constraintMode" value={advanced?"DESCRIBED":"NONE"}/>
          <button type="button" className="mr-campaign-advanced__toggle" onClick={toggleAdvanced} aria-expanded={advanced}>
            <span><Icon name="shield" size={15}/><b>{advanced?"Hard limits added":"Add hard limits"}</b><small>Optional · geography, company type or other non-negotiables</small></span>
            <strong>{advanced?"−":"+"}</strong>
          </button>
          {advanced&&<label className="mr-campaign-advanced__field"><span>Hard limits</span><textarea name="hardConstraintsText" required minLength={3} maxLength={2000} rows={3} placeholder="For example: UK only; B2B only; 50–1,000 employees." value={draft.hardConstraintsText} onChange={field("hardConstraintsText")}/><small>MarketRoute treats these as fail-closed constraints, not preferences.</small></label>}
        </div>

        {processing&&<div className="mr-alert"><Icon name="clock" size={16}/><span>MarketRoute is already preparing another campaign. This brief is saved; start it after the current preparation finishes.</span></div>}
        <button className="mr-button mr-button--primary mr-campaign-entry-submit" type="submit" disabled={processing}>{gated?"Continue to campaign access":"Build this MarketRoute"} <Icon name="arrow" size={18}/></button>
        <small className="mr-campaign-entry-foot">MarketRoute checks Genesis intelligence first and researches only what this campaign needs. Plan capacity is enforced when you start the brief.</small>
      </form>
    </section>

    {paywallOpen&&<div className="mr-commercial-modal" role="dialog" aria-modal="true" aria-label="Campaign plan limit"><button className="mr-commercial-modal__backdrop" type="button" onClick={()=>setPaywallOpen(false)} aria-label="Close campaign access"/><div className="mr-commercial-modal__panel"><div className="mr-campaign-paywall"><header><div><span>ADD ANOTHER CAMPAIGN</span><h2>Unlock another active market.</h2><p>{capacity.activeMarketCount>0?`You currently have ${capacity.activeMarketCount} live campaign${capacity.activeMarketCount===1?"":"s"}. Choose a plan that can accommodate campaign ${capacity.activeMarketCount+1}.`:"Additional campaigns are a paid MarketRoute capability. Your configured brief stays saved while you choose access."}</p></div><button type="button" onClick={()=>setPaywallOpen(false)} aria-label="Close">×</button></header>
      {eligiblePlans.length>0?<div className="mr-campaign-paywall__plans">{eligiblePlans.map(plan=><article key={plan.planCode} className={plan.planCode===capacity.nextPlanCode?"is-next":""}>{plan.planCode===capacity.nextPlanCode&&<b>RIGHT-SIZED NEXT PLAN</b>}<span>{plan.displayName}</span><strong>£{Math.round(plan.monthlyPriceGbp)}<small>/month</small></strong><p>{marketLabel(plan.activeMarketLimit)}</p>{paid?null:<form action="/api/billing/checkout" method="post"><input type="hidden" name="planCode" value={plan.planCode}/><button className="mr-button mr-button--primary" type="submit">Choose {plan.displayName} <Icon name="arrow" size={14}/></button></form>}</article>)}</div>:<div className="mr-alert"><Icon name="shield" size={16}/><span>Your current self-serve plan range is full. Archive a live campaign or contact support for a larger workspace.</span></div>}
      {paid&&eligiblePlans.length>0&&<form action="/api/billing/portal" method="post" className="mr-campaign-paywall__portal"><button className="mr-button mr-button--primary" type="submit">Upgrade current plan <Icon name="arrow" size={14}/></button><small>Plan changes are completed securely in the billing portal. Your campaign brief stays saved on this device.</small></form>}
      {eligiblePlans.length===0&&<a className="mr-button mr-button--secondary" href="/support">Contact support</a>}
      <footer><Icon name="shield" size={14}/><span>Campaign limits control product capacity only. They never change Truth, CIE or opportunity authority.</span></footer></div></div></div>}
  </>;
}
