-- MarketRoute V2 Production Hotfix 0.18.3.6
-- Route relationship claim fingerprint-version repair.
-- Safe scope: replaces one existing RPC only; no schema/table/authority changes.

BEGIN;

CREATE OR REPLACE FUNCTION public.marketroute_ensure_commercial_relationship_v1(
  p_tenant_scope_organisation_id uuid,p_relation_type text,p_from_node_id uuid,p_to_node_id uuid,p_ontology_version text,p_canonical_version text
) RETURNS TABLE(relationship_id uuid,claim_id uuid,relationship_fingerprint text,deduplicated boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_type public.commercial_relationship_type_registry%ROWTYPE; v_from public.commercial_graph_nodes%ROWTYPE; v_to public.commercial_graph_nodes%ROWTYPE; v_from_id uuid:=p_from_node_id; v_to_id uuid:=p_to_node_id; v_tmp uuid; v_fp text; v_claim_fp text; v_existing public.commercial_relationships%ROWTYPE; v_claim_id uuid; v_relationship_id uuid:=gen_random_uuid();
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT * INTO v_type FROM public.commercial_relationship_type_registry WHERE relation_type=p_relation_type;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_RELATIONSHIP_TYPE_UNKNOWN'; END IF;
  IF p_ontology_version IS DISTINCT FROM v_type.ontology_version OR p_canonical_version IS DISTINCT FROM 'MRV2-RELATIONSHIP-CANON-1.0.0' THEN RAISE EXCEPTION 'MARKETROUTE_RELATIONSHIP_VERSION_MISMATCH'; END IF;
  SELECT * INTO v_from FROM public.commercial_graph_nodes WHERE id=v_from_id; IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_RELATIONSHIP_FROM_NODE_NOT_FOUND'; END IF;
  SELECT * INTO v_to FROM public.commercial_graph_nodes WHERE id=v_to_id; IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_RELATIONSHIP_TO_NODE_NOT_FOUND'; END IF;
  IF NOT (v_type.allowed_from_kinds ? v_from.node_kind) OR NOT (v_type.allowed_to_kinds ? v_to.node_kind) THEN RAISE EXCEPTION 'MARKETROUTE_RELATIONSHIP_ENDPOINT_KIND_INVALID'; END IF;
  IF p_tenant_scope_organisation_id IS NULL AND (v_from.tenant_scope_organisation_id IS NOT NULL OR v_to.tenant_scope_organisation_id IS NOT NULL) THEN RAISE EXCEPTION 'MARKETROUTE_GLOBAL_RELATIONSHIP_PRIVATE_NODE'; END IF;
  IF p_tenant_scope_organisation_id IS NOT NULL AND ((v_from.tenant_scope_organisation_id IS NOT NULL AND v_from.tenant_scope_organisation_id<>p_tenant_scope_organisation_id) OR (v_to.tenant_scope_organisation_id IS NOT NULL AND v_to.tenant_scope_organisation_id<>p_tenant_scope_organisation_id)) THEN RAISE EXCEPTION 'MARKETROUTE_RELATIONSHIP_NODE_SCOPE_MISMATCH'; END IF;
  IF v_from_id=v_to_id THEN RAISE EXCEPTION 'MARKETROUTE_RELATIONSHIP_SELF_EDGE'; END IF;
  IF v_type.direction='UNDIRECTED' AND v_from.node_fingerprint>v_to.node_fingerprint THEN v_tmp:=v_from_id;v_from_id:=v_to_id;v_to_id:=v_tmp; SELECT * INTO v_from FROM public.commercial_graph_nodes WHERE id=v_from_id; SELECT * INTO v_to FROM public.commercial_graph_nodes WHERE id=v_to_id; END IF;
  v_fp:=encode(extensions.digest(concat_ws('|','MRV2-RELATIONSHIP-1.0.0',COALESCE(p_tenant_scope_organisation_id::text,'GLOBAL'),p_relation_type,v_from.node_fingerprint,v_to.node_fingerprint,v_type.ontology_version),'sha256'),'hex');
  SELECT * INTO v_existing FROM public.commercial_relationships r WHERE r.relationship_fingerprint=v_fp;
  IF FOUND THEN RETURN QUERY SELECT v_existing.id,v_existing.claim_id,v_existing.relationship_fingerprint,true; RETURN; END IF;
  v_claim_fp:=encode(extensions.digest(concat_ws('|','MRV2-RELATIONSHIP-CLAIM-1.0.0',COALESCE(p_tenant_scope_organisation_id::text,'GLOBAL'),v_fp,'relationship.exists','EXISTS','true'),'sha256'),'hex');
  INSERT INTO public.claims(tenant_scope_organisation_id,subject_type,subject_id,claim_key,predicate,object_json,canonical_value_text,claim_fingerprint,fingerprint_version)
  VALUES(p_tenant_scope_organisation_id,'RELATIONSHIP',v_relationship_id,'relationship.exists','EXISTS','true'::jsonb,'true',v_claim_fp,'MRV2-CLAIM-FP-1.0.0')
  RETURNING id INTO v_claim_id;
  -- Relationship id is the evidence subject identity.
  INSERT INTO public.commercial_relationships(id,tenant_scope_organisation_id,relation_type,from_node_id,to_node_id,claim_id,relationship_fingerprint,ontology_version,canonical_version)
  VALUES(v_relationship_id,p_tenant_scope_organisation_id,p_relation_type,v_from_id,v_to_id,v_claim_id,v_fp,v_type.ontology_version,p_canonical_version);
  RETURN QUERY SELECT v_relationship_id,v_claim_id,v_fp,false;
END; $$;

REVOKE ALL ON FUNCTION public.marketroute_ensure_commercial_relationship_v1(uuid,text,uuid,uuid,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_ensure_commercial_relationship_v1(uuid,text,uuid,uuid,text,text) TO service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
