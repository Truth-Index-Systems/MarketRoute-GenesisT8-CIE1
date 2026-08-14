import { EngagementDeliveryError,type EngagementDeliveryPayload,type EngagementDeliveryProvider,type EngagementDeliveryResult } from "./engagement-delivery-provider";
function required(name:string){const value=process.env[name]?.trim();if(!value)throw new Error(`MARKETROUTE_ENV_REQUIRED:${name}`);return value;}
export class ResendEngagementDeliveryProvider implements EngagementDeliveryProvider{
  async send(payload:EngagementDeliveryPayload,options:{signal:AbortSignal}):Promise<EngagementDeliveryResult>{
    if(payload.channel!=="EMAIL")throw new EngagementDeliveryError(`MARKETROUTE_DELIVERY_CHANNEL_NOT_CONFIGURED:${payload.channel}`,false);
    if(process.env.MARKETROUTE_DELIVERY_ENABLED?.trim().toLowerCase()!=="true")throw new EngagementDeliveryError("MARKETROUTE_DELIVERY_KILL_SWITCH_DISABLED",false);
    const apiKey=required("RESEND_API_KEY"),from=required("MARKETROUTE_EMAIL_FROM");const replyTo=process.env.MARKETROUTE_EMAIL_REPLY_TO?.trim();
    const body:any={from,to:[payload.accessPointValue],subject:payload.subjectText?.trim()||"A quick question",text:payload.bodyText};if(replyTo)body.reply_to=replyTo;
    let response:Response;try{response=await fetch("https://api.resend.com/emails",{method:"POST",headers:{Authorization:`Bearer ${apiKey}`,"Content-Type":"application/json","Idempotency-Key":payload.idempotencyKey.slice(0,256)},body:JSON.stringify(body),signal:options.signal});}catch(error){throw new EngagementDeliveryError(error instanceof Error?`MARKETROUTE_RESEND_NETWORK:${error.message}`:"MARKETROUTE_RESEND_NETWORK",true);}
    const raw=await response.text();let value:any={};try{value=raw?JSON.parse(raw):{}}catch{value={raw}}if(!response.ok){const retryable=response.status===408||response.status===409||response.status===429||response.status>=500;throw new EngagementDeliveryError(`MARKETROUTE_RESEND_HTTP_${response.status}:${String(value?.name??value?.message??"SEND_FAILED")}`,retryable);}
    return{providerMessageId:typeof value?.id==="string"?value.id:null,metadata:{provider:"RESEND",status:response.status}};
  }
}
export function resendDeliveryProviderFromEnvironment(){return new ResendEngagementDeliveryProvider();}
