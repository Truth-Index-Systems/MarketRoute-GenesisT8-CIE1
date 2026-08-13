import { NextResponse } from "next/server";
import { sessionServiceFromEnvironment } from "@/application/session/service";
import { sameOriginOrThrow } from "@/app/app/_lib/security";
import { ACCESS_COOKIE,REFRESH_COOKIE,ORG_COOKIE } from "@/app/app/_lib/session";

export async function POST(request:Request){
  try{sameOriginOrThrow(request);const form=await request.formData();const email=String(form.get("email")??"");const password=String(form.get("password")??"");const next=String(form.get("next")??"/app");const result=await sessionServiceFromEnvironment().signIn(email,password);const target=result.session.memberships.length===0?"/onboarding":next.startsWith("/app")&&!next.startsWith("//")?next:"/app";const response=NextResponse.redirect(new URL(target,request.url),303);const secure=new URL(request.url).protocol==="https:";response.cookies.set(ACCESS_COOKIE,result.auth.accessToken,{httpOnly:true,sameSite:"lax",secure,path:"/",maxAge:result.auth.expiresIn});response.cookies.set(REFRESH_COOKIE,result.auth.refreshToken,{httpOnly:true,sameSite:"lax",secure,path:"/",maxAge:60*60*24*30});if(result.session.memberships[0])response.cookies.set(ORG_COOKIE,result.session.memberships[0].organisationId,{httpOnly:true,sameSite:"lax",secure,path:"/",maxAge:60*60*24*365});return response;}
  catch(error){const message=encodeURIComponent(error instanceof Error?error.message:"MARKETROUTE_LOGIN_FAILED");return NextResponse.redirect(new URL(`/login?error=${message}`,request.url),303);}
}
