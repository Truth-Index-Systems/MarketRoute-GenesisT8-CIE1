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
  validateGenerationResult,
  validateReviewResult,
  type EngagementLanguageProvider,
} from "../../platform/ai/engagement-provider";
import type { EngagementDeliveryProvider } from "../../platform/ai/engagement-delivery-provider";
import { openAIEngagementLanguageProviderFromEnvironment } from "../../platform/ai/openai-engagement-provider";
import { resendDeliveryProviderFromEnvironment } from "../../platform/ai/resend-delivery-provider";
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
  setPolicy(command:{organisationId:string;campaignId:string;actorUserId:string;mode:"HUMAN_ONLY"|"AUTOPILOT";requestId?:string;at?:string}){if(command.mode!=="HUMAN_ONLY")throw new Error("MARKETROUTE_ASSISTED_ENGAGEMENT_ONLY");return this.repository.setPolicy({...command,requestId:command.requestId??randomUUID(),at:now(command.at)});}
  approveMessage(command:{messageId:string;actorUserId:string;decision:"APPROVE"|"REJECT";requestId?:string;at?:string}){return this.repository.approveMessage({...command,requestId:command.requestId??randomUUID(),at:now(command.at)});}
  queueMessage(_command:{messageId:string;requestId?:string;at?:string}){throw new Error("MARKETROUTE_ASSISTED_ENGAGEMENT_ONLY");}
  recordManualContact(command:{opportunityId:string;pathFingerprint:string;messageId:string;actorUserId:string;note?:string|null;requestId?:string;at?:string}){return this.repository.recordManualAction({...command,requestId:command.requestId??randomUUID(),at:now(command.at)});}
  async deliverNext(_workerId:string){throw new Error("MARKETROUTE_ASSISTED_ENGAGEMENT_ONLY");}
}
export function engagementServiceFromEnvironment(languageProvider?:EngagementLanguageProvider,deliveryProvider?:EngagementDeliveryProvider){return new EngagementService(engagementRepositoryFromEnvironment(),languageProvider??openAIEngagementLanguageProviderFromEnvironment(),deliveryProvider??resendDeliveryProviderFromEnvironment());}
