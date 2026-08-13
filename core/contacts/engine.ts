import { sha256Hex, stableJson } from "../evidence/index";
import {
  CONTACT_AUTHORITY_ENGINE_VERSION, CONTACT_AUTHORITY_MAX_HOURS, CONTACT_AUTHORITY_SEMANTICS_VERSION,
  CONTACT_AUTHORITY_WRITER_KEY, CONTACT_AUTHORITY_WRITER_VERSION,
  type ContactAuthorityContext, type ContactAuthorityEvaluation, type ContactClaimTruthRef, type ContactPathBinding,
} from "./contracts";

const HOUR=3_600_000;
const POSITIVE=new Set(["KNOWN","SUPPORTED"]);

function isPositive(c:ContactClaimTruthRef,reference:number):boolean {
  const next=c.nextRevalidationAt?Date.parse(c.nextRevalidationAt):NaN;
  return POSITIVE.has(c.truthState)&&Number.isFinite(next)&&next>reference;
}
function normal(value:unknown):string {return typeof value==="string"?value.normalize("NFKC").trim().toLowerCase():"";}
function exactRequirementQualified(claims:ContactClaimTruthRef[],reference:number,match:(c:ContactClaimTruthRef)=>boolean):boolean {
  const matching=claims.filter(match);
  const competing=claims.filter(c=>!match(c)&&isPositive(c,reference));
  if(competing.length||matching.some(c=>c.truthState==="CONTRADICTED")) return false;
  return matching.some(c=>isPositive(c,reference));
}
function roleQualified(claims:ContactClaimTruthRef[],reference:number,employerCompanyId:string):boolean {
  const groups=new Map<string,ContactClaimTruthRef[]>();
  for(const claim of claims){if(normal(claim.objectJson?.companyId)!==normal(employerCompanyId)) continue; const key=(claim.roleTitle??"").normalize("NFKC").trim().toLowerCase();if(!key)continue;const arr=groups.get(key)??[];arr.push(claim);groups.set(key,arr);}
  for(const group of groups.values()) if(!group.some(c=>c.truthState==="CONTRADICTED")&&group.some(c=>isPositive(c,reference))) return true;
  return false;
}

