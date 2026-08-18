import {
  OPPORTUNITY_ENGINE_VERSION,
  OPPORTUNITY_SEMANTICS_VERSION,
  type OpportunityDisposition,
  type OpportunityProfile,
  type OpportunityProfileInput,
  type OpportunityResearchPressure,
  type ParetoRelation,
} from "./contracts";

function finite01(value:number|null, code:string):number|null {
  if(value===null) return null;
  if(!Number.isFinite(value)||value<0||value>1) throw new Error(code);
  return value;
}
function finiteCount(value:number,code:string):number {
  if(!Number.isInteger(value)||value<0) throw new Error(code);
  return value;
}

export function opportunityDisposition(lifecycle:string):OpportunityDisposition {
  if(lifecycle==="AUTHORITY_READY") return "ACTIONABLE";
  if(lifecycle==="NOT_ADMISSIBLE") return "NOT_ADMISSIBLE";
  if(lifecycle==="ROUTE_NOT_APPLICABLE"||lifecycle==="CONTACT_NOT_APPLICABLE") return "NOT_APPLICABLE";
  if(lifecycle.endsWith("_REVALIDATION_REQUIRED")) return "REVALIDATION_REQUIRED";
  if(lifecycle==="COMMERCIAL_RESEARCH_REQUIRED"||lifecycle==="ROUTE_RESEARCH_REQUIRED"||lifecycle==="CONTACT_RESEARCH_REQUIRED") return "RESEARCH_REQUIRED";
  throw new Error("MARKETROUTE_OPPORTUNITY_LIFECYCLE_STATE_UNKNOWN");
}
export function researchPressure(lifecycle:string):OpportunityResearchPressure {
  if(lifecycle.startsWith("R4_")||lifecycle==="COMMERCIAL_RESEARCH_REQUIRED") return "R4";
  if(lifecycle.startsWith("R5_")||lifecycle==="ROUTE_RESEARCH_REQUIRED") return "R5";
  if(lifecycle.startsWith("R6_")||lifecycle==="CONTACT_RESEARCH_REQUIRED") return "R6";
  return "NONE";
}

