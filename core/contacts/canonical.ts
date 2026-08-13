import { canonicaliseClaim, normaliseText, type CanonicalClaim } from "../evidence/index.js";
import type { RawContactClaimInput } from "./contracts.js";

function clean(value:string, code:string):string {
  const v=normaliseText(value);
  if(!v) throw new Error(code);
  return v;
}

export function canonicaliseContactClaim(input:RawContactClaimInput):CanonicalClaim {
  const tenant=input.tenantScopeOrganisationId??null;
  switch(input.kind){
    case "IDENTITY": {
      const name=clean(input.canonicalName,"MARKETROUTE_R6_IDENTITY_NAME_REQUIRED");
      return canonicaliseClaim({tenantScopeOrganisationId:tenant,subjectType:"PERSON",subjectId:input.personId,claimKey:"identity.canonical_name",predicate:"equals",object:{name},canonicalValueText:name.toLowerCase()});
    }
    case "CURRENT_EMPLOYMENT":
      return canonicaliseClaim({tenantScopeOrganisationId:tenant,subjectType:"PERSON",subjectId:input.personId,claimKey:"employment.current",predicate:"equals",object:{companyId:input.companyId},canonicalValueText:input.companyId.toLowerCase()});
    case "CURRENT_ROLE": {
      const roleTitle=clean(input.roleTitle,"MARKETROUTE_R6_ROLE_TITLE_REQUIRED");
      return canonicaliseClaim({tenantScopeOrganisationId:tenant,subjectType:"PERSON",subjectId:input.personId,claimKey:"role.current",predicate:"equals",object:{companyId:input.companyId,roleTitle},canonicalValueText:roleTitle.toLowerCase()});
    }
    case "CHANNEL_OWNERSHIP":
      return canonicaliseClaim({tenantScopeOrganisationId:tenant,subjectType:"CHANNEL",subjectId:input.accessPointId,claimKey:"ownership.current",predicate:"equals",object:{personId:input.personId},canonicalValueText:input.personId.toLowerCase()});
  }
}
