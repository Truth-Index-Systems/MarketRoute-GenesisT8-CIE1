import { assertCronRequest } from "../../../../application/production/runtime";
import { runProductionConnectivitySmoke } from "../../../../application/production/smoke";
import { observeProductionRuntime } from "../../../../application/production/observability";

export const runtime="nodejs";
export const dynamic="force-dynamic";
export const maxDuration=120;

export async function GET(request:Request){
  try{
    assertCronRequest(request);
    const result=await observeProductionRuntime("SMOKE",()=>runProductionConnectivitySmoke());
    return Response.json(result,{status:200,headers:{"Cache-Control":"no-store"}});
  }catch(error){
    const code=error instanceof Error?error.message:"MARKETROUTE_PRODUCTION_SMOKE_FAILED";
    return Response.json({ok:false,error:code},{status:code==="MARKETROUTE_CRON_UNAUTHORISED"?401:503,headers:{"Cache-Control":"no-store"}});
  }
}
