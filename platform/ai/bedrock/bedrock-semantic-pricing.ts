import type { SemanticModelPricing } from "../../../core/ai/semantic-economics";

export const SONNET45_EU_GEO_INPUT_USD_PER_MILLION_TOKENS = 3.3 as const;
export const SONNET45_EU_GEO_OUTPUT_USD_PER_MILLION_TOKENS = 16.5 as const;

export const SONNET45_EU_GEO_PRICING: Readonly<SemanticModelPricing> = Object.freeze({
  inputUsdPerMillionUnits: SONNET45_EU_GEO_INPUT_USD_PER_MILLION_TOKENS,
  outputUsdPerMillionUnits: SONNET45_EU_GEO_OUTPUT_USD_PER_MILLION_TOKENS,
  pricingBasis: "AWS_EU_GEO_CROSS_REGION_PUBLIC_PRICE",
});
