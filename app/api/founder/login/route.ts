import { NextResponse } from "next/server";
import { createFounderSessionToken,founderSessionCookie,founderSessionCookieOptions,verifyFounderPassword } from "@/application/founder/auth";

export const runtime="nodejs";export const dynamic="force-dynamic";
export async function POST(request:Request){
  const form=await request.formData();const password=String(form.get("password")??"");
  let ok=false;try{ok=verifyFounderPassword(password);}catch(error){console.error(error);}
  if(!ok)return NextResponse.redirect(new URL("/dashboard/login?error=1",request.url),303);
  const response=NextResponse.redirect(new URL("/dashboard",request.url),303);
  response.cookies.set(founderSessionCookie.name,createFounderSessionToken(),founderSessionCookieOptions(founderSessionCookie.maxAge));
  return response;
}
