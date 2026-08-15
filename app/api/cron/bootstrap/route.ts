import { NextResponse } from "next/server";
import { assertCronRequest,runBootstrapCron } from "@/application/production/runtime";
import { observeProductionRuntime } from "@/application/production/observability";
export const runtime="nodejs";export const maxDuration=300;export const dynamic="force-dynamic";
export async function GET(request:Request){try{assertCronRequest(request);const result=await observeProductionRuntime("BOOTSTRAP",()=>runBootstrapCron());const status=result.status==="FAILED"?500:result.status==="PARTIAL"?207:200;return NextResponse.json({ok:status<400,...result},{status});}catch(error){const message=error instanceof Error?error.message:"MARKETROUTE_BOOTSTRAP_CRON_FAILED";return NextResponse.json({ok:false,error:message},{status:message==="MARKETROUTE_CRON_UNAUTHORISED"?401:500});}}
