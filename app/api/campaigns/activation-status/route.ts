import { cookies } from "next/headers";
import { NextResponse } from "next/server";
import { sessionServiceFromEnvironment } from "@/application/session/service";
import { ACCESS_COOKIE,ORG_COOKIE } from "@/app/app/_lib/session";

export const dynamic="force-dynamic";

export async function GET(){
  const jar=await cookies();
  const accessToken=jar.get(ACCESS_COOKIE)?.value;
  const organisationId=jar.get(ORG_COOKIE)?.value;
  if(!accessToken||!organisationId)return NextResponse.json({ok:false,error:"MARKETROUTE_AUTH_REQUIRED"},{status:401,headers:{"Cache-Control":"no-store"}});
  try{
    const activation=await sessionServiceFromEnvironment().activationStatus(accessToken,organisationId);
    return NextResponse.json({ok:true,activation},{headers:{"Cache-Control":"no-store"}});
  }catch(error){
    const message=error instanceof Error?error.message:"MARKETROUTE_ACTIVATION_STATUS_FAILED";
    const status=/AUTH|JWT|TOKEN|WORKSPACE_ACCESS_DENIED/i.test(message)?401:500;
    return NextResponse.json({ok:false,error:message},{status,headers:{"Cache-Control":"no-store"}});
  }
}
