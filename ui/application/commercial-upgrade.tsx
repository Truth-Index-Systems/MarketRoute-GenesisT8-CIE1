"use client";
import { useState } from "react";
import { Icon } from "@/ui/icons";
import type { LockedOpportunityTeaser,PublicPlan } from "@/application/commercial/service";

function PlanCard({plan}:{plan:PublicPlan}){
  const meta=plan.metadata??{};const recommended=meta.recommended===true;
  const bullets=[`${plan.activeMarketLimit} active market${plan.activeMarketLimit===1?"":"s"}`,"Ongoing company research","Opportunity monitoring","Buyer and contact routes","Email, phone and direct links when ready"];
  return <article className={`mr-plan-card ${recommended?"is-recommended":""}`}>
    {recommended&&<span className="mr-plan-card__recommended">RECOMMENDED</span>}
    <header><div><span>MARKETROUTE</span><h3>{plan.displayName}</h3></div><div className="mr-plan-card__price"><strong>£{Math.round(plan.monthlyPriceGbp)}</strong><small>/ month</small></div></header>
    <ul>{bullets.map((item,index)=><li key={`${item}-${index}`}><Icon name="check" size={13}/>{item}</li>)}</ul>
    <form action="/api/billing/checkout" method="post"><input type="hidden" name="planCode" value={plan.planCode}/><button className={`mr-button ${recommended?"mr-button--primary":"mr-button--secondary"}`} type="submit">Choose {plan.displayName} <Icon name="arrow" size={14}/></button></form>
  </article>;
}

export function PlanChooser({plans,title="Keep MarketRoute working for you",lockedCount=0,onClose}:{plans:PublicPlan[];title?:string;lockedCount?:number;onClose?:()=>void}){
  return <div className="mr-plan-chooser"><div className="mr-plan-chooser__head"><div><span>KEEP MARKETROUTE WORKING</span><h2>{title}</h2><p>{lockedCount>0?`MarketRoute has already found ${lockedCount} new opportunit${lockedCount===1?"y":"ies"}. Choose a plan to unlock them and keep the research running.`:"Choose the plan that matches how actively you want MarketRoute working your markets."}</p></div>{onClose&&<button type="button" onClick={onClose} aria-label="Close plans">×</button>}</div><div className="mr-plan-grid">{plans.map(plan=><PlanCard key={plan.planCode} plan={plan}/>)}</div><footer><Icon name="shield" size={14}/><span>Upgrading unlocks more opportunities and more ongoing research. Existing research stays intact.</span></footer></div>;
}

export function LockedOpportunityFeed({items,plans,totalLocked}:{items:LockedOpportunityTeaser[];plans:PublicPlan[];totalLocked:number}){
  const [open,setOpen]=useState(false);
  if(totalLocked<=0)return null;
  return <section className="mr-locked-opportunities">
    <div className="mr-locked-opportunities__head"><div><span>MORE OPPORTUNITIES FOUND</span><h2>{totalLocked} more opportunit{totalLocked===1?" is":"s are"} waiting.</h2><p>MarketRoute has found more companies worth your attention. Your free eight stay unlocked; upgrade to see the rest.</p></div><button className="mr-button mr-button--primary" type="button" onClick={()=>setOpen(true)}>Unlock opportunities <Icon name="arrow" size={14}/></button></div>
    <div className="mr-locked-opportunity-grid">{items.map((item)=><button className="mr-locked-opportunity" type="button" key={item.opportunityId} onClick={()=>setOpen(true)}><div className="mr-locked-opportunity__blur" aria-hidden="true"><span>NEW OPPORTUNITY</span><strong>{item.companyName}</strong><small>{item.canonicalDomain??"Company route ready"}</small><p>Why it matters and the contact route are ready.</p></div><div className="mr-locked-opportunity__cover"><Icon name="shield" size={18}/><strong>New opportunity</strong><span>Upgrade to see the company, why it matters and how to reach them.</span></div></button>)}</div>
    {totalLocked>items.length&&<button className="mr-locked-opportunities__more" type="button" onClick={()=>setOpen(true)}>+ {totalLocked-items.length} new opportunities waiting</button>}
    {open&&<div className="mr-commercial-modal" role="dialog" aria-modal="true" aria-label="MarketRoute plans"><button className="mr-commercial-modal__backdrop" onClick={()=>setOpen(false)} aria-label="Close plans"/><div className="mr-commercial-modal__panel"><PlanChooser plans={plans} lockedCount={totalLocked} onClose={()=>setOpen(false)}/></div></div>}
  </section>;
}

export function LockedOpportunityDetail({item,plans,totalLocked}:{item:LockedOpportunityTeaser;plans:PublicPlan[];totalLocked:number}){
  return <div className="mr-locked-detail"><div className="mr-locked-detail__card"><Icon name="shield" size={25}/><span>READY · LOCKED</span><h1>Another opportunity is waiting.</h1><p>MarketRoute has found a company worth your attention and a route in. Upgrade to reveal the company, the reason and the contact details.</p><div className="mr-locked-detail__safe"><small>Preview</small><strong>{item.companyName}</strong><span>{item.canonicalDomain??"Company identity established"}</span></div></div><PlanChooser plans={plans} lockedCount={totalLocked}/></div>;
}
