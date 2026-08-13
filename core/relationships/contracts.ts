export const RELATIONSHIP_ONTOLOGY_VERSION = "MRV2-RELATIONSHIP-ONTOLOGY-1.0.0" as const;
export const RELATIONSHIP_CANONICAL_VERSION = "MRV2-RELATIONSHIP-CANON-1.0.0" as const;
export const ROUTE_AUTHORITY_ENGINE_VERSION = "MRV2-R5-ENGINE-1.0.0" as const;
export const ROUTE_AUTHORITY_SEMANTICS_VERSION = "MRV2-R5-SEMANTICS-1.0.0" as const;
export const ROUTE_AUTHORITY_WRITER_KEY = "marketroute.r5.relationship-graph" as const;
export const ROUTE_AUTHORITY_WRITER_VERSION = "1.0.0" as const;
export const ROUTE_AUTHORITY_MAX_HOURS = 12 as const;
export const ROUTE_GRAPH_MAX_DEPTH = 4 as const;
export const ROUTE_GRAPH_MAX_RELATIONSHIPS = 128 as const;
export const ROUTE_GRAPH_MAX_PATHS = 512 as const;

export type GraphNodeKind = "COMPANY" | "PERSON" | "ORGANISATIONAL_UNIT" | "TECHNOLOGY" | "ACCESS_POINT";
export type RelationshipDirection = "DIRECTED" | "UNDIRECTED";
export type RelationshipEdgeClass = "DEPENDENCY" | "HIERARCHY" | "ASSOCIATION" | "COMPOSITION" | "ACCESS";
export type CommercialRelationshipType =
  | "depends_on" | "equivalent_to" | "part_of" | "parent_of" | "subsidiary_of"
  | "partners_with" | "supplies" | "customer_of" | "uses_technology_from"
  | "supersedes" | "employs" | "has_access_point" | "introduced_by";
export type AccessPointKind =
  | "CONTACT_FORM" | "GENERIC_EMAIL" | "SWITCHBOARD" | "DEPARTMENT_EMAIL" | "DEPARTMENT_FORM"
  | "PERSONAL_EMAIL" | "LINKEDIN" | "PERSONAL_PHONE" | "OTHER";

export interface RelationshipTypeDefinition {
  relationType: CommercialRelationshipType;
  edgeClass: RelationshipEdgeClass;
  direction: RelationshipDirection;
  routeTraversable: boolean;
  allowedFromKinds: GraphNodeKind[];
  allowedToKinds: GraphNodeKind[];
}

export interface RawGraphNodeInput {
  tenantScopeOrganisationId?: string | null;
  nodeKind: GraphNodeKind;
  companyId?: string | null;
  personId?: string | null;
  stableKey?: string | null;
  label?: string | null;
  accessPointKind?: AccessPointKind | null;
  canonicalValue?: string | null;
}

export interface CanonicalGraphNode {
  tenantScopeOrganisationId: string | null;
  nodeKind: GraphNodeKind;
  companyId: string | null;
  personId: string | null;
  stableKey: string | null;
  label: string | null;
  accessPointKind: AccessPointKind | null;
  canonicalValue: string | null;
  nodeFingerprint: string;
  canonicalVersion: typeof RELATIONSHIP_CANONICAL_VERSION;
}

export interface RawRelationshipInput {
  tenantScopeOrganisationId?: string | null;
  relationType: CommercialRelationshipType;
  from: RawGraphNodeInput;
  to: RawGraphNodeInput;
}

export interface CanonicalRelationshipInput {
  tenantScopeOrganisationId: string | null;
  relationType: CommercialRelationshipType;
  from: CanonicalGraphNode;
  to: CanonicalGraphNode;
  relationshipFingerprint: string;
  ontologyVersion: typeof RELATIONSHIP_ONTOLOGY_VERSION;
  canonicalVersion: typeof RELATIONSHIP_CANONICAL_VERSION;
}

export type RouteAuthorityDecision = "ROUTE_STRUCTURALLY_OPEN" | "ROUTE_RESEARCH_REQUIRED" | "ROUTE_NOT_APPLICABLE";
export type RelationshipTruthState = "KNOWN" | "SUPPORTED" | "UNRESOLVED" | "CONTRADICTED" | "STALE";
export type RoutePathState = "ORGANISATIONAL_OPEN" | "CONTACT_TRUTH_REQUIRED";
export type RouteKnowledgeState = "KNOWN" | "SUPPORTED";

export interface RouteGraphNode {
  nodeId: string;
  nodeFingerprint: string;
  nodeKind: GraphNodeKind;
  label: string | null;
  accessPointKind: AccessPointKind | null;
  canonicalValue: string | null;
}

export interface RouteRelationshipTruth {
  snapshotId: string;
  snapshotFingerprint: string;
  truthState: RelationshipTruthState;
  nextRevalidationAt: string | null;
}

export interface RouteGraphRelationship {
  relationshipId: string;
  relationshipFingerprint: string;
  relationType: CommercialRelationshipType;
  edgeClass: RelationshipEdgeClass;
  direction: RelationshipDirection;
  routeTraversable: boolean;
  fromNodeId: string;
  toNodeId: string;
  claimId: string;
  truth: RouteRelationshipTruth;
}

export interface RouteAuthorityContext {
  organisationId: string;
  campaignId: string;
  companyId: string;
  referenceTime: string;
  objectiveKey: string;
  targetNodeId: string;
  parentR4: {
    authorityRecordId: string;
    authorityFingerprint: string;
    decisionCode: "COMMERCIAL_CANDIDATE" | "RESEARCH_REQUIRED" | "NOT_ADMISSIBLE";
    validUntil: string;
    current: boolean;
  };
  relationshipUniverseFingerprint: string;
  nodes: RouteGraphNode[];
  relationships: RouteGraphRelationship[];
}

export interface RoutePath {
  pathFingerprint: string;
  nodeIds: string[];
  relationshipIds: string[];
  terminalAccessPointId: string;
  pathState: RoutePathState;
  knowledgeState: RouteKnowledgeState;
  canonicalRelations: Array<{ relationType: CommercialRelationshipType; edgeClass: RelationshipEdgeClass; direction: RelationshipDirection }>;
}

export interface RouteAuthorityEvaluation {
  engineVersion: typeof ROUTE_AUTHORITY_ENGINE_VERSION;
  semanticsVersion: typeof ROUTE_AUTHORITY_SEMANTICS_VERSION;
  writerKey: typeof ROUTE_AUTHORITY_WRITER_KEY;
  writerVersion: typeof ROUTE_AUTHORITY_WRITER_VERSION;
  organisationId: string;
  campaignId: string;
  companyId: string;
  referenceTime: string;
  parentAuthorityFingerprint: string;
  relationshipUniverseFingerprint: string;
  decision: RouteAuthorityDecision;
  paths: RoutePath[];
  openAccessPointIds: string[];
  contactTruthRequiredAccessPointIds: string[];
  distinctAccessPointCount: number;
  nextRevalidationAt: string;
  diagnosticInputFingerprint: string;
}