export function evaluateContactAuthority(context:ContactAuthorityContext):ContactAuthorityEvaluation {
  const reference=Date.parse(context.referenceTime); if(!Number.isFinite(reference)) throw new Error("MARKETROUTE_R6_REFERENCE_TIME_INVALID");
  const parentUntil=Date.parse(context.parentR5.validUntil); if(!Number.isFinite(parentUntil)) throw new Error("MARKETROUTE_R6_PARENT_VALID_UNTIL_INVALID");
  const applicable=context.parentR5.current&&context.parentR5.decisionCode==="ROUTE_STRUCTURALLY_OPEN";
  const bindings:ContactPathBinding[]=[];
  if(applicable){
    for(const path of [...context.paths].sort((a,b)=>a.pathFingerprint.localeCompare(b.pathFingerprint))){
      if(path.r5PathState==="ORGANISATIONAL_OPEN"){
        bindings.push({pathFingerprint:path.pathFingerprint,terminalAccessPointId:path.terminalAccessPointId,mode:"ORGANISATIONAL_ROUTE",authorityState:"AUTHORISED",personId:null,employerCompanyId:null,reasonCode:"ORGANISATIONAL_ACCESS_REQUIRES_NO_PERSON_TRUTH"});
        continue;
      }
      let reason="CONTACT_TRUTH_INCOMPLETE";
      let ok=true;
      if(!path.personId||!path.employerCompanyId){ok=false;reason="PERSON_OR_EMPLOYER_NOT_STRUCTURALLY_IDENTIFIED";}
      else if(path.personLifecycleState!=="ACTIVE"){ok=false;reason="PERSON_CANONICAL_RECORD_NOT_ACTIVE";}
      else if(!exactRequirementQualified(path.identityClaims,reference,c=>normal(c.objectJson?.name)===normal(path.expectedPersonName))){ok=false;reason="IDENTITY_NOT_TRUTH_QUALIFIED";}
      else if(!exactRequirementQualified(path.employmentClaims,reference,c=>normal(c.objectJson?.companyId)===normal(path.employerCompanyId))){ok=false;reason="CURRENT_EMPLOYMENT_NOT_TRUTH_QUALIFIED";}
      else if(!roleQualified(path.roleClaims,reference,path.employerCompanyId)){ok=false;reason="CURRENT_ROLE_NOT_TRUTH_QUALIFIED";}
      else if(!exactRequirementQualified(path.channelOwnershipClaims,reference,c=>normal(c.objectJson?.personId)===normal(path.personId))){ok=false;reason="CHANNEL_OWNERSHIP_NOT_TRUTH_QUALIFIED";}
      else reason="CONTACT_TRUTH_QUALIFIED";
      bindings.push({pathFingerprint:path.pathFingerprint,terminalAccessPointId:path.terminalAccessPointId,mode:"NAMED_CONTACT",authorityState:ok?"AUTHORISED":"CONTACT_TRUTH_REQUIRED",personId:path.personId,employerCompanyId:path.employerCompanyId,reasonCode:reason});
    }
  }
  const authorised=bindings.filter(b=>b.authorityState==="AUTHORISED");
  const authorisedPathFingerprints=authorised.map(b=>b.pathFingerprint).sort();
  const authorisedAccessPointIds=[...new Set(authorised.map(b=>b.terminalAccessPointId))].sort();
  const researchRequiredAccessPointIds=[...new Set(bindings.filter(b=>b.authorityState!=="AUTHORISED").map(b=>b.terminalAccessPointId))].sort();
  const decision=!applicable?"CONTACT_NOT_APPLICABLE":authorised.length?"CONTACT_AUTHORISED":"CONTACT_RESEARCH_REQUIRED";
  const expiries=context.paths.flatMap(p=>[...p.identityClaims,...p.employmentClaims,...p.roleClaims,...p.channelOwnershipClaims]).map(c=>c.nextRevalidationAt).filter((x):x is string=>Boolean(x)).map(Date.parse).filter(x=>Number.isFinite(x)&&x>reference);
  const cap=reference+CONTACT_AUTHORITY_MAX_HOURS*HOUR;
  const nextRevalidationAt=new Date(Math.min(cap,parentUntil,...(expiries.length?expiries:[cap]))).toISOString();
  const diagnosticInputFingerprint=sha256Hex(`MRV2-R6-DIAGNOSTIC-INPUT-1.0.0|${stableJson({parent:context.parentR5.authorityFingerprint,universe:context.contactClaimUniverseFingerprint,paths:context.paths.map(p=>({path:p.pathFingerprint,person:p.personId,employer:p.employerCompanyId,claims:[...p.identityClaims,...p.employmentClaims,...p.roleClaims,...p.channelOwnershipClaims].map(c=>[c.claimId,c.snapshotFingerprint])})),referenceTime:context.referenceTime})}`);
  return {engineVersion:CONTACT_AUTHORITY_ENGINE_VERSION,semanticsVersion:CONTACT_AUTHORITY_SEMANTICS_VERSION,writerKey:CONTACT_AUTHORITY_WRITER_KEY,writerVersion:CONTACT_AUTHORITY_WRITER_VERSION,organisationId:context.organisationId,campaignId:context.campaignId,companyId:context.companyId,referenceTime:context.referenceTime,parentAuthorityFingerprint:context.parentR5.authorityFingerprint,contactClaimUniverseFingerprint:context.contactClaimUniverseFingerprint,decision,bindings,authorisedPathFingerprints,authorisedAccessPointIds,researchRequiredAccessPointIds,distinctAuthorisedAccessPointCount:authorisedAccessPointIds.length,nextRevalidationAt,diagnosticInputFingerprint};
}
