import type { CanonicalGraphNode, CanonicalRelationshipInput, RouteAuthorityContext, RouteAuthorityEvaluation } from "../../core/relationships/index.js";
import { PostgrestRpcClient, databaseConfigFromEnvironment } from "./postgrest-rpc.js";

interface NodeRow { node_id:string; node_fingerprint:string; deduplicated:boolean; }
interface RelationshipRow { relationship_id:string; claim_id:string; relationship_fingerprint:string; deduplicated:boolean; }
interface LinkRow { relationship_id:string; claim_id:string; claim_evidence_link_id:string; link_created:boolean; }
interface PersistR5Row { r5_record_id:string; authority_record_id:string; reasoning_run_id:string; reasoning_artifact_id:string; input_fingerprint:string; authority_fingerprint:string; valid_until:string; deduplicated:boolean; }

function one<T>(value:T[]|T,code:string):T { if(Array.isArray(value)){if(value.length!==1) throw new Error(`${code}:${value.length}`); return value[0]!;} if(!value) throw new Error(`${code}:0`); return value; }

export class RelationshipRepository {
  constructor(private readonly rpc:PostgrestRpcClient){}
  static fromEnvironment(){return new RelationshipRepository(new PostgrestRpcClient(databaseConfigFromEnvironment()));}

  async ensureNode(node:CanonicalGraphNode):Promise<NodeRow>{
    const value=await this.rpc.call<NodeRow[]|NodeRow>("marketroute_ensure_graph_node_v1",{
      p_tenant_scope_organisation_id:node.tenantScopeOrganisationId,p_node_kind:node.nodeKind,p_company_id:node.companyId,p_person_id:node.personId,p_stable_key:node.stableKey,p_label:node.label,p_access_point_kind:node.accessPointKind,p_canonical_value:node.canonicalValue,p_canonical_version:node.canonicalVersion
    }); return one(value,"MARKETROUTE_GRAPH_NODE_ROW_COUNT");
  }

  async ensureRelationship(input:CanonicalRelationshipInput,fromNodeId:string,toNodeId:string):Promise<RelationshipRow>{
    const value=await this.rpc.call<RelationshipRow[]|RelationshipRow>("marketroute_ensure_commercial_relationship_v1",{
      p_tenant_scope_organisation_id:input.tenantScopeOrganisationId,p_relation_type:input.relationType,p_from_node_id:fromNodeId,p_to_node_id:toNodeId,p_ontology_version:input.ontologyVersion,p_canonical_version:input.canonicalVersion
    }); return one(value,"MARKETROUTE_RELATIONSHIP_ROW_COUNT");
  }

  async linkEvidence(relationshipId:string,evidenceItemId:string,polarity:"SUPPORTS"|"CONTRADICTS",linkMethod:"DETERMINISTIC"|"AI_EXTRACTED"|"USER_PROVIDED"|"MIGRATED",linkVersion?:string|null):Promise<LinkRow>{
    const value=await this.rpc.call<LinkRow[]|LinkRow>("marketroute_link_relationship_evidence_v1",{p_relationship_id:relationshipId,p_evidence_item_id:evidenceItemId,p_polarity:polarity,p_link_method:linkMethod,p_link_version:linkVersion??null}); return one(value,"MARKETROUTE_RELATIONSHIP_LINK_ROW_COUNT");
  }

  getUniverseClaimIds(organisationId:string,campaignId:string,companyId:string):Promise<Record<string,string>>{
    return this.rpc.call("marketroute_get_r5_relationship_claim_ids_v1",{p_organisation_id:organisationId,p_campaign_id:campaignId,p_company_id:companyId});
  }

  getR5Context(input:{organisationId:string;campaignId:string;companyId:string;referenceTime:string;relationshipTruthSnapshotMap:Record<string,string>}):Promise<RouteAuthorityContext>{
    return this.rpc.call("marketroute_get_r5_context_v1",{p_organisation_id:input.organisationId,p_campaign_id:input.campaignId,p_company_id:input.companyId,p_reference_time:input.referenceTime,p_relationship_truth_snapshot_map:input.relationshipTruthSnapshotMap});
  }

  async persistR5(e:RouteAuthorityEvaluation,relationshipTruthSnapshotMap:Record<string,string>):Promise<PersistR5Row>{
    const value=await this.rpc.call<PersistR5Row[]|PersistR5Row>("marketroute_persist_route_authority_r5_v1",{
      p_organisation_id:e.organisationId,p_campaign_id:e.campaignId,p_company_id:e.companyId,p_reference_time:e.referenceTime,p_parent_authority_fingerprint:e.parentAuthorityFingerprint,p_relationship_universe_fingerprint:e.relationshipUniverseFingerprint,p_relationship_truth_snapshot_map:relationshipTruthSnapshotMap,p_engine_version:e.engineVersion,p_semantics_version:e.semanticsVersion,p_decision_code:e.decision,p_paths_json:e.paths,p_open_access_point_ids:e.openAccessPointIds,p_contact_truth_required_access_point_ids:e.contactTruthRequiredAccessPointIds,p_distinct_access_point_count:e.distinctAccessPointCount,p_next_revalidation_at:e.nextRevalidationAt
    }); return one(value,"MARKETROUTE_R5_PERSIST_ROW_COUNT");
  }
}
export function relationshipRepositoryFromEnvironment(){return RelationshipRepository.fromEnvironment();}
