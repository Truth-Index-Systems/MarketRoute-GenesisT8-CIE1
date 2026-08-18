import { NextResponse } from "next/server";
import { billingServiceFromEnvironment } from "@/application/billing/service";

export const runtime="nodejs";
export async function POST(request:Request){
  try{const signature=request.headers.get("stripe-signature");if(!signature)throw new Error("MARKETROUTE_STRIPE_WEBHOOK_SIGNATURE_REQUIRED");const raw=await request.text();await billingServiceFromEnvironment().webhook(raw,signature);return NextResponse.json({received:true},{status:200});}
  catch(error){return NextResponse.json({received:false,error:error instanceof Error?error.message:"MARKETROUTE_BILLING_WEBHOOK_FAILED"},{status:400});}
}
