import { NextResponse } from "next/server";
import { cookies } from "next/headers";
import { sessionServiceFromEnvironment } from "@/application/session/service";
import { anonymousDiscoveryServiceFromEnvironment,ANONYMOUS_DISCOVERY_COOKIE } from "@/application/discovery/service";
import { sameOriginOrThrow,safeReturnPath } from "@/app/app/_lib/security";
import { ACCESS_COOKIE,REFRESH_COOKIE,ORG_COOKIE } from "@/app/app/_lib/session";

export async function POST(request:Request){
  let claim=false;let next="/app";
  try{
    sameOriginOrThrow(request);const form=await request.formData();const email=String(form.get("email")??"").trim();const password=String(form.get("password")??"");const confirmation=String(form.get("passwordConfirmation")??"");claim=String(form.get("claim")??"")==="discovery";next=safeReturnPath(form.get("next"),"/app");
    if(!claim)return NextResponse.redirect(new URL("/discover",request.url),303);
    if(password!==confirmation)throw new Error("MARKETROUTE_PASSWORDS_DO_NOT_MATCH");
    const result=await sessionServiceFromEnvironment().signUp(email,password);const jar=await cookies();const discoverySecret=jar.get(ANONYMOUS_DISCOVERY_COOKIE)?.value??null;
    if(!result.session){const notice=encodeURIComponent("Account created. Confirm your email, then sign in to save the MarketRoute already built for you.");return NextResponse.redirect(new URL(`/login?notice=${notice}&claim=discovery&next=${encodeURIComponent(next)}`,request.url),303);}
    let organisationId:string|null=null;if(discoverySecret){organisationId=(await anonymousDiscoveryServiceFromEnvironment().claim(result.session.accessToken,discoverySecret)).organisationId;}
    if(!organisationId)throw new Error("MARKETROUTE_ANONYMOUS_RUN_NOT_FOUND");
    const response=NextResponse.redirect(new URL(next,request.url),303);const secure=new URL(request.url).protocol==="https:";
    response.cookies.set(ACCESS_COOKIE,result.session.accessToken,{httpOnly:true,sameSite:"lax",secure,path:"/",maxAge:result.session.expiresIn});response.cookies.set(REFRESH_COOKIE,result.session.refreshToken,{httpOnly:true,sameSite:"lax",secure,path:"/",maxAge:60*60*24*30});response.cookies.set(ORG_COOKIE,organisationId,{httpOnly:true,sameSite:"lax",secure,path:"/",maxAge:60*60*24*365});return response;
  }catch(error){const message=encodeURIComponent(error instanceof Error?error.message:"MARKETROUTE_SIGNUP_FAILED");return NextResponse.redirect(new URL(`/signup?claim=discovery&next=${encodeURIComponent(next)}&error=${message}`,request.url),303);}
}
