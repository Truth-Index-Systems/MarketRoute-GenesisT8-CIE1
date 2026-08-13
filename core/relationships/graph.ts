import { sha256Hex, stableJson } from "../evidence/index.js";
import {
  ROUTE_AUTHORITY_ENGINE_VERSION, ROUTE_AUTHORITY_MAX_HOURS, ROUTE_AUTHORITY_SEMANTICS_VERSION,
  ROUTE_AUTHORITY_WRITER_KEY, ROUTE_AUTHORITY_WRITER_VERSION, ROUTE_GRAPH_MAX_DEPTH, ROUTE_GRAPH_MAX_PATHS, ROUTE_GRAPH_MAX_RELATIONSHIPS,
  type RouteAuthorityContext, type RouteAuthorityEvaluation, type RouteGraphRelationship, type RoutePath,
} from "./contracts.js";

const PERSONAL_ACCESS=new Set(["PERSONAL_EMAIL","LINKEDIN","PERSONAL_PHONE"]);
const HOUR=3_600_000;

function positive(edge: RouteGraphRelationship, referenceMs: number): boolean {
  const next=edge.truth.nextRevalidationAt ? Date.parse(edge.truth.nextRevalidationAt) : NaN;
  return edge.routeTraversable && (edge.truth.truthState === "KNOWN" || edge.truth.truthState === "SUPPORTED") && Number.isFinite(next) && next>referenceMs;
}

interface Walk { nodeIds:string[]; relationshipIds:string[]; edges:RouteGraphRelationship[]; }

