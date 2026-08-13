import { randomUUID } from "node:crypto";
import {
  ENGAGEMENT_GENERATION_CONTRACT_VERSION,
  ENGAGEMENT_MAX_REWRITES,
  ENGAGEMENT_REVIEW_CONTRACT_VERSION,
  ENGAGEMENT_STRATEGY_VERSION,
  buildEngagementStrategy,
  engagementMessageFingerprint,
  engagementReviewAllowsProgress,
  type CanonicalEngagementMessage,
} from "../../core/engagement/index";
import {
  UnconfiguredEngagementLanguageProvider,
  validateGenerationResult,
  validateReviewResult,
  type EngagementLanguageProvider,
} from "../../platform/ai/engagement-provider";
import { EngagementDeliveryError, UnconfiguredEngagementDeliveryProvider, type EngagementDeliveryProvider } from "../../platform/ai/engagement-delivery-provider";
import { EngagementRepository, engagementRepositoryFromEnvironment } from "../../platform/database/engagement-repository";

const PROVIDER_TIMEOUT_MS=120_000;
function now(value?:string){return (value?new Date(value):new Date()).toISOString();}
async function withTimeout<T>(fn:(signal:AbortSignal)=>Promise<T>):Promise<T>{const controller=new AbortController();const timer=setTimeout(()=>controller.abort(),PROVIDER_TIMEOUT_MS);try{return await fn(controller.signal);}finally{clearTimeout(timer);}}

export class EngagementService {
  constructor(private readonly repository:EngagementRepository,private readonly languageProvider:EngagementLanguageProvider,private readonly deliveryProvider:EngagementDeliveryProvider){}
  async createReviewedDraft(command:{opportunityId:string;pathFingerprint:string;at?:string}){
    const at=now(command.at);const {context,contextFingerprint}=await this.repository.generationContext(command.opportunityId,command.pathFingerprint,at);
    const strategy=buildEngagementStrategy(context);
    const persistedStrategy=await this.repository.createStrategy({opportunityId:command.opportunityId,pathFingerprint:command.pathFingerprint,requestId:randomUUID(),contextFingerprint,strategyFingerprint:strategy.strategyFingerprint,strategyVersion:ENGAGEMENT_STRATEGY_VERSION,at});
    let previousMessage:CanonicalEngagementMessage|null=null;let previousMessageId:string|null=null;let rewriteReasons:string[]=[];
    for(let rewrite=0;rewrite<=ENGAGEMENT_MAX_REWRITES;rewrite++){
      const generated=validateGenerationResult(strategy.channel,await withTimeout(signal=>this.languageProvider.generate(context,strategy.channel,{signal,previousMessage,rewriteReasons})));
      const messageFingerprint=engagementMessageFingerprint(strategy.strategyFingerprint,generated.message);
      const message=await this.repository.persistMessage({strategyId:persistedStrategy.strategy_id,previousMessageId,requestId:randomUUID(),contextFingerprint,generationContractVersion:ENGAGEMENT_GENERATION_CONTRACT_VERSION,generatorVersion:generated.generatorVersion,subjectText:generated.message.subjectText,bodyText:generated.message.bodyText,messageFingerprint,at:now()});
      const reviewed=validateReviewResult(await withTimeout(signal=>this.languageProvider.review(context,strategy.channel,generated.message,{signal})));
      const review=await this.repository.persistReview({messageId:message.message_id,requestId:randomUUID(),reviewContractVersion:ENGAGEMENT_REVIEW_CONTRACT_VERSION,reviewerVersion:reviewed.reviewerVersion,verdict:reviewed.review.verdict,reasonCodes:reviewed.review.reasonCodes,diagnostics:reviewed.review.diagnostics,at:now()});
      if(engagementReviewAllowsProgress(reviewed.review))return {strategy:persistedStrategy,message,review,rewriteCount:rewrite};
      if(reviewed.review.verdict==="BLOCK")return {strategy:persistedStrategy,message,review,rewriteCount:rewrite};
      previousMessage=generated.message;previousMessageId=message.message_id;rewriteReasons=reviewed.review.reasonCodes;
    }
    throw new Error("MARKETROUTE_ENGAGEMENT_REWRITE_LIMIT_EXHAUSTED");
  }
  setPolicy(command:{organisationId:string;campaignId:string;actorUserId:string;mode:"HUMAN_ONLY"|"AUTOPILOT";requestId?:string;at?:string}){return this.repository.setPolicy({...command,requestId:command.requestId??randomUUID(),at:now(command.at)});}
  approveMessage(command:{messageId:string;actorUserId:string;decision:"APPROVE"|"REJECT";requestId?:string;at?:string}){return this.repository.approveMessage({...command,requestId:command.requestId??randomUUID(),at:now(command.at)});}
  queueMessage(command:{messageId:string;requestId?:string;at?:string}){return this.repository.queue({messageId:command.messageId,requestId:command.requestId??randomUUID(),at:now(command.at)});}
  async deliverNext(workerId:string){const claim=await this.repository.claimDelivery({workerId,at:now()});if(!claim)return null;try{const result=await withTimeout(signal=>this.deliveryProvider.send(claim.delivery_payload,{signal}));await this.repository.completeDelivery({queueItemId:claim.queue_item_id,workerId,providerMessageId:result.providerMessageId,metadata:result.metadata??{},at:now()});return {status:"SENT" as const,claim,result};}catch(error){await this.repository.failDelivery({queueItemId:claim.queue_item_id,workerId,errorCode:error instanceof Error?error.message:"MARKETROUTE_ENGAGEMENT_DELIVERY_FAILED",deliveryStateUnknown:error instanceof EngagementDeliveryError?error.deliveryStateUnknown:true,at:now()});return {status:"FAILED" as const,claim,error};}}
}
export function engagementServiceFromEnvironment(languageProvider:EngagementLanguageProvider=new UnconfiguredEngagementLanguageProvider(),deliveryProvider:EngagementDeliveryProvider=new UnconfiguredEngagementDeliveryProvider()){return new EngagementService(engagementRepositoryFromEnvironment(),languageProvider,deliveryProvider);}
