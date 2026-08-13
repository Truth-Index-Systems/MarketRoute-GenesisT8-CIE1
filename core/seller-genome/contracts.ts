export const SELLER_GENOME_SCHEMA_VERSION = "MRV2-SELLER-GENOME-1.0.0" as const;
export const SELLER_GENOME_CANONICALISATION_VERSION = "MRV2-SELLER-CANON-1.0.0" as const;
export const SELLER_GENOME_EXTRACTION_CONTRACT_VERSION = "MRV2-SELLER-EXTRACT-1.0.0" as const;

export type SemanticDimensionState = "DECLARED" | "EXPLICIT_NONE" | "UNKNOWN";
export type ConstraintMode = "HARD" | "PREFERENCE";
export type CommercialObjectiveType =
  | "ACQUIRE_CUSTOMERS"
  | "EXPAND_ACCOUNTS"
  | "BUILD_PARTNERSHIPS"
  | "ENTER_MARKET"
  | "SOURCE_SUPPLIERS"
  | "RECRUIT_TALENT"
  | "OTHER";

export interface DimensionCandidate<T> {
  state: SemanticDimensionState;
  items: T[];
  unknownQuestion?: string | null;
}

export interface OfferingCandidate {
  offeringKey: string;
  label: string;
  description?: string | null;
  problemCodes?: string[];
  outcomeCodes?: string[];
  deliveryModeCodes?: string[];
}

export interface CapabilityCandidate {
  capabilityKey: string;
  label: string;
  description?: string | null;
}

export interface CommercialObjectiveCandidate {
  objectiveKey: string;
  objectiveType: CommercialObjectiveType;
  statement: string;
  offeringKeys?: string[];
  desiredActionCode: string;
  outcomeCodes?: string[];
}

export interface DeliveryCandidate {
  state: SemanticDimensionState;
  modeCodes: string[];
  notes?: string | null;
  unknownQuestion?: string | null;
}

export interface GeographyCandidate {
  state: SemanticDimensionState;
  countryCodes: string[];
  regionCodes?: string[];
  notes?: string | null;
  unknownQuestion?: string | null;
}

export interface TargetCharacteristicsCandidate {
  state: SemanticDimensionState;
  industryCodes?: string[];
  companySizeBands?: string[];
  businessModelCodes?: string[];
  notes?: string | null;
  unknownQuestion?: string | null;
}

export interface BuyerAssumptionsCandidate {
  state: SemanticDimensionState;
  roleCodes?: string[];
  departmentCodes?: string[];
  painCodes?: string[];
  notes?: string | null;
  unknownQuestion?: string | null;
}

export interface ConstraintCandidate {
  constraintKey: string;
  constraintType: string;
  mode: ConstraintMode;
  valueCodes?: string[];
  statement: string;
}

export interface SellerGenomeCandidate {
  offerings: DimensionCandidate<OfferingCandidate>;
  capabilities: DimensionCandidate<CapabilityCandidate>;
  commercialObjectives: DimensionCandidate<CommercialObjectiveCandidate>;
  delivery: DeliveryCandidate;
  serviceGeography: GeographyCandidate;
  targetCharacteristics: TargetCharacteristicsCandidate;
  buyerAssumptions: BuyerAssumptionsCandidate;
  constraints: DimensionCandidate<ConstraintCandidate>;
}

export interface SellerGenomeExtractionEnvelope {
  contractVersion: typeof SELLER_GENOME_EXTRACTION_CONTRACT_VERSION;
  extractorVersion: string;
  candidate: SellerGenomeCandidate;
}

export interface CanonicalDimension<T> {
  state: SemanticDimensionState;
  items: T[];
}

export interface CanonicalOfferingSemantic {
  offeringKey: string;
  problemCodes: string[];
  outcomeCodes: string[];
  deliveryModeCodes: string[];
}

export interface CanonicalCapabilitySemantic {
  capabilityKey: string;
}

export interface CanonicalObjectiveSemantic {
  objectiveKey: string;
  objectiveType: CommercialObjectiveType;
  offeringKeys: string[];
  desiredActionCode: string;
  outcomeCodes: string[];
}

export interface CanonicalConstraintSemantic {
  constraintKey: string;
  constraintType: string;
  mode: ConstraintMode;
  valueCodes: string[];
}

export interface SellerGenomeSemanticPayload {
  offerings: CanonicalDimension<CanonicalOfferingSemantic>;
  capabilities: CanonicalDimension<CanonicalCapabilitySemantic>;
  commercialObjectives: CanonicalDimension<CanonicalObjectiveSemantic>;
  delivery: { state: SemanticDimensionState; modeCodes: string[] };
  serviceGeography: { state: SemanticDimensionState; countryCodes: string[]; regionCodes: string[] };
  targetCharacteristics: {
    state: SemanticDimensionState;
    industryCodes: string[];
    companySizeBands: string[];
    businessModelCodes: string[];
  };
  buyerAssumptions: {
    state: SemanticDimensionState;
    roleCodes: string[];
    departmentCodes: string[];
    painCodes: string[];
  };
  constraints: CanonicalDimension<CanonicalConstraintSemantic>;
}

export interface SellerGenomeExplanatoryPayload {
  sellerDisplayName: string;
  offeringCopy: Array<{ offeringKey: string; label: string; description: string | null }>;
  capabilityCopy: Array<{ capabilityKey: string; label: string; description: string | null }>;
  objectiveCopy: Array<{ objectiveKey: string; statement: string }>;
  constraintCopy: Array<{ constraintKey: string; statement: string }>;
  deliveryNotes: string | null;
  geographyNotes: string | null;
  targetNotes: string | null;
  buyerNotes: string | null;
}

export type SellerGenomeDimensionKey = keyof SellerGenomeSemanticPayload;

export interface ExplicitSellerUnknown {
  dimension: SellerGenomeDimensionKey;
  question: string;
}

export interface CanonicalSellerGenome {
  schemaVersion: typeof SELLER_GENOME_SCHEMA_VERSION;
  canonicalisationVersion: typeof SELLER_GENOME_CANONICALISATION_VERSION;
  sellerBusinessId: string;
  semantic: SellerGenomeSemanticPayload;
  explanatory: SellerGenomeExplanatoryPayload;
  semanticCompleteness: "COMPLETE" | "PARTIAL";
  missingDimensions: SellerGenomeDimensionKey[];
  explicitUnknowns: ExplicitSellerUnknown[];
}
