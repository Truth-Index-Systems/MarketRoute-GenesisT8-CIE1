import { cookies } from "next/headers";
import { NextResponse } from "next/server";
import { billingServiceFromEnvironment } from "@/application/billing/service";
import { sessionServiceFromEnvironment } from "@/application/session/service";
import { ACCESS_COOKIE,ORG_COOKIE } from "@/app/app/_lib/session";
import { sameOriginOrThrow } from "@/app/app/_lib/security";

export async function POST(request:Request){
  try{sameOriginOrThrow(request);const form=await request.formData();const planCode=String(form.get("planCode")??"");const jar=await cookies();const access=jar.get(ACCESS_COOKIE)?.value;if(!access)throw new Error("MARKETROUTE_AUTH_REQUIRED");const sessions=sessionServiceFromEnvironment();const session=await sessions.authenticate(access);const workspace=sessions.selectWorkspace(session,jar.get(ORG_COOKIE)?.value);if(workspace.role!=="OWNER")throw new Error("MARKETROUTE_BILLING_OWNER_REQUIRED");const target=await billingServiceFromEnvironment().checkout({organisationId:workspace.organisationId,userId:session.user.id,email:session.user.email,planCode,requestOrigin:new URL(request.url).origin});return NextResponse.redirect(target,303);
  }catch(error){const code=encodeURIComponent(error instanceof Error?error.message:"MARKETROUTE_BILLING_CHECKOUT_FAILED");return NextResponse.redirect(new URL(`/app/plans?billingError=${code}`,request.url),303);}
}
