"use client";
import { useState } from "react";
import { Icon } from "@/ui/icons";
import type { LockedOpportunityTeaser,PublicPlan } from "@/application/commercial/service";

function PlanCard({plan}:{plan:PublicPlan}){
  const meta=plan.metadata??{};const recommended=meta.recommended===true;
  const bullets=[String(meta.capacityLabel??"Research capacity"),String(meta.depthLabel??"Company research"),String(meta.monitoringLabel??"Opportunity monitoring"),"Email, phone and direct route intelligence",`${plan.activeMarketLimit} active market${plan.activeMarketLimit===1?"":"s"}`].filter(Boolean);
  return <article className={`mr-plan-card ${recommended?"is-recommended":""}`}>
    {recommended&&<span className="mr-plan-card__recommended">RECOMMENDED</span>}
    <header><div><span>MARKETROUTE</span><h3>{plan.displayName}</h3></div><div className="mr-plan-card__price"><strong>£{Math.round(plan.monthlyPriceGbp)}</strong><small>/ month</small></div></header>
    <ul>{bullets.map((item,index)=><li key={`${item}-${index}`}><Icon name="check" size={13}/>{item}</li>)}</ul>
    <form action="/api/billing/checkout" method="post"><input type="hidden" name="planCode" value={plan.planCode}/><button className={`mr-button ${recommended?"mr-button--primary":"mr-button--secondary"}`} type="submit">Choose {plan.displayName} <Icon name="arrow" size={14}/></button></form>
  </article>;
}

export function PlanChooser({plans,title="Keep MarketRoute working for you",lockedCount=0,onClose}:{plans:PublicPlan[];title?:string;lockedCount?:number;onClose?:()=>void}){
  return <div className="mr-plan-chooser"><div className="mr-plan-chooser__head"><div><span>UNLOCK MARKETROUTE</span><h2>{title}</h2><p>{lockedCount>0?`MarketRoute has already found ${lockedCount} additional opportunit${lockedCount===1?"y":"ies"}. Choose a plan to unlock them and continue demand-driven research.`:"Choose the research capacity that matches how actively you want MarketRoute working your market."}</p></div>{onClose&&<button type="button" onClick={onClose} aria-label="Close plans">×</button>}</div><div className="mr-plan-grid">{plans.map(plan=><PlanCard key={plan.planCode} plan={plan}/>)}</div><footer><Icon name="shield" size={14}/><span>Plans control product access and research capacity. They never change Truth Index, CIE or contact authority.</span></footer></div>;
}

export function LockedOpportunityFeed({items,plans,totalLocked}:{items:LockedOpportunityTeaser[];plans:PublicPlan[];totalLocked:number}){
  const [open,setOpen]=useState(false);
  if(totalLocked<=0)return null;
  return <section className="mr-locked-opportunities">
    <div className="mr-locked-opportunities__head"><div><span>NEW OPPORTUNITIES FOUND</span><h2>{totalLocked} more route{totalLocked===1?" is":"s are"} waiting.</h2><p>MarketRoute has finished enough research to establish these as ready opportunities. Your free eight stay unlocked; new opportunities require a plan.</p></div><button className="mr-button mr-button--primary" type="button" onClick={()=>setOpen(true)}>Unlock opportunities <Icon name="arrow" size={14}/></button></div>
    <div className="mr-locked-opportunity-grid">{items.map((item)=><button className="mr-locked-opportunity" type="button" key={item.opportunityId} onClick={()=>setOpen(true)}><div className="mr-locked-opportunity__blur" aria-hidden="true"><span>READY OPPORTUNITY</span><strong>{item.companyName}</strong><small>{item.canonicalDomain??"Verified commercial route"}</small><p>Commercial reasoning and verified contact route available.</p></div><div className="mr-locked-opportunity__cover"><Icon name="shield" size={18}/><strong>New opportunity</strong><span>Upgrade to view the company, reasoning and contact route.</span></div></button>)}</div>
    {totalLocked>items.length&&<button className="mr-locked-opportunities__more" type="button" onClick={()=>setOpen(true)}>+ {totalLocked-items.length} additional opportunities waiting</button>}
    {open&&<div className="mr-commercial-modal" role="dialog" aria-modal="true" aria-label="MarketRoute plans"><button className="mr-commercial-modal__backdrop" onClick={()=>setOpen(false)} aria-label="Close plans"/><div className="mr-commercial-modal__panel"><PlanChooser plans={plans} lockedCount={totalLocked} onClose={()=>setOpen(false)}/></div></div>}
  </section>;
}

export function LockedOpportunityDetail({item,plans,totalLocked}:{item:LockedOpportunityTeaser;plans:PublicPlan[];totalLocked:number}){
  return <div className="mr-locked-detail"><div className="mr-locked-detail__card"><Icon name="shield" size={25}/><span>READY · LOCKED</span><h1>A new opportunity is ready.</h1><p>MarketRoute has established a current commercial opportunity and route for this organisation. The company intelligence, reasoning and contact details remain server-redacted until this workspace has a paid plan.</p><div className="mr-locked-detail__safe"><small>Safe preview</small><strong>{item.companyName}</strong><span>{item.canonicalDomain??"Company identity established"}</span></div></div><PlanChooser plans={plans} lockedCount={totalLocked}/></div>;
}
