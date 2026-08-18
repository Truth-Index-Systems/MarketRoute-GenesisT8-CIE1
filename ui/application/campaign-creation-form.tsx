"use client";

import { useEffect, useMemo, useState } from "react";
import type { CampaignCapacity,PublicPlan } from "@/application/commercial/service";
import { Icon } from "@/ui/icons";

const draftKey="marketroute:new-campaign-draft:v2";
interface CampaignDraft {campaignName:string;sellerOfferingText:string;objectiveText:string;targetMarketText:string;constraintMode:string;hardConstraintsText:string}
const emptyDraft:CampaignDraft={campaignName:"",sellerOfferingText:"",objectiveText:"",targetMarketText:"",constraintMode:"",hardConstraintsText:""};

function marketLabel(limit:number){return `${limit} active market${limit===1?"":"s"}`;}

export function CampaignCreationForm({capacity,plans,processing=false,initialPaywallOpen=false}:{capacity:CampaignCapacity;plans:PublicPlan[];processing?:boolean;initialPaywallOpen?:boolean}){
  const [draft,setDraft]=useState<CampaignDraft>(emptyDraft);
  const [loaded,setLoaded]=useState(false);
  const [paywallOpen,setPaywallOpen]=useState(initialPaywallOpen);
  const eligiblePlans=useMemo(()=>plans.filter(plan=>plan.activeMarketLimit>=capacity.activeMarketCount+1),[plans,capacity.activeMarketCount]);

  useEffect(()=>{
    try{
      const stored=localStorage.getItem(draftKey);
      if(stored){const value=JSON.parse(stored) as Partial<CampaignDraft>;setDraft({...emptyDraft,...Object.fromEntries(Object.entries(value).filter(([,item])=>typeof item==="string"))});}
    }catch{localStorage.removeItem(draftKey);}
    setLoaded(true);
  },[]);
  useEffect(()=>{if(loaded)localStorage.setItem(draftKey,JSON.stringify(draft));},[draft,loaded]);

  const field=(name:keyof CampaignDraft)=>(event:React.ChangeEvent<HTMLInputElement|HTMLTextAreaElement>)=>setDraft(current=>({...current,[name]:event.target.value}));
  const chooseConstraint=(event:React.ChangeEvent<HTMLInputElement>)=>setDraft(current=>({...current,constraintMode:event.target.value,hardConstraintsText:event.target.value==="NONE"?"":current.hardConstraintsText}));
  const gated=!capacity.canCreate;
  const paid=capacity.mode==="PAID"||capacity.mode==="FULL";
  function submit(event:React.FormEvent<HTMLFormElement>){if(gated){event.preventDefault();setPaywallOpen(true);}}

  return <>
    <form action="/api/campaigns" method="post" className="mr-login__form" onSubmit={submit}>
      <div className="mr-campaign-draft-state"><Icon name="check" size={14}/><span>{loaded?"Draft saved on this device":"Restoring draft…"}</span></div>
      <div className={`mr-campaign-capacity-note ${gated?"is-gated":""}`}><Icon name={gated?"shield":"campaigns"} size={16}/><span>{capacity.mode==="DISCOVERY_FREE"?"Discovery is your original one-time market run. Configure another campaign here; upgrading will be required before it starts.":capacity.mode==="UNENTITLED"?"Configure the campaign first. MarketRoute will ask you to choose a plan before it starts.":gated?`${capacity.planName??"Your plan"} is using ${capacity.activeMarketCount} of ${capacity.activeMarketLimit} active-market slots. Your brief will stay saved while you upgrade.`:`${capacity.activeMarketCount} of ${capacity.activeMarketLimit} active-market slots are currently in use.`}</span></div>
      <label><span>Campaign name</span><input name="campaignName" required minLength={3} maxLength={120} placeholder="UK logistics growth" value={draft.campaignName} onChange={field("campaignName")}/><small className="mr-field-help">Use a name you will recognise in campaign and opportunity views.</small></label>
      <label><span>What does your business currently sell?</span><textarea name="sellerOfferingText" required minLength={8} rows={3} placeholder="Bespoke software engineering and commercial intelligence systems for B2B organisations." value={draft.sellerOfferingText} onChange={field("sellerOfferingText")}/><small className="mr-field-help">MarketRoute rechecks current seller context before building this campaign.</small></label>
      <label><span>What are you trying to achieve?</span><textarea name="objectiveText" required minLength={8} rows={3} placeholder="Win new B2B contracts." value={draft.objectiveText} onChange={field("objectiveText")}/></label>
      <label><span>Which market should MarketRoute research?</span><textarea name="targetMarketText" required minLength={3} rows={3} placeholder="UK logistics and supply-chain organisations." value={draft.targetMarketText} onChange={field("targetMarketText")}/></label>
      <fieldset className="mr-constraint-choice">
        <legend>Does this campaign have hard limits?</legend>
        <label className="mr-check-row"><input type="radio" name="constraintMode" value="DESCRIBED" required checked={draft.constraintMode==="DESCRIBED"} onChange={chooseConstraint}/><span>I have hard commercial limits and have described them below.</span></label>
        <label className="mr-check-row"><input type="radio" name="constraintMode" value="NONE" required checked={draft.constraintMode==="NONE"} onChange={chooseConstraint}/><span>I have no hard commercial restrictions beyond the brief above.</span></label>
      </fieldset>
      <label><span>Hard limits</span><textarea name="hardConstraintsText" rows={2} placeholder="For example: UK only; small organisations; B2B only." value={draft.hardConstraintsText} onChange={field("hardConstraintsText")} disabled={draft.constraintMode==="NONE"}/><small className="mr-field-help">Complete this only when “I have hard limits” is selected. Hard limits remain fail-closed.</small></label>
      {processing&&<div className="mr-alert"><Icon name="clock" size={16}/><span>MarketRoute is already preparing another campaign. This brief is saved; start it after the current preparation finishes.</span></div>}
      <div className="mr-campaign-create__actions"><a className="mr-button mr-button--secondary" href="/app/campaigns">Cancel</a><button className="mr-button mr-button--primary" type="submit" disabled={processing}>{gated?"Continue to campaign access":"Start preparing campaign"} <Icon name="arrow" size={18}/></button></div>
    </form>

    {paywallOpen&&<div className="mr-commercial-modal" role="dialog" aria-modal="true" aria-label="Campaign plan limit"><button className="mr-commercial-modal__backdrop" type="button" onClick={()=>setPaywallOpen(false)} aria-label="Close campaign access"/><div className="mr-commercial-modal__panel"><div className="mr-campaign-paywall"><header><div><span>ADD ANOTHER CAMPAIGN</span><h2>Unlock another active market.</h2><p>{capacity.activeMarketCount>0?`You currently have ${capacity.activeMarketCount} live campaign${capacity.activeMarketCount===1?"":"s"}. Choose a plan that can accommodate campaign ${capacity.activeMarketCount+1}.`:"Additional campaigns are a paid MarketRoute capability. Your configured brief stays saved while you choose access."}</p></div><button type="button" onClick={()=>setPaywallOpen(false)} aria-label="Close">×</button></header>
      {eligiblePlans.length>0?<div className="mr-campaign-paywall__plans">{eligiblePlans.map(plan=><article key={plan.planCode} className={plan.planCode===capacity.nextPlanCode?"is-next":""}>{plan.planCode===capacity.nextPlanCode&&<b>RIGHT-SIZED NEXT PLAN</b>}<span>{plan.displayName}</span><strong>£{Math.round(plan.monthlyPriceGbp)}<small>/month</small></strong><p>{marketLabel(plan.activeMarketLimit)}</p>{paid?null:<form action="/api/billing/checkout" method="post"><input type="hidden" name="planCode" value={plan.planCode}/><button className="mr-button mr-button--primary" type="submit">Choose {plan.displayName} <Icon name="arrow" size={14}/></button></form>}</article>)}</div>:<div className="mr-alert"><Icon name="shield" size={16}/><span>Your current self-serve plan range is full. Archive a live campaign or contact support for a larger workspace.</span></div>}
      {paid&&eligiblePlans.length>0&&<form action="/api/billing/portal" method="post" className="mr-campaign-paywall__portal"><button className="mr-button mr-button--primary" type="submit">Upgrade current plan <Icon name="arrow" size={14}/></button><small>Plan changes are completed securely in the billing portal. Your campaign brief stays saved on this device.</small></form>}
      {eligiblePlans.length===0&&<a className="mr-button mr-button--secondary" href="/support">Contact support</a>}
      <footer><Icon name="shield" size={14}/><span>Campaign limits control product capacity only. They never change Truth, CIE or opportunity authority.</span></footer></div></div></div>}
  </>;
}
