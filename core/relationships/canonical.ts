import { sha256Hex, stableJson } from "../evidence/index.js";
import {
  RELATIONSHIP_CANONICAL_VERSION,
  RELATIONSHIP_ONTOLOGY_VERSION,
  type AccessPointKind,
  type CanonicalGraphNode,
  type CanonicalRelationshipInput,
  type CommercialRelationshipType,
  type GraphNodeKind,
  type RawGraphNodeInput,
  type RawRelationshipInput,
  type RelationshipTypeDefinition,
} from "./contracts.js";


const FORBIDDEN_AUTHORITY_KEYS=new Set(["score","confidence","probability","weight","rank","authority","strength","viability"]);
function rejectAuthorityFields(value: unknown): void {
  if (!value || typeof value !== "object") return;
  if (Array.isArray(value)) { for (const item of value) rejectAuthorityFields(item); return; }
  for (const [key,nested] of Object.entries(value as Record<string,unknown>)) {
    if (FORBIDDEN_AUTHORITY_KEYS.has(key.toLowerCase())) throw new Error("MARKETROUTE_RELATIONSHIP_AI_NUMERIC_AUTHORITY_FORBIDDEN");
    rejectAuthorityFields(nested);
  }
}

export const RELATIONSHIP_DEFINITIONS: Readonly<Record<CommercialRelationshipType, RelationshipTypeDefinition>> = {
  depends_on:{relationType:"depends_on",edgeClass:"DEPENDENCY",direction:"DIRECTED",routeTraversable:false,allowedFromKinds:["COMPANY"],allowedToKinds:["COMPANY","TECHNOLOGY"]},
  equivalent_to:{relationType:"equivalent_to",edgeClass:"ASSOCIATION",direction:"UNDIRECTED",routeTraversable:false,allowedFromKinds:["COMPANY","TECHNOLOGY"],allowedToKinds:["COMPANY","TECHNOLOGY"]},
  part_of:{relationType:"part_of",edgeClass:"HIERARCHY",direction:"DIRECTED",routeTraversable:false,allowedFromKinds:["ORGANISATIONAL_UNIT","COMPANY"],allowedToKinds:["COMPANY"]},
  parent_of:{relationType:"parent_of",edgeClass:"HIERARCHY",direction:"DIRECTED",routeTraversable:true,allowedFromKinds:["COMPANY"],allowedToKinds:["ORGANISATIONAL_UNIT"]},
  subsidiary_of:{relationType:"subsidiary_of",edgeClass:"HIERARCHY",direction:"DIRECTED",routeTraversable:false,allowedFromKinds:["COMPANY"],allowedToKinds:["COMPANY"]},
  partners_with:{relationType:"partners_with",edgeClass:"ASSOCIATION",direction:"UNDIRECTED",routeTraversable:false,allowedFromKinds:["COMPANY"],allowedToKinds:["COMPANY"]},
  supplies:{relationType:"supplies",edgeClass:"ASSOCIATION",direction:"DIRECTED",routeTraversable:false,allowedFromKinds:["COMPANY"],allowedToKinds:["COMPANY"]},
  customer_of:{relationType:"customer_of",edgeClass:"ASSOCIATION",direction:"DIRECTED",routeTraversable:false,allowedFromKinds:["COMPANY"],allowedToKinds:["COMPANY"]},
  uses_technology_from:{relationType:"uses_technology_from",edgeClass:"DEPENDENCY",direction:"DIRECTED",routeTraversable:false,allowedFromKinds:["COMPANY"],allowedToKinds:["COMPANY","TECHNOLOGY"]},
  supersedes:{relationType:"supersedes",edgeClass:"ASSOCIATION",direction:"DIRECTED",routeTraversable:false,allowedFromKinds:["COMPANY","TECHNOLOGY"],allowedToKinds:["COMPANY","TECHNOLOGY"]},
  employs:{relationType:"employs",edgeClass:"COMPOSITION",direction:"DIRECTED",routeTraversable:true,allowedFromKinds:["COMPANY"],allowedToKinds:["PERSON"]},
  has_access_point:{relationType:"has_access_point",edgeClass:"ACCESS",direction:"DIRECTED",routeTraversable:true,allowedFromKinds:["COMPANY","PERSON","ORGANISATIONAL_UNIT"],allowedToKinds:["ACCESS_POINT"]},
  introduced_by:{relationType:"introduced_by",edgeClass:"ACCESS",direction:"DIRECTED",routeTraversable:true,allowedFromKinds:["COMPANY"],allowedToKinds:["COMPANY"]},
};

function clean(value: string | null | undefined): string | null {
  const v=value?.normalize("NFKC").trim() ?? ""; return v || null;
}
function cleanKey(value: string | null | undefined): string | null {
  const v=clean(value); return v ? v.toLowerCase().replace(/\s+/g,"_") : null;
}
function cleanAccessValue(kind: AccessPointKind | null, value: string | null): string | null {
  if (!value) return null;
  const v=value.trim();
  if (kind === "GENERIC_EMAIL" || kind === "DEPARTMENT_EMAIL" || kind === "PERSONAL_EMAIL") return v.toLowerCase();
  if (kind === "CONTACT_FORM" || kind === "DEPARTMENT_FORM" || kind === "LINKEDIN") {
    try { const u=new URL(v); u.hash=""; return u.toString().replace(/\/$/,""); } catch { throw new Error("MARKETROUTE_RELATIONSHIP_ACCESS_URL_INVALID"); }
  }
  return v;
}
function scope(input: RawGraphNodeInput): string | null { return clean(input.tenantScopeOrganisationId) ?? null; }

