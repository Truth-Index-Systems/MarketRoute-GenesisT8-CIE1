import { NextResponse } from "next/server";
import { cookies } from "next/headers";
import { sessionServiceFromEnvironment } from "@/application/session/service";
import { ACCESS_COOKIE,REFRESH_COOKIE,ORG_COOKIE } from "@/app/app/_lib/session";
import { sameOriginOrThrow } from "@/app/app/_lib/security";
export async function POST(request:Request){try{sameOriginOrThrow(request);const jar=await cookies();const token=jar.get(ACCESS_COOKIE)?.value;if(token)await sessionServiceFromEnvironment().signOut(token);}catch{}const response=NextResponse.redirect(new URL("/login",request.url),303);for(const name of [ACCESS_COOKIE,REFRESH_COOKIE,ORG_COOKIE])response.cookies.set(name,"",{httpOnly:true,path:"/",maxAge:0,sameSite:"lax"});return response;}
