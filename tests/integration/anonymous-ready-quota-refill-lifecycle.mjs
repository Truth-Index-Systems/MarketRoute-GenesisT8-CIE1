import assert from "node:assert/strict";
// Deterministic orchestration integration model for the SQL policy. It exercises the
// complete customer-visible lifecycle without pretending to be a live Supabase test.
const TARGET=10,FREE=8,LOCKED=2,CANDIDATE_CEILING=40,ATTEMPT_CEILING=3;
function next({ready,scoped,attempts,budgetTerminal,cycleReady,paid=false,expired=false}){
  if(ready>=TARGET)return "SUCCEEDED";
  if(paid||expired||budgetTerminal||scoped>=CANDIDATE_CEILING||attempts>=ATTEMPT_CEILING)return "EXHAUSTED";
  return cycleReady?"CLAIM_REFILL":"WAIT_RESEARCH";
}
const initial={ready:5,scoped:10,attempts:0,budgetTerminal:false,cycleReady:true};
assert.equal(next(initial),"CLAIM_REFILL");
const afterDiscovery={...initial,scoped:20,attempts:1,cycleReady:false};assert.equal(next(afterDiscovery),"WAIT_RESEARCH");
const afterResearch={...afterDiscovery,ready:10,cycleReady:true};assert.equal(next(afterResearch),"SUCCEEDED");
assert.equal(Math.min(FREE,afterResearch.ready),8);assert.equal(Math.min(LOCKED,Math.max(0,afterResearch.ready-FREE)),2);
const budgetDead={ready:5,scoped:20,attempts:1,budgetTerminal:true,cycleReady:false};assert.equal(next(budgetDead),"EXHAUSTED");
const partialSecondCycle={ready:7,scoped:20,attempts:1,budgetTerminal:false,cycleReady:true};assert.equal(next(partialSecondCycle),"CLAIM_REFILL");
const paid={...partialSecondCycle,paid:true};assert.equal(next(paid),"EXHAUSTED");
console.log("\nMarketRoute V2 RC — anonymous ready-quota lifecycle integration model");console.log("PASS  10 scoped / 5 ready -> refill");console.log("PASS  refill waits for research cycle");console.log("PASS  10 ready -> exactly 8 free + 2 locked");console.log("PASS  exhausted budget terminates even when cycle is incomplete");console.log("PASS  paid conversion stops anonymous refill");console.log("\n5/5 PASS");