export function canonicaliseGraphNode(input: RawGraphNodeInput): CanonicalGraphNode {
  const nodeKind=input.nodeKind;
  const requestedScope=scope(input);
  const tenantScopeOrganisationId=(input.nodeKind === "COMPANY" || input.nodeKind === "PERSON") ? null : requestedScope;
  const companyId=clean(input.companyId);
  const personId=clean(input.personId);
  const stableKey=cleanKey(input.stableKey);
  const label=clean(input.label);
  const accessPointKind=input.accessPointKind ?? null;
  const canonicalValue=cleanAccessValue(accessPointKind,clean(input.canonicalValue));

  if ((nodeKind === "COMPANY" || nodeKind === "PERSON") && requestedScope !== null) throw new Error("MARKETROUTE_CANONICAL_ENTITY_NODE_MUST_BE_GLOBAL");
  if (nodeKind === "COMPANY" && (!companyId || personId || stableKey || accessPointKind || canonicalValue)) throw new Error("MARKETROUTE_GRAPH_COMPANY_NODE_INVALID");
  if (nodeKind === "PERSON" && (!personId || companyId || stableKey || accessPointKind || canonicalValue)) throw new Error("MARKETROUTE_GRAPH_PERSON_NODE_INVALID");
  if (nodeKind === "ACCESS_POINT" && (companyId || personId || !stableKey || !accessPointKind || !canonicalValue)) throw new Error("MARKETROUTE_GRAPH_ACCESS_POINT_INVALID");
  if ((nodeKind === "ORGANISATIONAL_UNIT" || nodeKind === "TECHNOLOGY") && (companyId || personId || !stableKey || accessPointKind || canonicalValue)) throw new Error("MARKETROUTE_GRAPH_SEMANTIC_NODE_INVALID");

  const identityStableKey=nodeKind === "ACCESS_POINT" ? null : stableKey;
  const identity={tenantScopeOrganisationId,nodeKind,companyId,personId,stableKey:identityStableKey,accessPointKind,canonicalValue};
  return {tenantScopeOrganisationId,nodeKind,companyId,personId,stableKey,label,accessPointKind,canonicalValue,nodeFingerprint:sha256Hex(`${RELATIONSHIP_CANONICAL_VERSION}|${stableJson(identity)}`),canonicalVersion:RELATIONSHIP_CANONICAL_VERSION};
}

function endpointAllowed(kind: GraphNodeKind, allowed: GraphNodeKind[]): boolean { return allowed.includes(kind); }

export function canonicaliseRelationship(input: RawRelationshipInput): CanonicalRelationshipInput {
  rejectAuthorityFields(input);
  const definition=RELATIONSHIP_DEFINITIONS[input.relationType];
  if (!definition) throw new Error("MARKETROUTE_RELATIONSHIP_TYPE_UNKNOWN");
  const relationshipScope=clean(input.tenantScopeOrganisationId) ?? null;
  const scopedNode=(node: RawGraphNodeInput): RawGraphNodeInput => ({
    ...node,
    tenantScopeOrganisationId: (node.nodeKind === "COMPANY" || node.nodeKind === "PERSON") ? null : (node.tenantScopeOrganisationId ?? relationshipScope),
  });
  let from=canonicaliseGraphNode(scopedNode(input.from));
  let to=canonicaliseGraphNode(scopedNode(input.to));
  for (const node of [from,to]) {
    if (relationshipScope === null && node.tenantScopeOrganisationId !== null) throw new Error("MARKETROUTE_GLOBAL_RELATIONSHIP_PRIVATE_NODE");
    if (relationshipScope !== null && node.tenantScopeOrganisationId !== null && node.tenantScopeOrganisationId !== relationshipScope) throw new Error("MARKETROUTE_RELATIONSHIP_NODE_SCOPE_MISMATCH");
  }
  if (!endpointAllowed(from.nodeKind,definition.allowedFromKinds) || !endpointAllowed(to.nodeKind,definition.allowedToKinds)) throw new Error("MARKETROUTE_RELATIONSHIP_ENDPOINT_KIND_INVALID");
  if (from.nodeFingerprint === to.nodeFingerprint) throw new Error("MARKETROUTE_RELATIONSHIP_SELF_EDGE");
  if (definition.direction === "UNDIRECTED" && from.nodeFingerprint > to.nodeFingerprint) [from,to]=[to,from];
  const identity={tenantScopeOrganisationId:relationshipScope,relationType:input.relationType,fromNodeFingerprint:from.nodeFingerprint,toNodeFingerprint:to.nodeFingerprint,ontologyVersion:RELATIONSHIP_ONTOLOGY_VERSION};
  return {tenantScopeOrganisationId:relationshipScope,relationType:input.relationType,from,to,relationshipFingerprint:sha256Hex(`${RELATIONSHIP_CANONICAL_VERSION}|${stableJson(identity)}`),ontologyVersion:RELATIONSHIP_ONTOLOGY_VERSION,canonicalVersion:RELATIONSHIP_CANONICAL_VERSION};
}
