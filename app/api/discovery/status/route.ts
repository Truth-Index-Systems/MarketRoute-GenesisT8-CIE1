import { NextResponse } from "next/server";
import { cookies } from "next/headers";
import { anonymousDiscoveryServiceFromEnvironment,ANONYMOUS_DISCOVERY_COOKIE } from "@/application/discovery/service";
export const runtime="nodejs";export const dynamic="force-dynamic";
export async function GET(){try{const secret=(await cookies()).get(ANONYMOUS_DISCOVERY_COOKIE)?.value;if(!secret)return NextResponse.json({ok:false,error:"MARKETROUTE_ANONYMOUS_RUN_NOT_FOUND"},{status:404});const discovery=await anonymousDiscoveryServiceFromEnvironment().status(secret);if(!discovery)return NextResponse.json({ok:false,error:"MARKETROUTE_ANONYMOUS_RUN_NOT_FOUND"},{status:404});return NextResponse.json({ok:true,discovery},{headers:{"Cache-Control":"no-store"}});}catch{return NextResponse.json({ok:false,error:"MARKETROUTE_ANONYMOUS_STATUS_FAILED"},{status:500});}}
