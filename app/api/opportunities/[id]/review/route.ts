import { NextResponse } from "next/server";
import { cookies } from "next/headers";
import { randomUUID } from "node:crypto";
import { sessionServiceFromEnvironment } from "@/application/session/service";
import { applicationReadServiceFromEnvironment } from "@/application/read-model/service";
import { OpportunityLifecycleService } from "@/application/opportunities/lifecycle-service";
import { ACCESS_COOKIE,ORG_COOKIE } from "@/app/app/_lib/session";
import { sameOriginOrThrow,safeReturnPath } from "@/app/app/_lib/security";

export async function POST(request:Request,{params}:{params:Promise<{id:string}>}){
  const form=await request.formData();const returnTo=safeReturnPath(form.get("returnTo"));
  try{sameOriginOrThrow(request);const {id}=await params;const campaignId=String(form.get("campaignId")??"");const companyId=String(form.get("companyId")??"");const decision=String(form.get("decision")??"") as "RETURN_TO_RESEARCH";if(decision!=="RETURN_TO_RESEARCH")throw new Error("MARKETROUTE_OPPORTUNITY_APPROVAL_RETIRED");const jar=await cookies();const access=jar.get(ACCESS_COOKIE)?.value;if(!access)throw new Error("MARKETROUTE_AUTH_REQUIRED");const service=sessionServiceFromEnvironment();const session=await service.authenticate(access);const workspace=service.selectWorkspace(session,jar.get(ORG_COOKIE)?.value);await service.assertOpportunityWriteScope(session,id,workspace.organisationId);const model=await applicationReadServiceFromEnvironment().company({organisationId:workspace.organisationId,campaignId,companyId});if(String((model.workflow as Record<string,unknown>).opportunityId??"")!==id)throw new Error("MARKETROUTE_REVIEW_MODEL_SCOPE_MISMATCH");if(!["REVIEWABLE","APPROVED","REJECTED"].includes(String((model.workflow as Record<string,unknown>).state??"")))throw new Error("MARKETROUTE_RETURN_TO_RESEARCH_NOT_ALLOWED");const lifecycle=OpportunityLifecycleService.fromEnvironment();await lifecycle.review({opportunityId:id,reviewerUserId:session.user.id,decision,note:String(form.get("note")??"").trim()||null,requestId:randomUUID()});return NextResponse.redirect(new URL(returnTo,request.url),303);}catch(error){const code=encodeURIComponent(error instanceof Error?error.message:"MARKETROUTE_REVIEW_FAILED");return NextResponse.redirect(new URL(`${returnTo}${returnTo.includes("?")?"&":"?"}actionError=${code}`,request.url),303);}
}
