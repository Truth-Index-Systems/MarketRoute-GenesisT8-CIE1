import { assertCronRequest, productionEnvironmentStatus } from "../../../../application/production/runtime";
import { observeProductionRuntime } from "../../../../application/production/observability";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(request:Request){
  try{
    assertCronRequest(request);
    const status=await observeProductionRuntime("PREFLIGHT",async()=>productionEnvironmentStatus());
    return Response.json(status,{status:status.ok?200:503,headers:{"Cache-Control":"no-store"}});
  }catch(error){
    const code=error instanceof Error?error.message:"MARKETROUTE_PREFLIGHT_FAILED";
    return Response.json({ok:false,error:code},{status:code==="MARKETROUTE_CRON_UNAUTHORISED"?401:500,headers:{"Cache-Control":"no-store"}});
  }
}
