import { NextResponse } from "next/server";
import { cookies } from "next/headers";
import { sessionServiceFromEnvironment } from "@/application/session/service";
import { ACCESS_COOKIE,ORG_COOKIE } from "@/app/app/_lib/session";
import { sameOriginOrThrow } from "@/app/app/_lib/security";
export async function POST(request:Request){try{sameOriginOrThrow(request);const form=await request.formData();const organisationId=String(form.get("organisationId")??"");const jar=await cookies();const access=jar.get(ACCESS_COOKIE)?.value;if(!access)throw new Error("MARKETROUTE_AUTH_REQUIRED");const session=await sessionServiceFromEnvironment().authenticate(access);const workspace=sessionServiceFromEnvironment().selectWorkspace(session,organisationId);if(workspace.organisationId!==organisationId)throw new Error("MARKETROUTE_WORKSPACE_ACCESS_DENIED");const response=NextResponse.redirect(new URL("/app",request.url),303);response.cookies.set(ORG_COOKIE,workspace.organisationId,{httpOnly:true,sameSite:"lax",secure:new URL(request.url).protocol==="https:",path:"/",maxAge:60*60*24*365});return response;}catch{return NextResponse.redirect(new URL("/app",request.url),303);}}
