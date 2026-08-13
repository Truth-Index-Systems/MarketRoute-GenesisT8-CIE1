import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";

const root=path.resolve(import.meta.dirname,"../..");
const temp=fs.mkdtempSync(path.join(os.tmpdir(),"mrv2-r4-"));
try {
  execFileSync("tsc",[
    "core/evidence/contracts.ts","core/evidence/canonical.ts","core/evidence/index.ts",
    "core/truth/contracts.ts","core/seller-genome/contracts.ts",
    "core/commercial-reality/contracts.ts","core/commercial-reality/engine.ts","core/commercial-reality/index.ts",
    "--target","ES2022","--module","NodeNext","--moduleResolution","NodeNext","--outDir",temp,"--strict","--skipLibCheck","--lib","ES2022,DOM,DOM.Iterable"
  ],{cwd:root,stdio:"pipe"});
  const r4=await import(pathToFileURL(path.join(temp,"commercial-reality/engine.js")).href+`?v=${Date.now()}`);
  const tests=[]; const test=(name,fn)=>tests.push({name,fn});
  const snap=(key,state,value,id="1",next="2026-09-01T00:00:00.000Z")=>({snapshotId:id.padStart(36,"0"),snapshotFingerprint:(id.repeat(64)).slice(0,64),claimId:`c${id}`.padEnd(36,"0"),claimKey:key,propositionFingerprint:(`${key}:${value}`).padEnd(64,"x").slice(0,64),truthState:state,canonicalValueText:value,objectJson:value,nextRevalidationAt:next});
  const semantic=()=>({
    offerings:{state:"DECLARED",items:[{offeringKey:"software",problemCodes:[],outcomeCodes:[],deliveryModeCodes:[]}]},
    capabilities:{state:"DECLARED",items:[]},
    commercialObjectives:{state:"DECLARED",items:[{objectiveKey:"customers",objectiveType:"ACQUIRE_CUSTOMERS",offeringKeys:["software"],desiredActionCode:"call",outcomeCodes:[]}]},
    delivery:{state:"DECLARED",modeCodes:["remote"]}, serviceGeography:{state:"DECLARED",countryCodes:["GB"],regionCodes:[]},
    targetCharacteristics:{state:"EXPLICIT_NONE",industryCodes:[],companySizeBands:[],businessModelCodes:[]},
    buyerAssumptions:{state:"EXPLICIT_NONE",roleCodes:[],departmentCodes:[],painCodes:[]}, constraints:{state:"EXPLICIT_NONE",items:[]}
  });
  const context=()=>({organisationId:"o",campaignId:"c",companyId:"x",referenceTime:"2026-08-13T12:00:00.000Z",seller:{selectionId:"s",semanticContextFingerprint:"a".repeat(64),semanticCompleteness:"COMPLETE",objectiveKey:"customers",semantic:semantic()},targetTruth:{entitySnapshotId:"e",entitySnapshotFingerprint:"b".repeat(64),entityState:"KNOWN",nextRevalidationAt:"2026-09-01T00:00:00.000Z",coreClaims:{"identity.canonical_name":[snap("identity.canonical_name","KNOWN","Acme","1")],"identity.canonical_domain":[snap("identity.canonical_domain","KNOWN","acme.com","2")],"operation.current":[snap("operation.current","KNOWN","true","3")]},constraintClaims:{}}});

  test("fully satisfied boundaries yield candidate",()=>assert.equal(r4.evaluateCommercialReality(context()).decision,"COMMERCIAL_CANDIDATE"));
  test("SUPPORTED target facts are categorically admissible",()=>{const c=context(); c.targetTruth.coreClaims["identity.canonical_name"][0].truthState="SUPPORTED"; assert.equal(r4.evaluateCommercialReality(c).decision,"COMMERCIAL_CANDIDATE");});
  test("KNOWN false operation is not admissible",()=>{const c=context(); c.targetTruth.coreClaims["operation.current"][0].canonicalValueText="false"; assert.equal(r4.evaluateCommercialReality(c).decision,"NOT_ADMISSIBLE");});
  test("unresolved operation requires research",()=>{const c=context(); c.targetTruth.coreClaims["operation.current"]=[]; assert.equal(r4.evaluateCommercialReality(c).decision,"RESEARCH_REQUIRED");});
  test("stale identity requires research",()=>{const c=context(); c.targetTruth.coreClaims["identity.canonical_name"][0].truthState="STALE"; assert.equal(r4.evaluateCommercialReality(c).decision,"RESEARCH_REQUIRED");});
  test("contradicted domain requires research",()=>{const c=context(); c.targetTruth.coreClaims["identity.canonical_domain"][0].truthState="CONTRADICTED"; assert.equal(r4.evaluateCommercialReality(c).decision,"RESEARCH_REQUIRED");});
  test("two positive competing domain propositions contradict",()=>{const c=context(); c.targetTruth.coreClaims["identity.canonical_domain"].push(snap("identity.canonical_domain","KNOWN","other.com","4")); assert.equal(r4.evaluateCommercialReality(c).decision,"RESEARCH_REQUIRED");});
  test("unknown seller constraints require research",()=>{const c=context(); c.seller.semantic.constraints={state:"UNKNOWN",items:[]}; assert.equal(r4.evaluateCommercialReality(c).decision,"RESEARCH_REQUIRED");});
  test("missing seller offering requires research",()=>{const c=context(); c.seller.semantic.offerings={state:"UNKNOWN",items:[]}; assert.equal(r4.evaluateCommercialReality(c).decision,"RESEARCH_REQUIRED");});
  test("missing selected objective requires research",()=>{const c=context(); c.seller.objectiveKey="missing"; assert.equal(r4.evaluateCommercialReality(c).decision,"RESEARCH_REQUIRED");});
  test("supported geography hard constraint can pass",()=>{const c=context(); c.seller.semantic.constraints={state:"DECLARED",items:[{constraintKey:"gb_only",constraintType:"geography",mode:"HARD",valueCodes:["gb"]}]}; c.targetTruth.constraintClaims["profile.country_code"]=[snap("profile.country_code","SUPPORTED","GB","5")]; assert.equal(r4.evaluateCommercialReality(c).decision,"COMMERCIAL_CANDIDATE");});
  test("known geography violation is not admissible",()=>{const c=context(); c.seller.semantic.constraints={state:"DECLARED",items:[{constraintKey:"gb_only",constraintType:"geography",mode:"HARD",valueCodes:["gb"]}]}; c.targetTruth.constraintClaims["profile.country_code"]=[snap("profile.country_code","KNOWN","US","5")]; assert.equal(r4.evaluateCommercialReality(c).decision,"NOT_ADMISSIBLE");});
  test("missing hard-constraint target fact requires research",()=>{const c=context(); c.seller.semantic.constraints={state:"DECLARED",items:[{constraintKey:"gb_only",constraintType:"geography",mode:"HARD",valueCodes:["gb"]}]}; assert.equal(r4.evaluateCommercialReality(c).decision,"RESEARCH_REQUIRED");});
  test("unsupported hard constraint fails closed",()=>{const c=context(); c.seller.semantic.constraints={state:"DECLARED",items:[{constraintKey:"certified",constraintType:"certification",mode:"HARD",valueCodes:["iso27001"]}]}; assert.equal(r4.evaluateCommercialReality(c).decision,"RESEARCH_REQUIRED");});
  test("preference constraint cannot block candidate",()=>{const c=context(); c.seller.semantic.constraints={state:"DECLARED",items:[{constraintKey:"prefer_gb",constraintType:"geography",mode:"PREFERENCE",valueCodes:["gb"]}]}; assert.equal(r4.evaluateCommercialReality(c).decision,"COMMERCIAL_CANDIDATE");});
  test("known hard violation outranks another unresolved boundary",()=>{const c=context(); c.seller.semantic.constraints={state:"DECLARED",items:[{constraintKey:"gb_only",constraintType:"geography",mode:"HARD",valueCodes:["gb"]},{constraintKey:"unknown",constraintType:"certification",mode:"HARD",valueCodes:["x"]}]}; c.targetTruth.constraintClaims["profile.country_code"]=[snap("profile.country_code","KNOWN","US","5")]; assert.equal(r4.evaluateCommercialReality(c).decision,"NOT_ADMISSIBLE");});
  test("same proposition duplicated across scopes is not contradiction",()=>{const c=context(); const a=snap("identity.canonical_domain","KNOWN","acme.com","6"); a.propositionFingerprint=c.targetTruth.coreClaims["identity.canonical_domain"][0].propositionFingerprint; c.targetTruth.coreClaims["identity.canonical_domain"].push(a); assert.equal(r4.evaluateCommercialReality(c).decision,"COMMERCIAL_CANDIDATE");});
  test("authority validity never exceeds 24 hours",()=>{const e=r4.evaluateCommercialReality(context()); assert.equal(e.nextRevalidationAt,"2026-08-14T12:00:00.000Z");});
  test("earlier Truth expiry shortens authority",()=>{const c=context(); c.targetTruth.coreClaims["operation.current"][0].nextRevalidationAt="2026-08-13T18:00:00.000Z"; assert.equal(r4.evaluateCommercialReality(c).nextRevalidationAt,"2026-08-13T18:00:00.000Z");});
  test("no continuous metric appears in boundary output",()=>{const out=JSON.stringify(r4.evaluateCommercialReality(context())); for(const t of ["supportStrength","evidenceSufficiency","truthIndex","probability","confidence","score"]) assert.equal(out.includes(t),false,t);});
  test("hard constraint requirements sort deterministically",()=>{const s=semantic(); s.constraints={state:"DECLARED",items:[{constraintKey:"z",constraintType:"industry",mode:"HARD",valueCodes:["b","a"]},{constraintKey:"a",constraintType:"geography",mode:"HARD",valueCodes:["gb"]}]}; const req=r4.deriveHardConstraintRequirements(s); assert.deepEqual(req.map(x=>x.constraintKey),["a","z"]); assert.deepEqual(req[1].allowedValues,["a","b"]);});

  let passed=0; console.log("\nMarketRoute V2 Build 6 — Commercial Reality adversarial gate");
  for(const {name,fn} of tests){try{await fn();passed++;console.log(`PASS  ${name}`)}catch(e){console.error(`FAIL  ${name}: ${e instanceof Error?e.message:e}`)}}
  console.log(`\n${passed}/${tests.length} PASS`); if(passed!==tests.length) process.exitCode=1;
} finally { fs.rmSync(temp,{recursive:true,force:true}); }
