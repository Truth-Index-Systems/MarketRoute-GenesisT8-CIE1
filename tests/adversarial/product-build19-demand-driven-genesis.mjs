import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {execFileSync} from "node:child_process";
import {pathToFileURL} from "node:url";
const root=path.resolve(import.meta.dirname,"../..");
const temp=fs.mkdtempSync(path.join(os.tmpdir(),"mrv2-product19-"));
try{
  const shim=path.join(temp,"node-crypto.d.ts");
  fs.writeFileSync(shim,`declare module "node:crypto" { export function createHash(name:string): { update(value:string): any; digest(encoding:"hex"): string }; }\n`);
  execFileSync("tsc",[shim,"core/evidence/contracts.ts","core/evidence/canonical.ts","core/evidence/index.ts","core/research/contracts.ts","core/research/planner.ts","core/research/index.ts","--target","ES2022","--module","NodeNext","--moduleResolution","NodeNext","--outDir",temp,"--strict","--skipLibCheck","--lib","ES2022,DOM,DOM.Iterable"],{cwd:root,stdio:"pipe"});
  const m=await import(pathToFileURL(path.join(temp,"research/planner.js")).href+`?${Date.now()}`);
  const base={organisationId:"org",campaignId:"campaign",companyId:"company",referenceTime:"2026-08-17T20:30:00.000Z",lifecycleState:"COMMERCIAL_RESEARCH_REQUIRED",authorityEnvelopeFingerprint:"a".repeat(64),policy:{dailyBudgetUsd:1,maxJobCostUsd:.25,maxConcurrentJobs:2,maxWorkUnitsPerPlan:2,refreshHorizonHours:2},budget:{spentTodayUsd:0,reservedTodayUsd:0,activeJobs:0}};
  const campaignGap={gapKey:"r4:offer",layer:"R4",tier:"DECISION_BLOCKER",action:"ACQUIRE_CLAIM_EVIDENCE",subjectType:"COMPANY",subjectId:"company",claimKey:"commercial.offering",reasonCode:"EVIDENCE_REQUIRED",metadata:{}};
  const refreshGap={gapKey:"r4:revalidate",layer:"R4",tier:"CURRENTNESS_REPAIR",action:"REVALIDATE_R4",subjectType:"COMPANY",subjectId:"company",claimKey:null,reasonCode:"CURRENT_R4_REQUIRED",metadata:{}};
  const campaign=m.planResearch({...base,candidates:[campaignGap]});
  const refresh=m.planResearch({...base,candidates:[refreshGap]});
  const tests=[
    ["new paid research is explicitly customer campaign work",()=>assert.equal(campaign.workUnits[0].payload.researchOrigin,"CUSTOMER_CAMPAIGN")],
    ["currentness repair is explicitly customer refresh work",()=>assert.equal(refresh.workUnits[0].payload.researchOrigin,"CUSTOMER_REFRESH")],
    ["origin is included in deterministic plan identity",()=>assert.notEqual(campaign.planFingerprint,m.planResearch({...base,candidates:[{...campaignGap,tier:"CURRENTNESS_REPAIR",action:"REVALIDATE_R4"}]}).planFingerprint)],
    ["origin cannot create commercial authority fields",()=>{const text=JSON.stringify(campaign);for(const k of ["opportunityScore","routeQuality","viabilityScore"])assert.equal(text.includes(k),false)}],
  ];
  let passed=0;
  console.log("\nMarketRoute V2 Product Build 19 — Demand-Driven Genesis adversarial gate");
  for(const [name,fn] of tests){try{await fn();passed++;console.log(`PASS  ${name}`)}catch(e){console.error(`FAIL  ${name}: ${e instanceof Error?e.message:e}`)}}
  console.log(`\n${passed}/${tests.length} PASS`);
  if(passed!==tests.length)process.exitCode=1;
} finally {fs.rmSync(temp,{recursive:true,force:true});}
