export const MARKETROUTE_CONVERSATION_CONTRACT_VERSION="MRV2-CONVERSATION-1.0.0" as const;

export type MarketRouteNarrativeScope="DISCOVERY_PROGRESS"|"COMMAND_CENTRE"|"CAMPAIGN_OVERVIEW"|"OPPORTUNITY_SUMMARY"|"OPPORTUNITY_QA";
export type MarketRouteNarrativeGeneration="AI"|"DETERMINISTIC_FALLBACK";

export interface MarketRouteNarrative{
  contractVersion:typeof MARKETROUTE_CONVERSATION_CONTRACT_VERSION;
  scope:MarketRouteNarrativeScope;
  headline:string;
  summary:string;
  whyItMatters:string;
  known:string[];
  uncertainties:string[];
  recommendation:string;
  nextAction:string;
  evidenceReferences:string[];
  sourceFingerprint:string;
  generatedAt:string;
  generation:MarketRouteNarrativeGeneration;
}

export interface NarrativeFactSet{
  scope:MarketRouteNarrativeScope;
  scopeKey:string;
  organisationId?:string|null;
  campaignId?:string|null;
  companyId?:string|null;
  subject:string;
  status:string;
  knownFacts:string[];
  uncertainties:string[];
  allowedEvidenceReferences:string[];
  deterministicRecommendation:string;
  deterministicNextAction:string;
}
