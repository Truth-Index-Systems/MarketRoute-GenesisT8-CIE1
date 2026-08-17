import { NextResponse } from "next/server";
import { anonymousDiscoveryServiceFromEnvironment,ANONYMOUS_DISCOVERY_COOKIE,newAnonymousBrowserSecret,anonymousDiscoveryCookieOptions } from "@/application/discovery/service";
export const runtime="nodejs";export const maxDuration=30;export const dynamic="force-dynamic";
function ip(request:Request){return (request.headers.get("x-forwarded-for")?.split(",")[0]||request.headers.get("x-real-ip")||"unknown").trim();}
function errorCode(error:unknown){const message=error instanceof Error?error.message:"MARKETROUTE_ANONYMOUS_DISCOVERY_FAILED";if(message.includes("ANONYMOUS_IP_LIMIT"))return"MARKETROUTE_ANONYMOUS_IP_LIMIT";if(message.includes("WEBSITE"))return"MARKETROUTE_ANONYMOUS_WEBSITE_INVALID";if(message.includes("COMPANY_NAME"))return"MARKETROUTE_ANONYMOUS_COMPANY_NAME_REQUIRED";if(message.includes("OFFERING"))return"MARKETROUTE_ANONYMOUS_OFFERING_REQUIRED";return"MARKETROUTE_ANONYMOUS_DISCOVERY_FAILED";}
export async function POST(request:Request){
  let browserSecret=request.headers.get("cookie")?.match(/(?:^|;\s*)marketroute_anonymous_discovery_v1=([^;]+)/)?.[1];
  try{
    const form=await request.formData();
    const resolvedBrowserSecret=browserSecret?decodeURIComponent(browserSecret):newAnonymousBrowserSecret();
    await anonymousDiscoveryServiceFromEnvironment().create({browserSecret:resolvedBrowserSecret,ipAddress:ip(request),companyName:String(form.get("companyName")??""),websiteUrl:String(form.get("websiteUrl")??""),sellerOfferingText:String(form.get("sellerOfferingText")??""),targetMarketText:String(form.get("targetMarketText")??"")});
    const response=NextResponse.redirect(new URL("/discover",request.url),303);
    response.cookies.set(ANONYMOUS_DISCOVERY_COOKIE,resolvedBrowserSecret,anonymousDiscoveryCookieOptions());
    return response;
  }catch(error){const code=errorCode(error);return NextResponse.redirect(new URL(`/discover?error=${encodeURIComponent(code)}`,request.url),303);}
}
