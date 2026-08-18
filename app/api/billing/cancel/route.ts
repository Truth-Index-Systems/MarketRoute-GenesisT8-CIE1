import { cookies } from "next/headers";
import { NextResponse } from "next/server";
import { billingServiceFromEnvironment } from "@/application/billing/service";
import { sessionServiceFromEnvironment } from "@/application/session/service";
import { ACCESS_COOKIE,ORG_COOKIE } from "@/app/app/_lib/session";

export async function GET(request:Request){
  try{const attempt=new URL(request.url).searchParams.get("attempt")??"";const jar=await cookies();const access=jar.get(ACCESS_COOKIE)?.value;if(!access)throw new Error("MARKETROUTE_AUTH_REQUIRED");const sessions=sessionServiceFromEnvironment();const session=await sessions.authenticate(access);const workspace=sessions.selectWorkspace(session,jar.get(ORG_COOKIE)?.value);if(workspace.role!=="OWNER")throw new Error("MARKETROUTE_BILLING_OWNER_REQUIRED");await billingServiceFromEnvironment().cancelCheckout({organisationId:workspace.organisationId,userId:session.user.id,attemptId:attempt});return NextResponse.redirect(new URL("/app/plans?billing=cancelled",request.url),303);}catch(error){const code=encodeURIComponent(error instanceof Error?error.message:"MARKETROUTE_BILLING_CANCEL_FAILED");return NextResponse.redirect(new URL(`/app/plans?billingError=${code}`,request.url),303);}
}
