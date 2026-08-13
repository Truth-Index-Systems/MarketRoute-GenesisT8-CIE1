import {
  ENGAGEMENT_GENERATION_CONTRACT_VERSION,
  ENGAGEMENT_REVIEW_CONTRACT_VERSION,
  canonicaliseEngagementMessage,
  canonicaliseEngagementReview,
  type CanonicalEngagementMessage,
  type CanonicalEngagementReview,
  type EngagementChannel,
  type EngagementReviewCandidate,
  type EngagementStrategyContext,
} from "../../core/engagement/index";

export interface EngagementGenerationProviderResult {
  contractVersion: typeof ENGAGEMENT_GENERATION_CONTRACT_VERSION;
  generatorVersion: string;
  message: { subjectText?: string | null; bodyText: string };
}
export interface EngagementReviewProviderResult {
  contractVersion: typeof ENGAGEMENT_REVIEW_CONTRACT_VERSION;
  reviewerVersion: string;
  review: EngagementReviewCandidate;
}
export interface EngagementLanguageProvider {
  generate(context: EngagementStrategyContext, channel: EngagementChannel, options: { signal: AbortSignal; previousMessage?: CanonicalEngagementMessage | null; rewriteReasons?: string[] }): Promise<EngagementGenerationProviderResult>;
  review(context: EngagementStrategyContext, channel: EngagementChannel, message: CanonicalEngagementMessage, options: { signal: AbortSignal }): Promise<EngagementReviewProviderResult>;
}


function exactKeys(value: unknown, allowed: readonly string[], code: string): void {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(code);
  const extras = Object.keys(value as Record<string, unknown>).filter(k => !allowed.includes(k));
  if (extras.length) throw new Error(`${code}:${extras.sort()[0]}`);
}

export class UnconfiguredEngagementLanguageProvider implements EngagementLanguageProvider {
  async generate(): Promise<EngagementGenerationProviderResult> { throw new Error("MARKETROUTE_ENGAGEMENT_LANGUAGE_PROVIDER_NOT_CONFIGURED"); }
  async review(): Promise<EngagementReviewProviderResult> { throw new Error("MARKETROUTE_ENGAGEMENT_LANGUAGE_PROVIDER_NOT_CONFIGURED"); }
}

export function validateGenerationResult(channel: EngagementChannel, value: EngagementGenerationProviderResult): { generatorVersion: string; message: CanonicalEngagementMessage } {
  exactKeys(value,["contractVersion","generatorVersion","message"],"MARKETROUTE_ENGAGEMENT_GENERATION_OUTPUT_SHAPE_INVALID");
  exactKeys(value.message,["subjectText","bodyText"],"MARKETROUTE_ENGAGEMENT_MESSAGE_OUTPUT_SHAPE_INVALID");
  if (value.contractVersion !== ENGAGEMENT_GENERATION_CONTRACT_VERSION) throw new Error("MARKETROUTE_ENGAGEMENT_GENERATION_CONTRACT_MISMATCH");
  const generatorVersion = value.generatorVersion.normalize("NFKC").trim(); if (!generatorVersion || generatorVersion.length > 160) throw new Error("MARKETROUTE_ENGAGEMENT_GENERATOR_VERSION_INVALID");
  return { generatorVersion, message: canonicaliseEngagementMessage(channel, value.message) };
}
export function validateReviewResult(value: EngagementReviewProviderResult): { reviewerVersion: string; review: CanonicalEngagementReview } {
  exactKeys(value,["contractVersion","reviewerVersion","review"],"MARKETROUTE_ENGAGEMENT_REVIEW_OUTPUT_SHAPE_INVALID");
  exactKeys(value.review,["verdict","reasonCodes","diagnostics"],"MARKETROUTE_ENGAGEMENT_REVIEW_PAYLOAD_SHAPE_INVALID");
  if (value.contractVersion !== ENGAGEMENT_REVIEW_CONTRACT_VERSION) throw new Error("MARKETROUTE_ENGAGEMENT_REVIEW_CONTRACT_MISMATCH");
  const reviewerVersion = value.reviewerVersion.normalize("NFKC").trim(); if (!reviewerVersion || reviewerVersion.length > 160) throw new Error("MARKETROUTE_ENGAGEMENT_REVIEWER_VERSION_INVALID");
  return { reviewerVersion, review: canonicaliseEngagementReview(value.review) };
}
