import { NextResponse } from "next/server";
import { cookies } from "next/headers";
import { sessionServiceFromEnvironment } from "@/application/session/service";
import { anonymousDiscoveryServiceFromEnvironment,ANONYMOUS_DISCOVERY_COOKIE } from "@/application/discovery/service";
import { sameOriginOrThrow,safeReturnPath } from "@/app/app/_lib/security";
import { ACCESS_COOKIE,REFRESH_COOKIE,ORG_COOKIE } from "@/app/app/_lib/session";

export async function POST(request:Request){
  try{
    sameOriginOrThrow(request);const form=await request.formData();const email=String(form.get("email")??"").trim();const password=String(form.get("password")??"");const confirmation=String(form.get("passwordConfirmation")??"");const claim=String(form.get("claim")??"")==="discovery";const next=safeReturnPath(form.get("next"),"/app");
    if(password!==confirmation)throw new Error("MARKETROUTE_PASSWORDS_DO_NOT_MATCH");
    const result=await sessionServiceFromEnvironment().signUp(email,password);const jar=await cookies();const discoverySecret=claim?jar.get(ANONYMOUS_DISCOVERY_COOKIE)?.value:null;
    if(!result.session){const notice=encodeURIComponent(claim?"Account created. Confirm your email, then sign in to save the MarketRoute already built for you.":"Account created. Check your email to confirm your address, then sign in.");return NextResponse.redirect(new URL(`/login?notice=${notice}${claim?`&claim=discovery&next=${encodeURIComponent(next)}`:""}`,request.url),303);}
    let organisationId:string|null=null;if(claim&&discoverySecret){organisationId=(await anonymousDiscoveryServiceFromEnvironment().claim(result.session.accessToken,discoverySecret)).organisationId;}
    const target=organisationId?next:"/onboarding";const response=NextResponse.redirect(new URL(target,request.url),303);const secure=new URL(request.url).protocol==="https:";
    response.cookies.set(ACCESS_COOKIE,result.session.accessToken,{httpOnly:true,sameSite:"lax",secure,path:"/",maxAge:result.session.expiresIn});response.cookies.set(REFRESH_COOKIE,result.session.refreshToken,{httpOnly:true,sameSite:"lax",secure,path:"/",maxAge:60*60*24*30});if(organisationId)response.cookies.set(ORG_COOKIE,organisationId,{httpOnly:true,sameSite:"lax",secure,path:"/",maxAge:60*60*24*365});return response;
  }catch(error){const message=encodeURIComponent(error instanceof Error?error.message:"MARKETROUTE_SIGNUP_FAILED");return NextResponse.redirect(new URL(`/signup?error=${message}`,request.url),303);}
}