export function evaluateRouteAuthority(context: RouteAuthorityContext): RouteAuthorityEvaluation {
  if (context.relationships.length>ROUTE_GRAPH_MAX_RELATIONSHIPS) throw new Error("MARKETROUTE_R5_RELATIONSHIP_UNIVERSE_LIMIT_EXCEEDED");
  const nodes=new Map(context.nodes.map(n=>[n.nodeId,n]));
  if (!nodes.has(context.targetNodeId)) throw new Error("MARKETROUTE_R5_TARGET_NODE_MISSING");
  const reference=Date.parse(context.referenceTime); if (!Number.isFinite(reference)) throw new Error("MARKETROUTE_R5_REFERENCE_TIME_INVALID");
  const parentUntil=Date.parse(context.parentR4.validUntil); if (!Number.isFinite(parentUntil)) throw new Error("MARKETROUTE_R5_PARENT_VALID_UNTIL_INVALID");

  const adjacency=new Map<string,Array<{next:string;edge:RouteGraphRelationship}>>();
  const add=(from:string,next:string,edge:RouteGraphRelationship)=>{const arr=adjacency.get(from)??[];arr.push({next,edge});adjacency.set(from,arr);};
  for(const edge of context.relationships.filter(edge=>positive(edge,reference))){
    add(edge.fromNodeId,edge.toNodeId,edge);
    if(edge.direction === "UNDIRECTED") add(edge.toNodeId,edge.fromNodeId,edge);
  }
  for(const arr of adjacency.values()) arr.sort((a,b)=>a.edge.relationshipFingerprint.localeCompare(b.edge.relationshipFingerprint)||a.next.localeCompare(b.next));

  const paths:RoutePath[]=[];
  if (context.parentR4.current && context.parentR4.decisionCode === "COMMERCIAL_CANDIDATE") {
    const stack:Walk[]=[{nodeIds:[context.targetNodeId],relationshipIds:[],edges:[]}];
    while(stack.length){
      const walk=stack.pop()!; const current=walk.nodeIds.at(-1)!;
      if(walk.relationshipIds.length>=ROUTE_GRAPH_MAX_DEPTH) continue;
      const candidates=[...(adjacency.get(current)??[])].reverse();
      for(const {next,edge} of candidates){
        if(walk.nodeIds.includes(next)) continue;
        const node=nodes.get(next); if(!node) throw new Error("MARKETROUTE_R5_EDGE_NODE_MISSING");
        const nextWalk={nodeIds:[...walk.nodeIds,next],relationshipIds:[...walk.relationshipIds,edge.relationshipId],edges:[...walk.edges,edge]};
        if(node.nodeKind === "ACCESS_POINT"){
          const hasPerson=nextWalk.nodeIds.some(id=>nodes.get(id)?.nodeKind === "PERSON");
          const contactRequired=hasPerson || PERSONAL_ACCESS.has(node.accessPointKind ?? "");
          const knowledgeState=nextWalk.edges.every(e=>e.truth.truthState === "KNOWN") ? "KNOWN" : "SUPPORTED";
          const canonicalRelations=nextWalk.edges.map(e=>({relationType:e.relationType,edgeClass:e.edgeClass,direction:e.direction}));
          const material={nodeIds:nextWalk.nodeIds,relationshipIds:nextWalk.relationshipIds,terminalAccessPointId:next,canonicalRelations};
          if(paths.length>=ROUTE_GRAPH_MAX_PATHS) throw new Error("MARKETROUTE_R5_PATH_LIMIT_EXCEEDED");
          paths.push({pathFingerprint:sha256Hex(`MRV2-R5-PATH-1.0.0|${stableJson(material)}`),nodeIds:nextWalk.nodeIds,relationshipIds:nextWalk.relationshipIds,terminalAccessPointId:next,pathState:contactRequired?"CONTACT_TRUTH_REQUIRED":"ORGANISATIONAL_OPEN",knowledgeState,canonicalRelations});
        } else stack.push(nextWalk);
      }
    }
  }
  const dedup=[...new Map(paths.sort((a,b)=>a.pathFingerprint.localeCompare(b.pathFingerprint)).map(p=>[p.pathFingerprint,p])).values()];
  const openAccessPointIds=[...new Set(dedup.map(p=>p.terminalAccessPointId))].sort();
  const contactTruthRequiredAccessPointIds=openAccessPointIds.filter(id=>{
    const terminalPaths=dedup.filter(p=>p.terminalAccessPointId===id);
    return terminalPaths.length>0 && terminalPaths.every(p=>p.pathState==="CONTACT_TRUTH_REQUIRED");
  });
  const decision = !context.parentR4.current || context.parentR4.decisionCode !== "COMMERCIAL_CANDIDATE" ? "ROUTE_NOT_APPLICABLE" : openAccessPointIds.length ? "ROUTE_STRUCTURALLY_OPEN" : "ROUTE_RESEARCH_REQUIRED";
  const truthExpiries=context.relationships.map(r=>r.truth.nextRevalidationAt).filter((v):v is string=>Boolean(v)).map(Date.parse).filter(v=>Number.isFinite(v)&&v>reference);
  const cap=reference+ROUTE_AUTHORITY_MAX_HOURS*HOUR;
  const nextRevalidationAt=new Date(Math.min(cap,parentUntil,...(truthExpiries.length?truthExpiries:[cap]))).toISOString();
  const diagnosticInputFingerprint=sha256Hex(`MRV2-R5-DIAGNOSTIC-INPUT-1.0.0|${stableJson({parent:context.parentR4.authorityFingerprint,universe:context.relationshipUniverseFingerprint,relationships:context.relationships.map(r=>[r.relationshipFingerprint,r.truth.snapshotFingerprint]),referenceTime:context.referenceTime})}`);
  return {engineVersion:ROUTE_AUTHORITY_ENGINE_VERSION,semanticsVersion:ROUTE_AUTHORITY_SEMANTICS_VERSION,writerKey:ROUTE_AUTHORITY_WRITER_KEY,writerVersion:ROUTE_AUTHORITY_WRITER_VERSION,organisationId:context.organisationId,campaignId:context.campaignId,companyId:context.companyId,referenceTime:context.referenceTime,parentAuthorityFingerprint:context.parentR4.authorityFingerprint,relationshipUniverseFingerprint:context.relationshipUniverseFingerprint,decision,paths:dedup,openAccessPointIds,contactTruthRequiredAccessPointIds,distinctAccessPointCount:openAccessPointIds.length,nextRevalidationAt,diagnosticInputFingerprint};
}
