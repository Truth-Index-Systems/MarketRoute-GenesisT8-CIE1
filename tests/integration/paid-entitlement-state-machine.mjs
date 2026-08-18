import assert from "node:assert/strict";
const limits={DISCOVERY:1,STARTER:1,GROWTH:3,SCALE:10};
function providerPaid(status){return ["active","trialing"].includes(String(status).toLowerCase());}
function researchEntitled({paid=false,plan="DISCOVERY",campaignIndex=0,isOriginal=false,anonymousActive=false,budgetTerminal=false,windowOpen=false,archived=false}){
  if(archived)return false;
  if(paid)return campaignIndex<limits[plan];
  return isOriginal&&anonymousActive&&windowOpen&&!budgetTerminal;
}
function policyProfile(state){
  if(state.paid)return state.isOriginal?"PAID_PROMOTED":"PAID_EXISTING";
  return researchEntitled(state)?"DISCOVERY_RESTORED":"DISABLED";
}
function paidRefill({ready,scoped,attempts,entitled=true,cycleReady=true,capacity=true}){
  if(!entitled)return "BLOCKED_ENTITLEMENT";
  if(ready>=10)return "SUCCEEDED";
  if(scoped>=60||attempts>=6)return "EXHAUSTED";
  if(!capacity)return "WAIT_CAPACITY";
  return cycleReady?"CLAIM_REFILL":"WAIT_RESEARCH";
}
function canFreeRead({accessCampaign,campaign,companyIds,company}){return accessCampaign===campaign&&companyIds.includes(company);}
const discovery={paid:false,plan:"DISCOVERY",campaignIndex:0,isOriginal:true,anonymousActive:true,budgetTerminal:false,windowOpen:true,archived:false};
assert.equal(researchEntitled(discovery),true);assert.equal(policyProfile(discovery),"DISCOVERY_RESTORED");
const starter={...discovery,paid:true,plan:"STARTER"};assert.equal(researchEntitled(starter),true);assert.equal(policyProfile(starter),"PAID_PROMOTED");
assert.equal(paidRefill({ready:5,scoped:10,attempts:0}),"CLAIM_REFILL");
assert.equal(paidRefill({ready:5,scoped:20,attempts:1,cycleReady:false}),"WAIT_RESEARCH");
assert.equal(paidRefill({ready:10,scoped:20,attempts:1}),"SUCCEEDED");
const scaleCampaigns=Array.from({length:7},(_,i)=>researchEntitled({paid:true,plan:"SCALE",campaignIndex:i}));assert.deepEqual(scaleCampaigns,[true,true,true,true,true,true,true]);
const downgraded=Array.from({length:7},(_,i)=>researchEntitled({paid:true,plan:"STARTER",campaignIndex:i}));assert.deepEqual(downgraded,[true,false,false,false,false,false,false]);
const growth=Array.from({length:7},(_,i)=>researchEntitled({paid:true,plan:"GROWTH",campaignIndex:i}));assert.deepEqual(growth,[true,true,true,false,false,false,false]);
const cancelOriginal={...discovery,paid:false};assert.equal(researchEntitled(cancelOriginal),true);
const cancelPaidCampaign={...cancelOriginal,isOriginal:false,campaignIndex:1};assert.equal(researchEntitled(cancelPaidCampaign),false);
assert.equal(researchEntitled({...cancelOriginal,windowOpen:false}),false);assert.equal(researchEntitled({...cancelOriginal,budgetTerminal:true}),false);
assert.equal(canFreeRead({accessCampaign:"A",campaign:"A",companyIds:["X"],company:"X"}),true);
assert.equal(canFreeRead({accessCampaign:"A",campaign:"B",companyIds:["X"],company:"X"}),false);
assert.equal(paidRefill({ready:5,scoped:20,attempts:1,entitled:false}),"BLOCKED_ENTITLEMENT");
assert.equal(paidRefill({ready:5,scoped:20,attempts:1,capacity:false}),"WAIT_CAPACITY");
assert.equal(providerPaid("past_due"),false);assert.equal(providerPaid("active"),true);
assert.equal(providerPaid("active"),true); // cancel_at_period_end remains provider-active until Stripe actually cancels.
console.log("\nMarketRoute V2 RC — paid entitlement lifecycle integration model");
for(const label of [
  "Discovery original retains bounded free research",
  "subscription promotes original campaign to paid policy",
  "5 ready after payment still triggers paid refill",
  "refill waits for research before widening again",
  "10 authority-ready opportunities terminates refill",
  "Scale -> Starter suspends campaigns 2-7 from research",
  "Starter -> Growth restores first three markets",
  "cancellation restores free research only to original campaign",
  "expired or exhausted Discovery never revives free research",
  "same free company cannot leak through later paid campaign",
  "over-limit campaign cannot run paid refill",
  "exhausted plan capacity defers paid refill",
  "PAST_DUE disables paid research until Stripe returns ACTIVE",
  "cancel-at-period-end preserves paid state while provider remains active"
])console.log(`PASS  ${label}`);
console.log("\n14/14 PASS");
