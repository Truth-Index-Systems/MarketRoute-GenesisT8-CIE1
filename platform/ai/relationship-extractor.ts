import type { CommercialRelationshipType, GraphNodeKind, AccessPointKind } from "../../core/relationships/index";

export interface RelationshipSemanticProposalNode {
  nodeKind: GraphNodeKind;
  companyId?: string | null;
  personId?: string | null;
  stableKey?: string | null;
  label?: string | null;
  accessPointKind?: AccessPointKind | null;
  canonicalValue?: string | null;
}

export interface RelationshipSemanticProposal {
  relationType: CommercialRelationshipType;
  from: RelationshipSemanticProposalNode;
  to: RelationshipSemanticProposalNode;
  rationale?: string | null;
}

export interface RelationshipExtractor {
  extract(input: { text: string; targetCompanyId: string }): Promise<RelationshipSemanticProposal[]>;
}

// Provider implementations are intentionally deferred. AI may propose ontology semantics only;
// it may not emit score/confidence/weight/rank/authority fields.
export const RELATIONSHIP_AI_FORBIDDEN_NUMERIC_AUTHORITY_FIELDS = ["score","confidence","probability","weight","rank","authority","strength"] as const;
