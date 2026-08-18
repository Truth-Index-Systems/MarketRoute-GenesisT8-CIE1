import { createHmac,timingSafeEqual } from "node:crypto";

export type StripePlanCode="STARTER"|"GROWTH"|"SCALE";

type StripeRecord=Record<string,unknown>;

function required(name:string):string{const value=process.env[name]?.trim();if(!value)throw new Error(`MARKETROUTE_ENV_REQUIRED:${name}`);return value;}
function record(value:unknown,label:string):StripeRecord{if(!value||typeof value!=="object"||Array.isArray(value))throw new Error(`MARKETROUTE_STRIPE_${label}_INVALID`);return value as StripeRecord;}
function str(value:unknown):string|null{return typeof value==="string"&&value.trim()?value.trim():null;}
function num(value:unknown):number|null{const parsed=Number(value);return Number.isFinite(parsed)?parsed:null;}
function bool(value:unknown):boolean{return value===true;}
function object(value:unknown):StripeRecord{return value&&typeof value==="object"&&!Array.isArray(value)?value as StripeRecord:{};}
function array(value:unknown):unknown[]{return Array.isArray(value)?value:[];}

export interface StripePriceSnapshot { id:string;active:boolean;currency:string;unitAmount:number;recurringInterval:string|null; }
export interface StripeCheckoutSnapshot { id:string;status:string|null;paymentStatus:string|null;customerId:string|null;subscriptionId:string|null;clientReferenceId:string|null;metadata:StripeRecord; }
export interface StripeSubscriptionSnapshot { id:string;customerId:string|null;status:string;currentPeriodStart:string|null;currentPeriodEnd:string|null;cancelAtPeriodEnd:boolean;priceIds:string[];metadata:StripeRecord; }
export interface StripeEventSnapshot { id:string;type:string;created:number;dataObject:StripeRecord; }

function priceEnvironment(plan:StripePlanCode):string{
  return required(plan==="STARTER"?"STRIPE_PRICE_STARTER":plan==="GROWTH"?"STRIPE_PRICE_GROWTH":"STRIPE_PRICE_SCALE");
}
export function stripePriceIdForPlan(plan:StripePlanCode):string{return priceEnvironment(plan);}
export function stripePlanForPriceId(priceId:string):StripePlanCode|null{
  const pairs:[[StripePlanCode,string],[StripePlanCode,string],[StripePlanCode,string]]=[["STARTER",process.env.STRIPE_PRICE_STARTER?.trim()??""],["GROWTH",process.env.STRIPE_PRICE_GROWTH?.trim()??""],["SCALE",process.env.STRIPE_PRICE_SCALE?.trim()??""]];
  return pairs.find(([,id])=>id&&id===priceId)?.[0]??null;
}

function encode(params:Record<string,string|number|boolean|null|undefined>):URLSearchParams{
  const body=new URLSearchParams();for(const [key,value] of Object.entries(params)){if(value===undefined||value===null)continue;body.set(key,String(value));}return body;
}

