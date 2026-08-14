import { NextResponse } from "next/server";
import { assertCronRequest,runDeliveryCron } from "@/application/production/runtime";
import { observeProductionRuntime } from "@/application/production/observability";
export const runtime="nodejs";export const maxDuration=300;export const dynamic="force-dynamic";
export async function GET(request:Request){try{assertCronRequest(request);const result=await observeProductionRuntime("DELIVERY",()=>runDeliveryCron());return NextResponse.json({ok:true,...result});}catch(error){const message=error instanceof Error?error.message:"MARKETROUTE_DELIVERY_CRON_FAILED";return NextResponse.json({ok:false,error:message},{status:message==="MARKETROUTE_CRON_UNAUTHORISED"?401:500});}}
