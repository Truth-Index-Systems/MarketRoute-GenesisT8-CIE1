import { OpenAIResponsesClient } from "../../platform/ai/openai-responses";
import { PostgrestRestClient } from "../../platform/database/postgrest-rest";

const SMOKE_SCHEMA={
  type:"object",
  additionalProperties:false,
  properties:{status:{type:"string",enum:["OK"]}},
  required:["status"],
} as const;

type ReleaseRow={release_key?:unknown;build_number?:unknown};

export async function runProductionConnectivitySmoke(){
  const database=new PostgrestRestClient();
  const releases=await database.get<ReleaseRow[]>("marketroute_schema_releases?select=release_key,build_number&release_key=eq.MARKETROUTE_V2_BUILD18_PRODUCTION_ACTIVATION&limit=1");
  const release=Array.isArray(releases)?releases[0]:undefined;
  if(!release)throw new Error("MARKETROUTE_PRODUCTION_ACTIVATION_SQL_NOT_APPLIED");
  const openai=await new OpenAIResponsesClient().structured<{status:"OK"}>({
    name:"marketroute_production_smoke",
    schema:SMOKE_SCHEMA as unknown as Record<string,unknown>,
    instructions:"You are performing a MarketRoute production connectivity check. Return only the requested structured status. Do not infer commercial authority.",
    prompt:"Return status OK.",
    maxOutputTokens:64,
  });
  if(openai.value.status!=="OK")throw new Error("MARKETROUTE_OPENAI_SMOKE_UNEXPECTED_OUTPUT");
  return {
    ok:true,
    supabase:{releaseKey:String(release.release_key??""),buildNumber:Number(release.build_number??0)},
    openai:{model:openai.model,responseId:openai.responseId,estimatedCostUsd:openai.usage.estimatedCostUsd},
  };
}
