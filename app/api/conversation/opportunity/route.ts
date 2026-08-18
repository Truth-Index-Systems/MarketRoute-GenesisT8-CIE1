import { NextResponse } from "next/server";
import { cookies } from "next/headers";
import { ACCESS_COOKIE,ORG_COOKIE } from "@/app/app/_lib/session";
import { sameOriginOrThrow } from "@/app/app/_lib/security";
import { sessionServiceFromEnvironment } from "@/application/session/service";
import { applicationReadServiceFromEnvironment } from "@/application/read-model/service";
import { marketRouteConversationServiceFromEnvironment } from "@/application/conversation/service";

export async function POST(request:Request){
  try{
    sameOriginOrThrow(request);const body=await request.json() as Record<string,unknown>;
    const campaignId=String(body.campaignId??"").trim(),companyId=String(body.companyId??"").trim(),question=String(body.question??"").replace(/\s+/g," ").trim();
    if(!campaignId||!companyId||question.length<3||question.length>320)throw new Error("MARKETROUTE_OPPORTUNITY_QUESTION_INVALID");
    const jar=await cookies(),access=jar.get(ACCESS_COOKIE)?.value;if(!access)throw new Error("MARKETROUTE_AUTH_REQUIRED");
    const sessions=sessionServiceFromEnvironment(),session=await sessions.authenticate(access),workspace=sessions.selectWorkspace(session,jar.get(ORG_COOKIE)?.value);
    const read=applicationReadServiceFromEnvironment();const [model,routes]=await Promise.all([read.company({organisationId:workspace.organisationId,campaignId,companyId}),read.routeDisplay({organisationId:workspace.organisationId,campaignId,companyId})]);
    const narrative=await marketRouteConversationServiceFromEnvironment().opportunityQuestion(model,routes,question);
    return NextResponse.json({narrative},{status:200,headers:{"Cache-Control":"no-store"}});
  }catch(error){const code=error instanceof Error?error.message:"MARKETROUTE_OPPORTUNITY_QUESTION_FAILED";const status=code.includes("AUTH")?401:code.includes("UPGRADE")?403:400;return NextResponse.json({error:code},{status,headers:{"Cache-Control":"no-store"}});}
}
