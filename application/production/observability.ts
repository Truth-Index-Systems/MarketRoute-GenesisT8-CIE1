import { randomUUID } from "node:crypto";
import { productionObservabilityRepositoryFromEnvironment,type RuntimeEventInput,type RuntimeKind } from "../../platform/database/production-observability-repository";

function objectResult(value:unknown):Record<string,unknown>{
  return value&&typeof value==="object"&&!Array.isArray(value)?value as Record<string,unknown>:{value};
}

async function recordBestEffort(input:RuntimeEventInput){
  try{await productionObservabilityRepositoryFromEnvironment().record(input);}catch(error){
    console.error("MarketRoute production observability write failed",error);
  }
}

export async function observeProductionRuntime<T>(runtimeKind:RuntimeKind,operation:()=>Promise<T>):Promise<T>{
  const correlationId=randomUUID();
  const started=Date.now();
  await recordBestEffort({correlationId,runtimeKind,eventType:"STARTED",at:new Date(started).toISOString()});
  try{
    const result=await operation();
    const metadata=objectResult(result);
    const status=String(metadata.status??"").toUpperCase();
    const disabled=status==="DISABLED";
    const failed=status==="FAILED"||status==="PARTIAL";
    const errorCode=failed?String(metadata.errorCode??"MARKETROUTE_RUNTIME_REPORTED_FAILURE"):null;
    await recordBestEffort({correlationId,runtimeKind,eventType:disabled?"DISABLED":failed?"FAILED":"SUCCEEDED",durationMs:Date.now()-started,errorCode,metadata});
    return result;
  }catch(error){
    const code=error instanceof Error?error.message:"MARKETROUTE_RUNTIME_FAILED";
    await recordBestEffort({correlationId,runtimeKind,eventType:"FAILED",durationMs:Date.now()-started,errorCode:code});
    throw error;
  }
}