export function buildOpportunityProfile(input:OpportunityProfileInput):OpportunityProfile {
  const at=Date.parse(input.evaluatedAt); if(!Number.isFinite(at)) throw new Error("MARKETROUTE_OPPORTUNITY_EVALUATED_AT_INVALID");
  const structurallyOpenAccessPointCount=finiteCount(input.structurallyOpenAccessPointCount,"MARKETROUTE_OPPORTUNITY_R5_COUNT_INVALID");
  const authorisedAccessPointCount=finiteCount(input.authorisedAccessPointCount,"MARKETROUTE_OPPORTUNITY_R6_COUNT_INVALID");
  if(authorisedAccessPointCount>structurallyOpenAccessPointCount) throw new Error("MARKETROUTE_OPPORTUNITY_AUTHORISED_COUNT_EXCEEDS_STRUCTURE");
  const truth={...input.truth,
    currentCoverage:finite01(input.truth.currentCoverage,"MARKETROUTE_OPPORTUNITY_CURRENT_COVERAGE_INVALID"),
    evidenceSufficiency:finite01(input.truth.evidenceSufficiency,"MARKETROUTE_OPPORTUNITY_EVIDENCE_SUFFICIENCY_INVALID"),
    freshnessCoverage:finite01(input.truth.freshnessCoverage,"MARKETROUTE_OPPORTUNITY_FRESHNESS_INVALID"),
    coherence:finite01(input.truth.coherence,"MARKETROUTE_OPPORTUNITY_COHERENCE_INVALID"),
  };
  if(truth.truthIndex!==null&&(!Number.isFinite(truth.truthIndex)||truth.truthIndex<0||truth.truthIndex>100)) throw new Error("MARKETROUTE_OPPORTUNITY_TRUTH_INDEX_INVALID");
  if(truth.probabilityState!==null&&truth.probabilityState!=="UNCALIBRATED") throw new Error("MARKETROUTE_OPPORTUNITY_PROBABILITY_STATE_INVALID");
  const disposition=opportunityDisposition(input.lifecycleState);
  if(input.authorityReady!==(disposition==="ACTIONABLE")) throw new Error("MARKETROUTE_OPPORTUNITY_AUTHORITY_DISPOSITION_MISMATCH");
  if(disposition==="ACTIONABLE"){
    if(input.r4Decision!=="COMMERCIAL_CANDIDATE"||input.r5Decision!=="ROUTE_STRUCTURALLY_OPEN"||input.r6Decision!=="CONTACT_AUTHORISED") throw new Error("MARKETROUTE_OPPORTUNITY_ACTIONABLE_AUTHORITY_CHAIN_INVALID");
    if(truth.currentCoverage===null||truth.evidenceSufficiency===null||truth.freshnessCoverage===null||truth.coherence===null||truth.truthIndex===null) throw new Error("MARKETROUTE_OPPORTUNITY_ACTIONABLE_TRUTH_REQUIRED");
    if(structurallyOpenAccessPointCount<1||authorisedAccessPointCount<1) throw new Error("MARKETROUTE_OPPORTUNITY_ACTIONABLE_ROUTE_REQUIRED");
  }
  const workflow=input.workflowState??null;
  const reviewableNow=workflow==="REVIEWABLE"&&input.authorityReady;
  const executableNow=(workflow==="REVIEWABLE"||workflow==="APPROVED")&&input.authorityReady;
  return {
    engineVersion:OPPORTUNITY_ENGINE_VERSION,semanticsVersion:OPPORTUNITY_SEMANTICS_VERSION,
    organisationId:input.organisationId,campaignId:input.campaignId,companyId:input.companyId,
    opportunityId:input.opportunityId??null,companyName:input.companyName.normalize("NFKC").trim(),canonicalDomain:input.canonicalDomain?.normalize("NFKC").trim().toLowerCase()||null,
    evaluatedAt:new Date(at).toISOString(),workflowState:workflow,lifecycleState:input.lifecycleState,disposition,researchPressure:researchPressure(input.lifecycleState),authorityReady:input.authorityReady,
    reviewableNow,executableNow,reasonCode:input.reasonCode,nextRevalidationAt:input.nextRevalidationAt??null,
    commercialReality:input.r4Decision??null,routeAuthority:input.r5Decision??null,contactAuthority:input.r6Decision??null,
    truth,structurallyOpenAccessPointCount,authorisedAccessPointCount,
    routeRedundancy:authorisedAccessPointCount===0?"NONE":authorisedAccessPointCount===1?"SINGLE":"MULTIPLE"
  };
}

function dimensions(p:OpportunityProfile):number[]|null {
  if(p.disposition!=="ACTIONABLE") return null;
  const t=p.truth;
  if(t.currentCoverage===null||t.evidenceSufficiency===null||t.freshnessCoverage===null||t.coherence===null) return null;
  return [t.currentCoverage,t.evidenceSufficiency,t.freshnessCoverage,t.coherence,p.authorisedAccessPointCount];
}
export function compareOpportunityPareto(a:OpportunityProfile,b:OpportunityProfile):ParetoRelation {
  const da=dimensions(a),db=dimensions(b);if(!da||!db)return "NOT_COMPARABLE";
  let aBetter=false,bBetter=false;
  for(let i=0;i<da.length;i++){if(da[i]!>db[i]!)aBetter=true;else if(db[i]!>da[i]!)bBetter=true;}
  if(!aBetter&&!bBetter)return "EQUIVALENT";
  if(aBetter&&!bBetter)return "A_DOMINATES";
  if(bBetter&&!aBetter)return "B_DOMINATES";
  return "INCOMPARABLE";
}

export function opportunityParetoFrontier(values:OpportunityProfile[]):OpportunityProfile[] {
  const actionable=values.filter(v=>v.disposition==="ACTIONABLE");
  return actionable.filter((candidate,i)=>!actionable.some((other,j)=>i!==j&&compareOpportunityPareto(other,candidate)==="A_DOMINATES"))
    .sort((a,b)=>a.companyName<b.companyName?-1:a.companyName>b.companyName?1:(a.companyId<b.companyId?-1:a.companyId>b.companyId?1:0));
}
