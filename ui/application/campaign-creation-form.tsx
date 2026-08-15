"use client";

import { useEffect, useState } from "react";
import { Icon } from "@/ui/icons";

const draftKey="marketroute:new-campaign-draft:v1";
interface CampaignDraft {campaignName:string;sellerOfferingText:string;objectiveText:string;targetMarketText:string;constraintMode:string;hardConstraintsText:string}
const emptyDraft:CampaignDraft={campaignName:"",sellerOfferingText:"",objectiveText:"",targetMarketText:"",constraintMode:"",hardConstraintsText:""};

export function CampaignCreationForm(){
  const [draft,setDraft]=useState<CampaignDraft>(emptyDraft);
  const [loaded,setLoaded]=useState(false);

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

  return <form action="/api/campaigns" method="post" className="mr-login__form">
    <div className="mr-campaign-draft-state"><Icon name="check" size={14}/><span>{loaded?"Draft saved on this device":"Restoring draft…"}</span></div>
    <label><span>Campaign name</span><input name="campaignName" required minLength={3} maxLength={120} placeholder="UK logistics growth" value={draft.campaignName} onChange={field("campaignName")}/><small className="mr-field-help">Use a name you will recognise in campaign and opportunity views.</small></label>
    <label><span>What does your business currently sell?</span><textarea name="sellerOfferingText" required minLength={8} rows={3} placeholder="Bespoke software engineering and commercial intelligence systems for B2B organisations." value={draft.sellerOfferingText} onChange={field("sellerOfferingText")}/><small className="mr-field-help">MarketRoute rechecks current seller context before building the new campaign.</small></label>
    <label><span>What are you trying to achieve?</span><textarea name="objectiveText" required minLength={8} rows={3} placeholder="Win new B2B contracts." value={draft.objectiveText} onChange={field("objectiveText")}/></label>
    <label><span>Which market should MarketRoute research?</span><textarea name="targetMarketText" required minLength={3} rows={3} placeholder="UK logistics and supply-chain organisations." value={draft.targetMarketText} onChange={field("targetMarketText")}/></label>
    <fieldset className="mr-constraint-choice">
      <legend>Does this campaign have hard limits?</legend>
      <label className="mr-check-row"><input type="radio" name="constraintMode" value="DESCRIBED" required checked={draft.constraintMode==="DESCRIBED"} onChange={chooseConstraint}/><span>I have hard commercial limits and have described them below.</span></label>
      <label className="mr-check-row"><input type="radio" name="constraintMode" value="NONE" required checked={draft.constraintMode==="NONE"} onChange={chooseConstraint}/><span>I have no hard commercial restrictions beyond the brief above.</span></label>
    </fieldset>
    <label><span>Hard limits</span><textarea name="hardConstraintsText" rows={2} placeholder="For example: UK only; small organisations; B2B only." value={draft.hardConstraintsText} onChange={field("hardConstraintsText")} disabled={draft.constraintMode==="NONE"}/><small className="mr-field-help">Complete this only when “I have hard limits” is selected. Hard limits remain fail-closed.</small></label>
    <div className="mr-campaign-create__actions"><a className="mr-button mr-button--secondary" href="/app/campaigns">Cancel</a><button className="mr-button mr-button--primary" type="submit">Start preparing campaign <Icon name="arrow" size={18}/></button></div>
  </form>;
}
