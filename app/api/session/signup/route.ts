import { NextResponse } from "next/server";
import { sessionServiceFromEnvironment } from "@/application/session/service";
import { sameOriginOrThrow } from "@/app/app/_lib/security";
import { ACCESS_COOKIE,REFRESH_COOKIE } from "@/app/app/_lib/session";

export async function POST(request:Request){
  try{
    sameOriginOrThrow(request);
    const form=await request.formData();
    const email=String(form.get("email")??"").trim();
    const password=String(form.get("password")??"");
    const confirmation=String(form.get("passwordConfirmation")??"");
    if(password!==confirmation)throw new Error("MARKETROUTE_PASSWORDS_DO_NOT_MATCH");
    const result=await sessionServiceFromEnvironment().signUp(email,password);
    if(!result.session){
      return NextResponse.redirect(new URL(`/login?notice=${encodeURIComponent("Account created. Check your email to confirm your address, then sign in.")}`,request.url),303);
    }
    const response=NextResponse.redirect(new URL("/onboarding",request.url),303);
    const secure=new URL(request.url).protocol==="https:";
    response.cookies.set(ACCESS_COOKIE,result.session.accessToken,{httpOnly:true,sameSite:"lax",secure,path:"/",maxAge:result.session.expiresIn});
    response.cookies.set(REFRESH_COOKIE,result.session.refreshToken,{httpOnly:true,sameSite:"lax",secure,path:"/",maxAge:60*60*24*30});
    return response;
  }catch(error){
    const message=encodeURIComponent(error instanceof Error?error.message:"MARKETROUTE_SIGNUP_FAILED");
    return NextResponse.redirect(new URL(`/signup?error=${message}`,request.url),303);
  }
}
