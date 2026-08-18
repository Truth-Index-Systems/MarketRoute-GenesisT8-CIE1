import { cookies } from "next/headers";
import { NextResponse } from "next/server";
import { sessionServiceFromEnvironment } from "@/application/session/service";
import { ACCESS_COOKIE, ORG_COOKIE } from "@/app/app/_lib/session";
import { sameOriginOrThrow } from "@/app/app/_lib/security";

export async function POST(request:Request){
  try{
    sameOriginOrThrow(request);
    const form=await request.formData();
    const constraintMode=String(form.get("constraintMode")??"");
    if(!["DESCRIBED","NONE"].includes(constraintMode))throw new Error("MARKETROUTE_SETUP_CONSTRAINT_CHOICE_REQUIRED");

    const jar=await cookies();
    const accessToken=jar.get(ACCESS_COOKIE)?.value;
    if(!accessToken)throw new Error("MARKETROUTE_AUTH_REQUIRED");
    const sessions=sessionServiceFromEnvironment();
    const session=await sessions.authenticate(accessToken);
    const workspace=sessions.selectWorkspace(session,jar.get(ORG_COOKIE)?.value);
    if(!["OWNER","ADMIN"].includes(workspace.role))throw new Error("MARKETROUTE_CAMPAIGN_ADMIN_REQUIRED");

    await sessions.submitCampaign(accessToken,{
      organisationId:workspace.organisationId,
      campaignName:String(form.get("campaignName")??""),
      sellerOfferingText:String(form.get("sellerOfferingText")??""),
      objectiveText:String(form.get("objectiveText")??""),
      targetMarketText:String(form.get("targetMarketText")??""),
      hardConstraintsText:String(form.get("hardConstraintsText")??""),
      noHardConstraints:constraintMode==="NONE"
    });

    return NextResponse.redirect(new URL("/app/campaigns?campaignAction=processing",request.url),303);
  }catch(error){
    const code=error instanceof Error?error.message:"MARKETROUTE_CAMPAIGN_CREATION_FAILED";
    return NextResponse.redirect(new URL(`/app/campaigns/new?error=${encodeURIComponent(code)}`,request.url),303);
  }
}
