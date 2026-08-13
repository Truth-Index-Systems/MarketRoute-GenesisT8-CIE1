import {
  SELLER_GENOME_EXTRACTION_CONTRACT_VERSION,
  type SellerGenomeExtractionEnvelope,
} from "../../core/seller-genome/index.js";

const FORBIDDEN_OUTPUT_KEY = /(confidence|probability|score|rank|fit|viab|authority|priority)/i;

export interface SellerGenomeSourceMaterial {
  sellerBusinessId: string;
  sellerDisplayName: string;
  materialKind: "USER_DECLARED" | "WEBSITE_ANALYSIS" | "IMPORT" | "COMPOSITE";
  content: unknown;
}

export interface SellerGenomeSemanticExtractor {
  readonly extractorVersion: string;
  extract(material: SellerGenomeSourceMaterial): Promise<SellerGenomeExtractionEnvelope>;
}

function inspect(value: unknown, path = "output"): void {
  if (Array.isArray(value)) {
    value.forEach((child, index) => inspect(child, `${path}[${index}]`));
    return;
  }
  if (!value || typeof value !== "object") return;
  for (const [key, child] of Object.entries(value as Record<string, unknown>)) {
    if (FORBIDDEN_OUTPUT_KEY.test(key)) throw new Error(`MARKETROUTE_SELLER_AI_FORBIDDEN_FIELD:${path}.${key}`);
    inspect(child, `${path}.${key}`);
  }
}

export function validateSellerGenomeExtractionEnvelope(envelope: SellerGenomeExtractionEnvelope): SellerGenomeExtractionEnvelope {
  if (envelope.contractVersion !== SELLER_GENOME_EXTRACTION_CONTRACT_VERSION) {
    throw new Error("MARKETROUTE_SELLER_AI_CONTRACT_VERSION_MISMATCH");
  }
  if (!envelope.extractorVersion.trim()) throw new Error("MARKETROUTE_SELLER_AI_EXTRACTOR_VERSION_REQUIRED");
  inspect(envelope.candidate);
  return envelope;
}
