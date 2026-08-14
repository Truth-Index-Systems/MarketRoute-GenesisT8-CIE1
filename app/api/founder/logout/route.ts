import { NextResponse } from "next/server";
import { founderSessionCookie,founderSessionCookieOptions } from "@/application/founder/auth";
export async function POST(request:Request){const response=NextResponse.redirect(new URL("/dashboard/login",request.url),303);response.cookies.set(founderSessionCookie.name,"",founderSessionCookieOptions(0));return response;}
