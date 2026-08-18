export const APPLICATION_READ_CONTRACT_VERSION = "MRV2-APPLICATION-READ-1.0.0" as const;

export type JsonPrimitive = string | number | boolean | null;
export type JsonValue = JsonPrimitive | JsonValue[] | { [key: string]: JsonValue };
export type JsonObject = { [key: string]: JsonValue };

export type ApplicationResourceType = "COMMAND_CENTRE" | "CAMPAIGN" | "COMPANY_INTELLIGENCE" | "CLAIM_PROVENANCE" | "COMPANY_INDEX" | "RESEARCH_ACTIVITY" | "ENGAGEMENT_INDEX" | "PROVENANCE_CLAIM_INDEX" | "ROUTE_DISPLAY" | "OPPORTUNITY_INDEX";

export interface CanonicalReadBase {
  contractVersion: typeof APPLICATION_READ_CONTRACT_VERSION;
  resourceType: ApplicationResourceType;
  evaluatedAt: string;
}

export interface CommandCentreReadModel extends CanonicalReadBase {
  resourceType: "COMMAND_CENTRE";
  organisation: {
    organisationId: string;
    name: string;
    slug: string;
    status: "ACTIVE" | "SUSPENDED" | "CLOSED";
  };
  campaigns: Array<{
    campaign: JsonObject;
    seller: JsonObject | null;
    metrics: JsonObject;
    research: JsonObject;
    engagementPolicy: "HUMAN_ONLY" | "AUTOPILOT";
  }>;
}

export interface CampaignReadModel extends CanonicalReadBase {
  resourceType: "CAMPAIGN";
  campaign: JsonObject;
  seller: JsonObject | null;
  sellerContext: JsonObject | null;
  metrics: JsonObject;
  research: JsonObject;
  engagementPolicy: "HUMAN_ONLY" | "AUTOPILOT";
  opportunities: JsonObject[];
}

export interface CompanyIntelligenceReadModel extends CanonicalReadBase {
  resourceType: "COMPANY_INTELLIGENCE";
  profile: JsonObject;
  authority: JsonObject;
  truth: JsonObject | null;
  research: JsonObject;
  workflow: JsonObject;
  engagement: JsonObject | null;
  actions: {
    canReview: boolean;
    canGenerateEngagement: boolean;
    canExecute: boolean;
    requiresResearch: boolean;
  };
}

export interface EngagementReadModel extends JsonObject {
  contractVersion: typeof APPLICATION_READ_CONTRACT_VERSION;
  evaluatedAt: string;
  policyMode: "HUMAN_ONLY" | "AUTOPILOT";
  opportunityExecutableNow: boolean;
}

export interface ClaimProvenanceReadModel extends CanonicalReadBase {
  resourceType: "CLAIM_PROVENANCE";
  scope: JsonObject;
  truthSnapshot: JsonObject;
  claim: JsonObject;
  evidence: JsonObject[];
  evidenceCount: number;
  returnedEvidenceCount: number;
  truncated: boolean;
}


export interface CompanyIndexReadModel extends CanonicalReadBase {
  resourceType: "COMPANY_INDEX";
  organisationId: string;
  campaignId: string;
  totalCount: number;
  offset: number;
  limit: number;
  returnedCount: number;
  companies: JsonObject[];
}

export interface OpportunityIndexReadModel extends CanonicalReadBase {
  resourceType: "OPPORTUNITY_INDEX";
  organisationId: string;
  campaignId: string;
  totalCount: number;
  offset: number;
  limit: number;
  returnedCount: number;
  opportunities: JsonObject[];
}

export interface ResearchActivityReadModel extends CanonicalReadBase {
  resourceType: "RESEARCH_ACTIVITY";
  organisationId: string;
  campaignId: string;
  policy: JsonObject;
  budget: JsonObject;
  plans: JsonObject[];
  workUnits: JsonObject[];
  schedulerRuns: JsonObject[];
}

export interface EngagementIndexReadModel extends CanonicalReadBase {
  resourceType: "ENGAGEMENT_INDEX";
  organisationId: string;
  campaignId: string;
  policyMode: "HUMAN_ONLY" | "AUTOPILOT";
  totalCount: number;
  offset: number;
  limit: number;
  returnedCount: number;
  items: JsonObject[];
}

export interface ProvenanceClaimIndexReadModel extends CanonicalReadBase {
  resourceType: "PROVENANCE_CLAIM_INDEX";
  organisationId: string;
  campaignId: string;
  companyId: string;
  claims: JsonObject[];
}

export interface RouteDisplayReadModel extends CanonicalReadBase { resourceType:"ROUTE_DISPLAY"; organisationId:string; campaignId:string; companyId:string; company:JsonObject; r5Decision:string; r6Decision:string; paths:JsonObject[]; }
