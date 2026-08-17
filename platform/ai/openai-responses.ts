import { aiUsageRepositoryFromEnvironment } from "../database/ai-usage-repository";
export interface OpenAIUsage { inputTokens:number; cachedInputTokens:number; outputTokens:number; webSearchCalls:number; estimatedCostUsd:number; }
export interface OpenAIStructuredResult<T>{ value:T; responseId:string; model:string; usage:OpenAIUsage; sourceUrls:string[]; }
export interface OpenAIUsageContext{requestKind:string;organisationId?:string|null;campaignId?:string|null;origin?:string|null;}

function required(name:string):string{const value=process.env[name]?.trim();if(!value)throw new Error(`MARKETROUTE_ENV_REQUIRED:${name}`);return value;}
function numeric(name:string,fallback:number):number{const raw=process.env[name]?.trim();const value=raw?Number(raw):fallback;return Number.isFinite(value)&&value>=0?value:fallback;}
function outputText(response:any):string{
  if(!response||response.status!=="completed")throw new Error(`MARKETROUTE_OPENAI_RESPONSE_INCOMPLETE:${String(response?.status??"UNKNOWN")}`);
  for(const item of Array.isArray(response.output)?response.output:[]){if(item?.type!=="message")continue;for(const content of Array.isArray(item.content)?item.content:[]){if(content?.type==="refusal")throw new Error("MARKETROUTE_OPENAI_REFUSAL");if(content?.type==="output_text"&&typeof content.text==="string")return content.text;}}
  throw new Error("MARKETROUTE_OPENAI_OUTPUT_MISSING");
}
function sourceUrlsOf(response:any):string[]{const out=new Set<string>();const visit=(node:any)=>{if(!node)return;if(Array.isArray(node)){for(const x of node)visit(x);return;}if(typeof node!=="object")return;if(typeof node.url==="string"&&/^https?:\/\//i.test(node.url))out.add(node.url);for(const [key,value] of Object.entries(node)){if(["sources","annotations","action"].includes(key))visit(value);}};visit(response?.output);return [...out];}
function usageOf(response:any):OpenAIUsage{
  const inputTokens=Number(response?.usage?.input_tokens??0);const cachedInputTokens=Number(response?.usage?.input_tokens_details?.cached_tokens??0);const outputTokens=Number(response?.usage?.output_tokens??0);
  const webSearchCalls=(Array.isArray(response?.output)?response.output:[]).filter((x:any)=>x?.type==="web_search_call"&&x?.action?.type==="search").length;
  const inputRate=numeric("OPENAI_INPUT_USD_PER_MILLION",0.20);const cachedRate=numeric("OPENAI_CACHED_INPUT_USD_PER_MILLION",0.02);const outputRate=numeric("OPENAI_OUTPUT_USD_PER_MILLION",1.20);const searchRate=numeric("OPENAI_WEB_SEARCH_USD_PER_CALL",0.01);
  const uncached=Math.max(0,inputTokens-cachedInputTokens);const estimatedCostUsd=(uncached/1_000_000)*inputRate+(cachedInputTokens/1_000_000)*cachedRate+(outputTokens/1_000_000)*outputRate+webSearchCalls*searchRate;
  return {inputTokens,cachedInputTokens,outputTokens,webSearchCalls,estimatedCostUsd:Number(estimatedCostUsd.toFixed(6))};
}
export function openAIModel():string{return process.env.OPENAI_MODEL?.trim()||"gpt-5.6-luna";}
export class OpenAIResponsesClient{
  private readonly apiKey=required("OPENAI_API_KEY");
  async structured<T>(input:{model?:string;name:string;schema:Record<string,unknown>;instructions:string;prompt:string;webSearch?:boolean;allowedDomains?:string[];signal?:AbortSignal;maxOutputTokens?:number;usageContext?:OpenAIUsageContext}):Promise<OpenAIStructuredResult<T>>{
    const started=Date.now();const model=input.model?.trim()||openAIModel();
    const body:any={model,instructions:input.instructions,input:input.prompt,reasoning:{effort:process.env.OPENAI_REASONING_EFFORT?.trim()||"low"},text:{format:{type:"json_schema",name:input.name,strict:true,schema:input.schema}},max_output_tokens:input.maxOutputTokens??4000};
    if(input.webSearch){const tool:any={type:"web_search",search_context_size:process.env.OPENAI_WEB_SEARCH_CONTEXT?.trim()||"medium"};const allowed=(input.allowedDomains??[]).map(x=>x.trim().toLowerCase().replace(/^https?:\/\//,"").replace(/\/.*$/,"")).filter(Boolean).slice(0,100);if(allowed.length)tool.filters={allowed_domains:allowed};body.tools=[tool];body.tool_choice="required";body.include=["web_search_call.action.sources"];}
    let parsed:any=null;
    try{
      const response=await fetch("https://api.openai.com/v1/responses",{method:"POST",headers:{Authorization:`Bearer ${this.apiKey}`,"Content-Type":"application/json"},body:JSON.stringify(body),signal:input.signal,cache:"no-store"});
      const raw=await response.text();try{parsed=raw?JSON.parse(raw):null}catch{parsed={raw}}if(!response.ok)throw new Error(`MARKETROUTE_OPENAI_HTTP_${response.status}:${String(parsed?.error?.code??parsed?.error?.message??"REQUEST_FAILED")}`);
      const text=outputText(parsed);let value:T;try{value=JSON.parse(text) as T}catch{throw new Error("MARKETROUTE_OPENAI_STRUCTURED_PARSE_FAILED")}
      const usage=usageOf(parsed);const result={value,responseId:String(parsed.id??""),model:String(parsed.model??model),usage,sourceUrls:sourceUrlsOf(parsed)};
      if(input.usageContext)void aiUsageRepositoryFromEnvironment().record({organisationId:input.usageContext.organisationId??null,campaignId:input.usageContext.campaignId??null,provider:"OPENAI_RESPONSES",model:result.model,requestKind:input.usageContext.requestKind,inputTokens:usage.inputTokens,outputTokens:usage.outputTokens,costUsd:usage.estimatedCostUsd,latencyMs:Date.now()-started,status:"SUCCEEDED",metadata:{cachedInputTokens:usage.cachedInputTokens,webSearchCalls:usage.webSearchCalls,responseId:result.responseId,researchOrigin:input.usageContext.origin??null}}).catch(()=>{});
      return result;
    }catch(error){
      if(input.usageContext){const usage=usageOf(parsed);const status=input.signal?.aborted?"CANCELLED":"FAILED";void aiUsageRepositoryFromEnvironment().record({organisationId:input.usageContext.organisationId??null,campaignId:input.usageContext.campaignId??null,provider:"OPENAI_RESPONSES",model:String(parsed?.model??model),requestKind:input.usageContext.requestKind,inputTokens:usage.inputTokens,outputTokens:usage.outputTokens,costUsd:usage.estimatedCostUsd,latencyMs:Date.now()-started,status,metadata:{cachedInputTokens:usage.cachedInputTokens,webSearchCalls:usage.webSearchCalls,errorCode:error instanceof Error?error.message.slice(0,300):"UNKNOWN",researchOrigin:input.usageContext.origin??null}}).catch(()=>{});}
      throw error;
    }
  }
}