export class StripeBillingClient {
  private readonly secret=required("STRIPE_SECRET_KEY");
  private async request(path:string,init?:{method?:"GET"|"POST";body?:URLSearchParams;idempotencyKey?:string}):Promise<StripeRecord>{
    const response=await fetch(`https://api.stripe.com${path}`,{method:init?.method??"GET",headers:{Authorization:`Bearer ${this.secret}`,...(init?.body?{"Content-Type":"application/x-www-form-urlencoded"}:{ }),...(init?.idempotencyKey?{"Idempotency-Key":init.idempotencyKey}:{})},body:init?.body,cache:"no-store"});
    const raw=await response.text();let parsed:unknown=null;try{parsed=raw?JSON.parse(raw):null;}catch{parsed=raw;}
    if(!response.ok){
      const error=parsed&&typeof parsed==="object"&&!Array.isArray(parsed)?object((parsed as StripeRecord).error):{};
      const message=str(error.message)??`HTTP_${response.status}`;
      const lower=message.toLowerCase();
      if(lower.includes("similar object exists in test mode")||lower.includes("test mode")&&lower.includes("live mode key"))throw new Error("MARKETROUTE_STRIPE_MODE_MISMATCH:LIVE_KEY_TEST_OBJECT");
      if(lower.includes("similar object exists in live mode")||lower.includes("live mode")&&lower.includes("test mode key"))throw new Error("MARKETROUTE_STRIPE_MODE_MISMATCH:TEST_KEY_LIVE_OBJECT");
      throw new Error(`MARKETROUTE_STRIPE_REQUEST_FAILED:${message.slice(0,240)}`);
    }
    return record(parsed,"RESPONSE");
  }
  async price(priceId:string):Promise<StripePriceSnapshot>{
    if(!/^price_[A-Za-z0-9]+$/.test(priceId))throw new Error("MARKETROUTE_STRIPE_PRICE_ID_INVALID");const value=await this.request(`/v1/prices/${encodeURIComponent(priceId)}`);const recurring=object(value.recurring);const amount=num(value.unit_amount);if(amount===null)throw new Error("MARKETROUTE_STRIPE_PRICE_AMOUNT_MISSING");return{id:String(value.id??""),active:bool(value.active),currency:String(value.currency??"").toLowerCase(),unitAmount:amount,recurringInterval:str(recurring.interval)};
  }
  async createCheckout(input:{organisationId:string;planCode:StripePlanCode;priceId:string;customerId:string|null;customerEmail:string|null;successUrl:string;cancelUrl:string;attemptId:string}):Promise<{id:string;url:string}>{
    const params:Record<string,string|number|boolean|null|undefined>={mode:"subscription","line_items[0][price]":input.priceId,"line_items[0][quantity]":1,success_url:input.successUrl,cancel_url:input.cancelUrl,client_reference_id:input.organisationId,"metadata[marketroute_organisation_id]":input.organisationId,"metadata[marketroute_plan_code]":input.planCode,"metadata[marketroute_checkout_attempt_id]":input.attemptId,"subscription_data[metadata][marketroute_organisation_id]":input.organisationId,"subscription_data[metadata][marketroute_plan_code]":input.planCode,"subscription_data[metadata][marketroute_checkout_attempt_id]":input.attemptId,expires_at:Math.floor(Date.now()/1000)+30*60};
    if(input.customerId)params.customer=input.customerId;else if(input.customerEmail)params.customer_email=input.customerEmail;
    const value=await this.request("/v1/checkout/sessions",{method:"POST",body:encode(params),idempotencyKey:`mr_checkout_${input.attemptId}`});const id=str(value.id),url=str(value.url);if(!id||!url)throw new Error("MARKETROUTE_STRIPE_CHECKOUT_RESPONSE_INVALID");return{id,url};
  }
  async checkout(sessionId:string):Promise<StripeCheckoutSnapshot>{
    if(!/^cs_(?:test_|live_)?[A-Za-z0-9]+$/.test(sessionId))throw new Error("MARKETROUTE_STRIPE_CHECKOUT_ID_INVALID");const value=await this.request(`/v1/checkout/sessions/${encodeURIComponent(sessionId)}`);return{id:String(value.id??""),status:str(value.status),paymentStatus:str(value.payment_status),customerId:str(value.customer),subscriptionId:str(value.subscription),clientReferenceId:str(value.client_reference_id),metadata:object(value.metadata)};
  }
  async subscription(subscriptionId:string):Promise<StripeSubscriptionSnapshot>{
    if(!/^sub_[A-Za-z0-9]+$/.test(subscriptionId))throw new Error("MARKETROUTE_STRIPE_SUBSCRIPTION_ID_INVALID");const value=await this.request(`/v1/subscriptions/${encodeURIComponent(subscriptionId)}`);const items=object(value.items);const itemRows=array(items.data).map(row=>object(row));const priceIds=itemRows.map(row=>str(object(row.price).id)).filter((id):id is string=>Boolean(id));const firstItem=itemRows[0]??{};const start=num(value.current_period_start)??num(firstItem.current_period_start),end=num(value.current_period_end)??num(firstItem.current_period_end);return{id:String(value.id??""),customerId:str(value.customer),status:String(value.status??"unknown"),currentPeriodStart:start===null?null:new Date(start*1000).toISOString(),currentPeriodEnd:end===null?null:new Date(end*1000).toISOString(),cancelAtPeriodEnd:bool(value.cancel_at_period_end),priceIds,metadata:object(value.metadata)};
  }
  async createPortal(customerId:string,returnUrl:string):Promise<string>{
    if(!/^cus_[A-Za-z0-9]+$/.test(customerId))throw new Error("MARKETROUTE_STRIPE_CUSTOMER_ID_INVALID");const value=await this.request("/v1/billing_portal/sessions",{method:"POST",body:encode({customer:customerId,return_url:returnUrl})});const url=str(value.url);if(!url)throw new Error("MARKETROUTE_STRIPE_PORTAL_RESPONSE_INVALID");return url;
  }
}

function parseSignature(header:string):{timestamp:number;signatures:string[]}{let timestamp=0;const signatures:string[]=[];for(const part of header.split(",")){const index=part.indexOf("=");if(index<1)continue;const key=part.slice(0,index).trim(),value=part.slice(index+1).trim();if(key==="t")timestamp=Number(value);if(key==="v1"&&/^[a-f0-9]{64}$/i.test(value))signatures.push(value.toLowerCase());}if(!Number.isFinite(timestamp)||timestamp<=0||signatures.length===0)throw new Error("MARKETROUTE_STRIPE_WEBHOOK_SIGNATURE_INVALID");return{timestamp,signatures};}
function safeEqualHex(a:string,b:string):boolean{try{const left=Buffer.from(a,"hex"),right=Buffer.from(b,"hex");return left.length===right.length&&left.length>0&&timingSafeEqual(left,right);}catch{return false;}}
export function verifyStripeWebhook(rawBody:string,signatureHeader:string,nowMs=Date.now()):StripeEventSnapshot{
  const secret=required("STRIPE_WEBHOOK_SECRET");const parsed=parseSignature(signatureHeader);if(Math.abs(Math.floor(nowMs/1000)-parsed.timestamp)>300)throw new Error("MARKETROUTE_STRIPE_WEBHOOK_TIMESTAMP_OUTSIDE_TOLERANCE");const expected=createHmac("sha256",secret).update(`${parsed.timestamp}.${rawBody}`,"utf8").digest("hex");if(!parsed.signatures.some(signature=>safeEqualHex(expected,signature)))throw new Error("MARKETROUTE_STRIPE_WEBHOOK_SIGNATURE_INVALID");let payload:unknown;try{payload=JSON.parse(rawBody);}catch{throw new Error("MARKETROUTE_STRIPE_WEBHOOK_JSON_INVALID");}const event=record(payload,"WEBHOOK_EVENT");const id=str(event.id),type=str(event.type),created=num(event.created),data=object(event.data);if(!id||!type||created===null)throw new Error("MARKETROUTE_STRIPE_WEBHOOK_EVENT_INVALID");return{id,type,created,dataObject:object(data.object)};
}
export function stripeBillingClientFromEnvironment(){return new StripeBillingClient();}
