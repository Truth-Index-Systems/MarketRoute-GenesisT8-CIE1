import { NextResponse } from "next/server";
import { cookies } from "next/headers";
import { engagementServiceFromEnvironment } from "@/application/engagement/service";
import { applicationReadServiceFromEnvironment } from "@/application/read-model/service";
import { sessionServiceFromEnvironment } from "@/application/session/service";
import { ACCESS_COOKIE,ORG_COOKIE } from "@/app/app/_lib/session";
import { sameOriginOrThrow,safeReturnPath } from "@/app/app/_lib/security";

export const runtime="nodejs";
export async function POST(request:Request,{params}:{params:Promise<{id:string}>}){
  const form=await request.formData();const returnTo=safeReturnPath(form.get("returnTo"));
  try{
    sameOriginOrThrow(request);
    const {id}=await params;
    const pathFingerprint=String(form.get("pathFingerprint")??"").trim();
    const messageId=String(form.get("messageId")??"").trim();
    const note=String(form.get("note")??"").trim()||null;
    if(!/^[a-f0-9]{64}$/.test(pathFingerprint))throw new Error("MARKETROUTE_MANUAL_ENGAGEMENT_PATH_INVALID");
    if(!messageId)throw new Error("MARKETROUTE_MANUAL_ENGAGEMENT_MESSAGE_REQUIRED");
    const jar=await cookies();const access=jar.get(ACCESS_COOKIE)?.value;if(!access)throw new Error("MARKETROUTE_AUTH_REQUIRED");
    const sessions=sessionServiceFromEnvironment();const session=await sessions.authenticate(access);const workspace=sessions.selectWorkspace(session,jar.get(ORG_COOKIE)?.value);
    await sessions.assertOpportunityWriteScope(session,id,workspace.organisationId);
    const read=await applicationReadServiceFromEnvironment().engagement({opportunityId:id});
    const message=read.message as Record<string,unknown>|null;const actions=read.actions as Record<string,unknown>;
    if(!message||String(message.messageId??"")!==messageId)throw new Error("MARKETROUTE_MANUAL_ENGAGEMENT_MESSAGE_NOT_CURRENT");
    if(!Boolean(actions.canMarkContacted))throw new Error("MARKETROUTE_MANUAL_ENGAGEMENT_NOT_ALLOWED");
    await engagementServiceFromEnvironment().recordManualContact({opportunityId:id,pathFingerprint,messageId,actorUserId:session.user.id,note});
    return NextResponse.redirect(new URL(returnTo,request.url),303);
  }catch(error){
    const code=encodeURIComponent(error instanceof Error?error.message:"MARKETROUTE_MANUAL_ENGAGEMENT_FAILED");
    return NextResponse.redirect(new URL(`${returnTo}${returnTo.includes("?")?"&":"?"}actionError=${code}`,request.url),303);
  }
}
