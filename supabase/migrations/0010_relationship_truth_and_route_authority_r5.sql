BEGIN;

-- MarketRoute V2 Build 7: Relationship Truth + Canonical Commercial Graph / R5
-- Relationships are canonical world assertions whose existence must pass Truth before graph traversal.

INSERT INTO public.truth_claim_policy_registry(policy_key,policy_version,max_age_days,known_support_family_requirement,metadata_json)
VALUES('RELATIONSHIP_CURRENT_V1','1.0.0',120,2,jsonb_build_object('purpose','commercial relationship/access structural currentness'))
ON CONFLICT (policy_key) DO UPDATE SET
  policy_version=EXCLUDED.policy_version,
  max_age_days=EXCLUDED.max_age_days,
  known_support_family_requirement=EXCLUDED.known_support_family_requirement,
  metadata_json=EXCLUDED.metadata_json;

INSERT INTO public.truth_claim_policy_bindings(subject_type,claim_key,policy_key,precedence)
VALUES('RELATIONSHIP','relationship.exists','RELATIONSHIP_CURRENT_V1',40)
ON CONFLICT (subject_type,claim_key) DO UPDATE SET policy_key=EXCLUDED.policy_key, precedence=EXCLUDED.precedence;

CREATE TABLE public.commercial_relationship_type_registry (
  relation_type text PRIMARY KEY,
  edge_class text NOT NULL CHECK(edge_class IN ('DEPENDENCY','HIERARCHY','ASSOCIATION','COMPOSITION','ACCESS')),
  direction text NOT NULL CHECK(direction IN ('DIRECTED','UNDIRECTED')),
  route_traversable boolean NOT NULL,
  allowed_from_kinds jsonb NOT NULL CHECK(jsonb_typeof(allowed_from_kinds)='array' AND jsonb_array_length(allowed_from_kinds)>0),
  allowed_to_kinds jsonb NOT NULL CHECK(jsonb_typeof(allowed_to_kinds)='array' AND jsonb_array_length(allowed_to_kinds)>0),
  ontology_version text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.commercial_relationship_type_registry(relation_type,edge_class,direction,route_traversable,allowed_from_kinds,allowed_to_kinds,ontology_version) VALUES
('depends_on','DEPENDENCY','DIRECTED',false,'["COMPANY"]','["COMPANY","TECHNOLOGY"]','MRV2-RELATIONSHIP-ONTOLOGY-1.0.0'),
('equivalent_to','ASSOCIATION','UNDIRECTED',false,'["COMPANY","TECHNOLOGY"]','["COMPANY","TECHNOLOGY"]','MRV2-RELATIONSHIP-ONTOLOGY-1.0.0'),
('part_of','HIERARCHY','DIRECTED',false,'["ORGANISATIONAL_UNIT","COMPANY"]','["COMPANY"]','MRV2-RELATIONSHIP-ONTOLOGY-1.0.0'),
('parent_of','HIERARCHY','DIRECTED',true,'["COMPANY"]','["ORGANISATIONAL_UNIT"]','MRV2-RELATIONSHIP-ONTOLOGY-1.0.0'),
('subsidiary_of','HIERARCHY','DIRECTED',false,'["COMPANY"]','["COMPANY"]','MRV2-RELATIONSHIP-ONTOLOGY-1.0.0'),
('partners_with','ASSOCIATION','UNDIRECTED',false,'["COMPANY"]','["COMPANY"]','MRV2-RELATIONSHIP-ONTOLOGY-1.0.0'),
('supplies','ASSOCIATION','DIRECTED',false,'["COMPANY"]','["COMPANY"]','MRV2-RELATIONSHIP-ONTOLOGY-1.0.0'),
('customer_of','ASSOCIATION','DIRECTED',false,'["COMPANY"]','["COMPANY"]','MRV2-RELATIONSHIP-ONTOLOGY-1.0.0'),
('uses_technology_from','DEPENDENCY','DIRECTED',false,'["COMPANY"]','["COMPANY","TECHNOLOGY"]','MRV2-RELATIONSHIP-ONTOLOGY-1.0.0'),
('supersedes','ASSOCIATION','DIRECTED',false,'["COMPANY","TECHNOLOGY"]','["COMPANY","TECHNOLOGY"]','MRV2-RELATIONSHIP-ONTOLOGY-1.0.0'),
('employs','COMPOSITION','DIRECTED',true,'["COMPANY"]','["PERSON"]','MRV2-RELATIONSHIP-ONTOLOGY-1.0.0'),
('has_access_point','ACCESS','DIRECTED',true,'["COMPANY","PERSON","ORGANISATIONAL_UNIT"]','["ACCESS_POINT"]','MRV2-RELATIONSHIP-ONTOLOGY-1.0.0'),
('introduced_by','ACCESS','DIRECTED',true,'["COMPANY"]','["COMPANY"]','MRV2-RELATIONSHIP-ONTOLOGY-1.0.0')
ON CONFLICT (relation_type) DO NOTHING;

CREATE TABLE public.commercial_graph_nodes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_scope_organisation_id uuid REFERENCES public.organisations(id) ON DELETE RESTRICT,
  node_kind text NOT NULL CHECK(node_kind IN ('COMPANY','PERSON','ORGANISATIONAL_UNIT','TECHNOLOGY','ACCESS_POINT')),
  company_id uuid REFERENCES public.companies(id) ON DELETE RESTRICT,
  person_id uuid REFERENCES public.people(id) ON DELETE RESTRICT,
  stable_key text,
  label text,
  access_point_kind text CHECK(access_point_kind IS NULL OR access_point_kind IN ('CONTACT_FORM','GENERIC_EMAIL','SWITCHBOARD','DEPARTMENT_EMAIL','DEPARTMENT_FORM','PERSONAL_EMAIL','LINKEDIN','PERSONAL_PHONE','OTHER')),
  canonical_value text,
  node_fingerprint text NOT NULL UNIQUE CHECK(node_fingerprint ~ '^[a-f0-9]{64}$'),
  canonical_version text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (
    (node_kind='COMPANY' AND company_id IS NOT NULL AND person_id IS NULL AND stable_key IS NULL AND access_point_kind IS NULL AND canonical_value IS NULL AND tenant_scope_organisation_id IS NULL)
    OR (node_kind='PERSON' AND person_id IS NOT NULL AND company_id IS NULL AND stable_key IS NULL AND access_point_kind IS NULL AND canonical_value IS NULL AND tenant_scope_organisation_id IS NULL)
    OR (node_kind IN ('ORGANISATIONAL_UNIT','TECHNOLOGY') AND company_id IS NULL AND person_id IS NULL AND stable_key IS NOT NULL AND access_point_kind IS NULL AND canonical_value IS NULL)
    OR (node_kind='ACCESS_POINT' AND company_id IS NULL AND person_id IS NULL AND stable_key IS NOT NULL AND access_point_kind IS NOT NULL AND canonical_value IS NOT NULL)
  )
);

CREATE INDEX commercial_graph_nodes_company_idx ON public.commercial_graph_nodes(company_id) WHERE company_id IS NOT NULL;
CREATE INDEX commercial_graph_nodes_person_idx ON public.commercial_graph_nodes(person_id) WHERE person_id IS NOT NULL;
CREATE INDEX commercial_graph_nodes_scope_kind_idx ON public.commercial_graph_nodes(tenant_scope_organisation_id,node_kind);

CREATE TABLE public.commercial_relationships (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_scope_organisation_id uuid REFERENCES public.organisations(id) ON DELETE RESTRICT,
  relation_type text NOT NULL REFERENCES public.commercial_relationship_type_registry(relation_type) ON DELETE RESTRICT,
  from_node_id uuid NOT NULL REFERENCES public.commercial_graph_nodes(id) ON DELETE RESTRICT,
  to_node_id uuid NOT NULL REFERENCES public.commercial_graph_nodes(id) ON DELETE RESTRICT,
  claim_id uuid NOT NULL UNIQUE REFERENCES public.claims(id) ON DELETE RESTRICT,
  relationship_fingerprint text NOT NULL UNIQUE CHECK(relationship_fingerprint ~ '^[a-f0-9]{64}$'),
  ontology_version text NOT NULL,
  canonical_version text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK(from_node_id<>to_node_id)
);
CREATE INDEX commercial_relationships_scope_idx ON public.commercial_relationships(tenant_scope_organisation_id,relation_type,created_at DESC);
CREATE INDEX commercial_relationships_from_idx ON public.commercial_relationships(from_node_id);
CREATE INDEX commercial_relationships_to_idx ON public.commercial_relationships(to_node_id);

CREATE TABLE public.route_authority_r5_records (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organisation_id uuid NOT NULL REFERENCES public.organisations(id) ON DELETE RESTRICT,
  campaign_id uuid NOT NULL,
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  authority_record_id uuid NOT NULL UNIQUE REFERENCES public.authority_records(id) ON DELETE RESTRICT,
  parent_r4_authority_record_id uuid NOT NULL REFERENCES public.authority_records(id) ON DELETE RESTRICT,
  parent_r4_authority_fingerprint text NOT NULL CHECK(parent_r4_authority_fingerprint ~ '^[a-f0-9]{64}$'),
  relationship_universe_fingerprint text NOT NULL CHECK(relationship_universe_fingerprint ~ '^[a-f0-9]{64}$'),
  relationship_truth_snapshot_map jsonb NOT NULL CHECK(jsonb_typeof(relationship_truth_snapshot_map)='object'),
  engine_version text NOT NULL,
  semantics_version text NOT NULL,
  decision_code text NOT NULL CHECK(decision_code IN ('ROUTE_STRUCTURALLY_OPEN','ROUTE_RESEARCH_REQUIRED','ROUTE_NOT_APPLICABLE')),
  paths_json jsonb NOT NULL CHECK(jsonb_typeof(paths_json)='array'),
  open_access_point_ids jsonb NOT NULL CHECK(jsonb_typeof(open_access_point_ids)='array'),
  contact_truth_required_access_point_ids jsonb NOT NULL CHECK(jsonb_typeof(contact_truth_required_access_point_ids)='array'),
  distinct_access_point_count integer NOT NULL CHECK(distinct_access_point_count>=0),
  input_fingerprint text NOT NULL CHECK(input_fingerprint ~ '^[a-f0-9]{64}$'),
  authority_fingerprint text NOT NULL CHECK(authority_fingerprint ~ '^[a-f0-9]{64}$'),
  reference_time timestamptz NOT NULL,
  next_revalidation_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT route_authority_r5_campaign_scope_fk FOREIGN KEY(organisation_id,campaign_id) REFERENCES public.campaigns(organisation_id,id) ON DELETE RESTRICT,
  CHECK(next_revalidation_at>reference_time)
);
CREATE INDEX route_authority_r5_scope_idx ON public.route_authority_r5_records(organisation_id,campaign_id,company_id,created_at DESC);

CREATE TRIGGER commercial_relationship_type_registry_append_only BEFORE UPDATE OR DELETE ON public.commercial_relationship_type_registry FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();
CREATE TRIGGER commercial_graph_nodes_append_only BEFORE UPDATE OR DELETE ON public.commercial_graph_nodes FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();
CREATE TRIGGER commercial_relationships_append_only BEFORE UPDATE OR DELETE ON public.commercial_relationships FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();
CREATE TRIGGER route_authority_r5_records_append_only BEFORE UPDATE OR DELETE ON public.route_authority_r5_records FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

CREATE OR REPLACE FUNCTION public.marketroute_prevent_relationship_claim_supersession_v1()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  IF EXISTS(SELECT 1 FROM public.commercial_relationships r WHERE r.claim_id=NEW.prior_claim_id) THEN
    RAISE EXCEPTION 'MARKETROUTE_CANONICAL_RELATIONSHIP_CLAIM_SUPERSESSION_FORBIDDEN';
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER relationship_claim_supersession_guard BEFORE INSERT ON public.claim_supersessions FOR EACH ROW EXECUTE FUNCTION public.marketroute_prevent_relationship_claim_supersession_v1();

INSERT INTO public.authority_writer_registry(writer_key,authority_stage,writer_version,enabled,registered_by_build,metadata_json)
VALUES('marketroute.r5.relationship-graph','ROUTE_AUTHORITY','1.0.0',true,7,jsonb_build_object('numeric_authority',false,'database_recomputes_decision',true,'database_recomputes_fingerprint',true))
ON CONFLICT (writer_key) DO NOTHING;

DO $$ BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.authority_writer_registry WHERE writer_key='marketroute.r5.relationship-graph' AND authority_stage='ROUTE_AUTHORITY' AND writer_version='1.0.0' AND enabled) THEN
    RAISE EXCEPTION 'MARKETROUTE_R5_WRITER_REGISTRY_COLLISION';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.marketroute_graph_node_fingerprint_v1(
  p_tenant_scope_organisation_id uuid,p_node_kind text,p_company_id uuid,p_person_id uuid,p_stable_key text,p_access_point_kind text,p_canonical_value text
) RETURNS text LANGUAGE sql IMMUTABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT encode(extensions.digest(concat_ws('|','MRV2-GRAPH-NODE-1.0.0',COALESCE(p_tenant_scope_organisation_id::text,'GLOBAL'),p_node_kind,
    COALESCE(p_company_id::text,'-'),COALESCE(p_person_id::text,'-'),CASE WHEN p_node_kind='ACCESS_POINT' THEN '-' ELSE COALESCE(lower(btrim(p_stable_key)),'-') END,COALESCE(p_access_point_kind,'-'),COALESCE(lower(btrim(p_canonical_value)),'-')),'sha256'),'hex');
$$;

CREATE OR REPLACE FUNCTION public.marketroute_ensure_graph_node_v1(
  p_tenant_scope_organisation_id uuid,p_node_kind text,p_company_id uuid,p_person_id uuid,p_stable_key text,p_label text,p_access_point_kind text,p_canonical_value text,p_canonical_version text
) RETURNS TABLE(node_id uuid,node_fingerprint text,deduplicated boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_fp text; v_node_id uuid; v_existing public.commercial_graph_nodes%ROWTYPE; v_stable text:=NULLIF(lower(btrim(p_stable_key)),''); v_value text:=NULLIF(btrim(p_canonical_value),'');
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF p_canonical_version IS DISTINCT FROM 'MRV2-RELATIONSHIP-CANON-1.0.0' THEN RAISE EXCEPTION 'MARKETROUTE_GRAPH_NODE_CANONICAL_VERSION_MISMATCH'; END IF;
  IF p_node_kind NOT IN ('COMPANY','PERSON','ORGANISATIONAL_UNIT','TECHNOLOGY','ACCESS_POINT') THEN RAISE EXCEPTION 'MARKETROUTE_GRAPH_NODE_KIND_INVALID'; END IF;
  IF p_node_kind IN ('COMPANY','PERSON') AND p_tenant_scope_organisation_id IS NOT NULL THEN RAISE EXCEPTION 'MARKETROUTE_CANONICAL_ENTITY_NODE_MUST_BE_GLOBAL'; END IF;
  IF p_node_kind='COMPANY' AND (p_company_id IS NULL OR p_person_id IS NOT NULL OR v_stable IS NOT NULL OR p_access_point_kind IS NOT NULL OR v_value IS NOT NULL) THEN RAISE EXCEPTION 'MARKETROUTE_GRAPH_COMPANY_NODE_INVALID'; END IF;
  IF p_node_kind='PERSON' AND (p_person_id IS NULL OR p_company_id IS NOT NULL OR v_stable IS NOT NULL OR p_access_point_kind IS NOT NULL OR v_value IS NOT NULL) THEN RAISE EXCEPTION 'MARKETROUTE_GRAPH_PERSON_NODE_INVALID'; END IF;
  IF p_node_kind IN ('ORGANISATIONAL_UNIT','TECHNOLOGY') AND (p_company_id IS NOT NULL OR p_person_id IS NOT NULL OR v_stable IS NULL OR p_access_point_kind IS NOT NULL OR v_value IS NOT NULL) THEN RAISE EXCEPTION 'MARKETROUTE_GRAPH_SEMANTIC_NODE_INVALID'; END IF;
  IF p_node_kind='ACCESS_POINT' AND (p_company_id IS NOT NULL OR p_person_id IS NOT NULL OR v_stable IS NULL OR p_access_point_kind IS NULL OR v_value IS NULL) THEN RAISE EXCEPTION 'MARKETROUTE_GRAPH_ACCESS_POINT_INVALID'; END IF;
  IF p_node_kind='COMPANY' AND NOT EXISTS(SELECT 1 FROM public.companies WHERE id=p_company_id) THEN RAISE EXCEPTION 'MARKETROUTE_GRAPH_COMPANY_NOT_FOUND'; END IF;
  IF p_node_kind='PERSON' AND NOT EXISTS(SELECT 1 FROM public.people WHERE id=p_person_id) THEN RAISE EXCEPTION 'MARKETROUTE_GRAPH_PERSON_NOT_FOUND'; END IF;
  v_fp:=public.marketroute_graph_node_fingerprint_v1(p_tenant_scope_organisation_id,p_node_kind,p_company_id,p_person_id,v_stable,p_access_point_kind,v_value);
  SELECT * INTO v_existing FROM public.commercial_graph_nodes n WHERE n.node_fingerprint=v_fp;
  IF FOUND THEN RETURN QUERY SELECT v_existing.id,v_existing.node_fingerprint,true; RETURN; END IF;
  INSERT INTO public.commercial_graph_nodes(tenant_scope_organisation_id,node_kind,company_id,person_id,stable_key,label,access_point_kind,canonical_value,node_fingerprint,canonical_version)
  VALUES(p_tenant_scope_organisation_id,p_node_kind,p_company_id,p_person_id,v_stable,NULLIF(btrim(p_label),''),p_access_point_kind,v_value,v_fp,p_canonical_version)
  RETURNING id INTO v_node_id;
  RETURN QUERY SELECT v_node_id,v_fp,false;
END; $$;

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

CREATE OR REPLACE FUNCTION public.marketroute_link_relationship_evidence_v1(
  p_relationship_id uuid,p_evidence_item_id uuid,p_polarity text,p_link_method text,p_link_version text DEFAULT NULL
) RETURNS TABLE(relationship_id uuid,claim_id uuid,claim_evidence_link_id uuid,link_created boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_rel public.commercial_relationships%ROWTYPE; v_e public.evidence_items%ROWTYPE; v_link uuid;
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT * INTO v_rel FROM public.commercial_relationships WHERE id=p_relationship_id; IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_RELATIONSHIP_NOT_FOUND'; END IF;
  SELECT * INTO v_e FROM public.evidence_items WHERE id=p_evidence_item_id; IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_RELATIONSHIP_EVIDENCE_NOT_FOUND'; END IF;
  IF v_e.subject_type<>'RELATIONSHIP' OR v_e.subject_id<>v_rel.id OR v_e.tenant_scope_organisation_id IS DISTINCT FROM v_rel.tenant_scope_organisation_id THEN RAISE EXCEPTION 'MARKETROUTE_RELATIONSHIP_EVIDENCE_SCOPE_MISMATCH'; END IF;
  IF p_polarity NOT IN ('SUPPORTS','CONTRADICTS') THEN RAISE EXCEPTION 'MARKETROUTE_RELATIONSHIP_POLARITY_INVALID'; END IF;
  IF p_link_method NOT IN ('DETERMINISTIC','AI_EXTRACTED','USER_PROVIDED','MIGRATED') THEN RAISE EXCEPTION 'MARKETROUTE_RELATIONSHIP_LINK_METHOD_INVALID'; END IF;
  SELECT l.id INTO v_link FROM public.claim_evidence_links l WHERE l.claim_id=v_rel.claim_id AND l.evidence_item_id=p_evidence_item_id;
  IF FOUND THEN
    IF EXISTS(SELECT 1 FROM public.claim_evidence_links WHERE id=v_link AND polarity<>p_polarity) THEN RAISE EXCEPTION 'MARKETROUTE_RELATIONSHIP_EVIDENCE_POLARITY_CONFLICT'; END IF;
    RETURN QUERY SELECT v_rel.id,v_rel.claim_id,v_link,false; RETURN;
  END IF;
  INSERT INTO public.claim_evidence_links(claim_id,evidence_item_id,polarity,dependence_family_key,link_method,link_version)
  VALUES(v_rel.claim_id,p_evidence_item_id,p_polarity,v_e.dependence_family_key,p_link_method,p_link_version) RETURNING id INTO v_link;
  RETURN QUERY SELECT v_rel.id,v_rel.claim_id,v_link,true;
END; $$;

CREATE OR REPLACE FUNCTION public.marketroute_r5_target_node_v1(p_company_id uuid)
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT id FROM public.commercial_graph_nodes WHERE node_kind='COMPANY' AND company_id=p_company_id AND tenant_scope_organisation_id IS NULL ORDER BY created_at,id LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.marketroute_r5_universe_v1(p_organisation_id uuid,p_company_id uuid)
RETURNS TABLE(relationship_id uuid)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
  WITH RECURSIVE target AS (
    SELECT public.marketroute_r5_target_node_v1(p_company_id) AS node_id
  ), walk(node_id,depth,visited) AS (
    SELECT node_id,0,ARRAY[node_id]::uuid[] FROM target WHERE node_id IS NOT NULL
    UNION ALL
    SELECT CASE WHEN t.direction='DIRECTED' THEN r.to_node_id WHEN r.from_node_id=w.node_id THEN r.to_node_id ELSE r.from_node_id END,
           w.depth+1,
           w.visited || CASE WHEN t.direction='DIRECTED' THEN r.to_node_id WHEN r.from_node_id=w.node_id THEN r.to_node_id ELSE r.from_node_id END
    FROM walk w
    JOIN public.commercial_relationships r ON (r.tenant_scope_organisation_id IS NULL OR r.tenant_scope_organisation_id=p_organisation_id)
    JOIN public.commercial_relationship_type_registry t ON t.relation_type=r.relation_type AND t.route_traversable=true
    WHERE w.depth<4
      AND ((t.direction='DIRECTED' AND r.from_node_id=w.node_id) OR (t.direction='UNDIRECTED' AND (r.from_node_id=w.node_id OR r.to_node_id=w.node_id)))
      AND NOT (CASE WHEN t.direction='DIRECTED' THEN r.to_node_id WHEN r.from_node_id=w.node_id THEN r.to_node_id ELSE r.from_node_id END = ANY(w.visited))
  )
  SELECT DISTINCT r.id
  FROM walk w
  JOIN public.commercial_relationships r ON (r.tenant_scope_organisation_id IS NULL OR r.tenant_scope_organisation_id=p_organisation_id)
  JOIN public.commercial_relationship_type_registry t ON t.relation_type=r.relation_type AND t.route_traversable=true
  WHERE w.depth<4 AND ((t.direction='DIRECTED' AND r.from_node_id=w.node_id) OR (t.direction='UNDIRECTED' AND (r.from_node_id=w.node_id OR r.to_node_id=w.node_id)));
$$;

CREATE OR REPLACE FUNCTION public.marketroute_r5_universe_fingerprint_v1(p_organisation_id uuid,p_company_id uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT encode(extensions.digest('MRV2-R5-UNIVERSE-1.0.0|'||COALESCE(string_agg(r.relationship_fingerprint,';' ORDER BY r.relationship_fingerprint),''),'sha256'),'hex')
  FROM public.commercial_relationships r WHERE r.id IN (SELECT relationship_id FROM public.marketroute_r5_universe_v1(p_organisation_id,p_company_id));
$$;

CREATE OR REPLACE FUNCTION public.marketroute_get_r5_relationship_claim_ids_v1(p_organisation_id uuid,p_campaign_id uuid,p_company_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_result jsonb;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF NOT EXISTS(SELECT 1 FROM public.organisation_company_scopes s WHERE s.organisation_id=p_organisation_id AND s.campaign_id=p_campaign_id AND s.company_id=p_company_id) THEN RAISE EXCEPTION 'MARKETROUTE_R5_COMPANY_NOT_IN_CAMPAIGN_SCOPE'; END IF;
  IF (SELECT count(*) FROM public.marketroute_r5_universe_v1(p_organisation_id,p_company_id))>128 THEN RAISE EXCEPTION 'MARKETROUTE_R5_RELATIONSHIP_UNIVERSE_LIMIT_EXCEEDED'; END IF;
  SELECT COALESCE(jsonb_object_agg(r.id::text,r.claim_id::text ORDER BY r.id::text),'{}'::jsonb) INTO v_result
  FROM public.commercial_relationships r WHERE r.id IN (SELECT relationship_id FROM public.marketroute_r5_universe_v1(p_organisation_id,p_company_id));
  RETURN v_result;
END; $$;

CREATE OR REPLACE FUNCTION public.marketroute_r5_access_points_v1(p_organisation_id uuid,p_company_id uuid,p_reference_time timestamptz,p_snapshot_map jsonb)
RETURNS TABLE(access_point_id uuid,requires_contact_truth boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
  WITH RECURSIVE target AS (SELECT public.marketroute_r5_target_node_v1(p_company_id) node_id),
  positive AS (
    SELECT r.*,t.direction,t.route_traversable,ts.truth_state
    FROM public.commercial_relationships r
    JOIN public.commercial_relationship_type_registry t ON t.relation_type=r.relation_type
    JOIN public.truth_claim_snapshots ts ON ts.id=(p_snapshot_map->>r.id::text)::uuid
    WHERE r.id IN (SELECT relationship_id FROM public.marketroute_r5_universe_v1(p_organisation_id,p_company_id))
      AND t.route_traversable=true AND ts.truth_state IN ('KNOWN','SUPPORTED')
      AND ts.reference_time=p_reference_time AND ts.next_revalidation_at>p_reference_time
  ), walk(node_id,depth,visited,requires_contact_truth) AS (
    SELECT node_id,0,ARRAY[node_id]::uuid[],false FROM target WHERE node_id IS NOT NULL
    UNION ALL
    SELECT CASE WHEN p.direction='DIRECTED' THEN p.to_node_id WHEN p.from_node_id=w.node_id THEN p.to_node_id ELSE p.from_node_id END,
           w.depth+1,
           w.visited || CASE WHEN p.direction='DIRECTED' THEN p.to_node_id WHEN p.from_node_id=w.node_id THEN p.to_node_id ELSE p.from_node_id END,
           w.requires_contact_truth OR n.node_kind='PERSON'
    FROM walk w JOIN positive p ON ((p.direction='DIRECTED' AND p.from_node_id=w.node_id) OR (p.direction='UNDIRECTED' AND (p.from_node_id=w.node_id OR p.to_node_id=w.node_id)))
    JOIN public.commercial_graph_nodes n ON n.id=CASE WHEN p.direction='DIRECTED' THEN p.to_node_id WHEN p.from_node_id=w.node_id THEN p.to_node_id ELSE p.from_node_id END
    WHERE w.depth<4 AND NOT (n.id=ANY(w.visited))
  )
  SELECT n.id,
    bool_and(w.requires_contact_truth OR n.access_point_kind IN ('PERSONAL_EMAIL','LINKEDIN','PERSONAL_PHONE'))
  FROM walk w JOIN public.commercial_graph_nodes n ON n.id=w.node_id
  WHERE n.node_kind='ACCESS_POINT'
  GROUP BY n.id;
$$;

CREATE OR REPLACE FUNCTION public.marketroute_get_r5_context_v1(p_organisation_id uuid,p_campaign_id uuid,p_company_id uuid,p_reference_time timestamptz,p_relationship_truth_snapshot_map jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_r4 record; v_target uuid; v_universe text; v_expected_keys text[]; v_given_keys text[]; v_nodes jsonb; v_relationships jsonb; v_objective text;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF (SELECT count(*) FROM public.marketroute_r5_universe_v1(p_organisation_id,p_company_id))>128 THEN RAISE EXCEPTION 'MARKETROUTE_R5_RELATIONSHIP_UNIVERSE_LIMIT_EXCEEDED'; END IF;
  IF jsonb_typeof(p_relationship_truth_snapshot_map)<>'object' THEN RAISE EXCEPTION 'MARKETROUTE_R5_SNAPSHOT_MAP_INVALID'; END IF;
  SELECT r.authority_record_id,a.authority_fingerprint,a.valid_until,a.decision_code INTO v_r4
  FROM public.commercial_reality_r4_records r JOIN public.authority_records a ON a.id=r.authority_record_id
  WHERE r.organisation_id=p_organisation_id AND r.campaign_id=p_campaign_id AND r.company_id=p_company_id AND public.marketroute_r4_authority_current_v1(a.id,p_reference_time)
  ORDER BY r.created_at DESC,r.id DESC LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_R5_CURRENT_R4_REQUIRED'; END IF;
  v_target:=public.marketroute_r5_target_node_v1(p_company_id); IF v_target IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_R5_TARGET_NODE_REQUIRED'; END IF;
  SELECT array_agg(relationship_id::text ORDER BY relationship_id::text) INTO v_expected_keys FROM public.marketroute_r5_universe_v1(p_organisation_id,p_company_id);
  SELECT array_agg(key ORDER BY key) INTO v_given_keys FROM jsonb_object_keys(p_relationship_truth_snapshot_map) key;
  IF COALESCE(v_expected_keys,'{}'::text[]) IS DISTINCT FROM COALESCE(v_given_keys,'{}'::text[]) THEN RAISE EXCEPTION 'MARKETROUTE_R5_RELATIONSHIP_UNIVERSE_OMISSION'; END IF;
  IF EXISTS(
    SELECT 1 FROM public.commercial_relationships r
    JOIN LATERAL (SELECT (p_relationship_truth_snapshot_map->>r.id::text)::uuid sid) x ON true
    LEFT JOIN public.truth_claim_snapshots ts ON ts.id=x.sid
    WHERE r.id IN (SELECT relationship_id FROM public.marketroute_r5_universe_v1(p_organisation_id,p_company_id))
      AND (ts.id IS NULL OR ts.claim_id<>r.claim_id OR ts.subject_type<>'RELATIONSHIP' OR ts.subject_id<>r.id OR ts.reference_time<>p_reference_time OR ts.input_fingerprint<>public.marketroute_truth_context_fingerprint_v1(r.claim_id,p_reference_time))
  ) THEN RAISE EXCEPTION 'MARKETROUTE_R5_RELATIONSHIP_TRUTH_SNAPSHOT_INVALID'; END IF;
  v_universe:=public.marketroute_r5_universe_fingerprint_v1(p_organisation_id,p_company_id);
  SELECT s.objective_key INTO v_objective FROM public.campaign_seller_context_selections s WHERE s.organisation_id=p_organisation_id AND s.campaign_id=p_campaign_id ORDER BY s.created_at DESC,s.id DESC LIMIT 1;
  WITH ids AS (
    SELECT v_target id UNION SELECT r.from_node_id FROM public.commercial_relationships r WHERE r.id IN (SELECT relationship_id FROM public.marketroute_r5_universe_v1(p_organisation_id,p_company_id)) UNION SELECT r.to_node_id FROM public.commercial_relationships r WHERE r.id IN (SELECT relationship_id FROM public.marketroute_r5_universe_v1(p_organisation_id,p_company_id))
  ) SELECT COALESCE(jsonb_agg(jsonb_build_object('nodeId',n.id,'nodeFingerprint',n.node_fingerprint,'nodeKind',n.node_kind,'label',n.label,'accessPointKind',n.access_point_kind,'canonicalValue',n.canonical_value) ORDER BY n.node_fingerprint),'[]'::jsonb) INTO v_nodes FROM public.commercial_graph_nodes n WHERE n.id IN(SELECT id FROM ids);
  SELECT COALESCE(jsonb_agg(jsonb_build_object('relationshipId',r.id,'relationshipFingerprint',r.relationship_fingerprint,'relationType',r.relation_type,'edgeClass',t.edge_class,'direction',t.direction,'routeTraversable',t.route_traversable,'fromNodeId',r.from_node_id,'toNodeId',r.to_node_id,'claimId',r.claim_id,'truth',jsonb_build_object('snapshotId',ts.id,'snapshotFingerprint',ts.snapshot_fingerprint,'truthState',ts.truth_state,'nextRevalidationAt',ts.next_revalidation_at)) ORDER BY r.relationship_fingerprint),'[]'::jsonb) INTO v_relationships
  FROM public.commercial_relationships r JOIN public.commercial_relationship_type_registry t ON t.relation_type=r.relation_type JOIN public.truth_claim_snapshots ts ON ts.id=(p_relationship_truth_snapshot_map->>r.id::text)::uuid
  WHERE r.id IN(SELECT relationship_id FROM public.marketroute_r5_universe_v1(p_organisation_id,p_company_id));
  RETURN jsonb_build_object('organisationId',p_organisation_id,'campaignId',p_campaign_id,'companyId',p_company_id,'referenceTime',p_reference_time,'objectiveKey',v_objective,'targetNodeId',v_target,'relationshipUniverseFingerprint',v_universe,'nodes',v_nodes,'relationships',v_relationships,'parentR4',jsonb_build_object('authorityRecordId',v_r4.authority_record_id,'authorityFingerprint',v_r4.authority_fingerprint,'decisionCode',v_r4.decision_code,'validUntil',v_r4.valid_until,'current',true));
END; $$;

CREATE OR REPLACE FUNCTION public.marketroute_r5_expected_decision_v1(p_r4_decision text,p_organisation_id uuid,p_company_id uuid,p_reference_time timestamptz,p_snapshot_map jsonb)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT CASE WHEN p_r4_decision<>'COMMERCIAL_CANDIDATE' THEN 'ROUTE_NOT_APPLICABLE'
              WHEN EXISTS(SELECT 1 FROM public.marketroute_r5_access_points_v1(p_organisation_id,p_company_id,p_reference_time,p_snapshot_map)) THEN 'ROUTE_STRUCTURALLY_OPEN'
              ELSE 'ROUTE_RESEARCH_REQUIRED' END;
$$;


CREATE OR REPLACE FUNCTION public.marketroute_r5_path_valid_v1(
  p_organisation_id uuid,p_company_id uuid,p_reference_time timestamptz,p_snapshot_map jsonb,p_path jsonb
) RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_nodes text[]; v_rels text[]; v_target uuid; v_terminal public.commercial_graph_nodes%ROWTYPE; v_rel public.commercial_relationships%ROWTYPE; v_type public.commercial_relationship_type_registry%ROWTYPE; v_ts public.truth_claim_snapshots%ROWTYPE; v_from uuid; v_to uuid; v_i integer; v_all_known boolean:=true; v_contact boolean:=false; v_node public.commercial_graph_nodes%ROWTYPE; v_canon jsonb; v_expected_state text; v_expected_knowledge text;
BEGIN
  IF jsonb_typeof(p_path)<>'object' OR jsonb_typeof(p_path->'nodeIds')<>'array' OR jsonb_typeof(p_path->'relationshipIds')<>'array' OR jsonb_typeof(p_path->'canonicalRelations')<>'array' THEN RETURN false; END IF;
  SELECT array_agg(value ORDER BY ord) INTO v_nodes FROM jsonb_array_elements_text(p_path->'nodeIds') WITH ORDINALITY x(value,ord);
  SELECT array_agg(value ORDER BY ord) INTO v_rels FROM jsonb_array_elements_text(p_path->'relationshipIds') WITH ORDINALITY x(value,ord);
  IF COALESCE(array_length(v_nodes,1),0)<2 OR COALESCE(array_length(v_rels,1),0)<>array_length(v_nodes,1)-1 OR jsonb_array_length(p_path->'canonicalRelations')<>COALESCE(array_length(v_rels,1),0) THEN RETURN false; END IF;
  IF (SELECT count(DISTINCT value) FROM unnest(v_nodes) u(value))<>array_length(v_nodes,1) THEN RETURN false; END IF;
  v_target:=public.marketroute_r5_target_node_v1(p_company_id); IF v_nodes[1]::uuid<>v_target THEN RETURN false; END IF;
  FOR v_i IN 1..array_length(v_rels,1) LOOP
    SELECT * INTO v_rel FROM public.commercial_relationships WHERE id=v_rels[v_i]::uuid AND (tenant_scope_organisation_id IS NULL OR tenant_scope_organisation_id=p_organisation_id);
    IF NOT FOUND OR NOT (v_rel.id IN (SELECT relationship_id FROM public.marketroute_r5_universe_v1(p_organisation_id,p_company_id))) THEN RETURN false; END IF;
    SELECT * INTO v_type FROM public.commercial_relationship_type_registry WHERE relation_type=v_rel.relation_type; IF NOT FOUND OR NOT v_type.route_traversable THEN RETURN false; END IF;
    SELECT * INTO v_ts FROM public.truth_claim_snapshots WHERE id=(p_snapshot_map->>v_rel.id::text)::uuid;
    IF NOT FOUND OR v_ts.claim_id<>v_rel.claim_id OR v_ts.reference_time<>p_reference_time OR v_ts.truth_state NOT IN ('KNOWN','SUPPORTED') OR v_ts.next_revalidation_at IS NULL OR v_ts.next_revalidation_at<=p_reference_time THEN RETURN false; END IF;
    v_from:=v_nodes[v_i]::uuid; v_to:=v_nodes[v_i+1]::uuid;
    IF v_type.direction='DIRECTED' THEN IF v_rel.from_node_id<>v_from OR v_rel.to_node_id<>v_to THEN RETURN false; END IF;
    ELSE IF NOT ((v_rel.from_node_id=v_from AND v_rel.to_node_id=v_to) OR (v_rel.from_node_id=v_to AND v_rel.to_node_id=v_from)) THEN RETURN false; END IF; END IF;
    IF v_ts.truth_state<>'KNOWN' THEN v_all_known:=false; END IF;
    SELECT * INTO v_node FROM public.commercial_graph_nodes WHERE id=v_to; IF NOT FOUND THEN RETURN false; END IF;
    IF v_node.node_kind='PERSON' THEN v_contact:=true; END IF;
    v_canon:=p_path->'canonicalRelations'->(v_i-1);
    IF v_canon->>'relationType' IS DISTINCT FROM v_rel.relation_type OR v_canon->>'edgeClass' IS DISTINCT FROM v_type.edge_class OR v_canon->>'direction' IS DISTINCT FROM v_type.direction THEN RETURN false; END IF;
  END LOOP;
  SELECT * INTO v_terminal FROM public.commercial_graph_nodes WHERE id=v_nodes[array_length(v_nodes,1)]::uuid;
  IF NOT FOUND OR v_terminal.node_kind<>'ACCESS_POINT' OR p_path->>'terminalAccessPointId' IS DISTINCT FROM v_terminal.id::text THEN RETURN false; END IF;
  IF v_terminal.access_point_kind IN ('PERSONAL_EMAIL','LINKEDIN','PERSONAL_PHONE') THEN v_contact:=true; END IF;
  v_expected_state:=CASE WHEN v_contact THEN 'CONTACT_TRUTH_REQUIRED' ELSE 'ORGANISATIONAL_OPEN' END;
  v_expected_knowledge:=CASE WHEN v_all_known THEN 'KNOWN' ELSE 'SUPPORTED' END;
  IF p_path->>'pathState' IS DISTINCT FROM v_expected_state OR p_path->>'knowledgeState' IS DISTINCT FROM v_expected_knowledge THEN RETURN false; END IF;
  IF COALESCE(p_path->>'pathFingerprint','') !~ '^[a-f0-9]{64}$' THEN RETURN false; END IF;
  RETURN true;
EXCEPTION WHEN OTHERS THEN RETURN false;
END; $$;

CREATE OR REPLACE FUNCTION public.marketroute_persist_route_authority_r5_v1(
  p_organisation_id uuid,p_campaign_id uuid,p_company_id uuid,p_reference_time timestamptz,p_parent_authority_fingerprint text,p_relationship_universe_fingerprint text,p_relationship_truth_snapshot_map jsonb,p_engine_version text,p_semantics_version text,p_decision_code text,p_paths_json jsonb,p_open_access_point_ids jsonb,p_contact_truth_required_access_point_ids jsonb,p_distinct_access_point_count integer,p_next_revalidation_at timestamptz
) RETURNS TABLE(r5_record_id uuid,authority_record_id uuid,reasoning_run_id uuid,reasoning_artifact_id uuid,input_fingerprint text,authority_fingerprint text,valid_until timestamptz,deduplicated boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_context jsonb; v_r4_id uuid; v_r4_fp text; v_r4_decision text; v_r4_until timestamptz; v_universe text; v_expected_decision text; v_expected_open jsonb; v_expected_contact jsonb; v_expected_next timestamptz; v_valid_until timestamptz; v_input_fp text; v_payload jsonb; v_run uuid; v_art uuid; v_auth uuid; v_r5 uuid; v_auth_fp text; v_art_fp text; v_previous uuid; v_existing public.route_authority_r5_records%ROWTYPE;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF abs(extract(epoch FROM (now()-p_reference_time)))>600 THEN RAISE EXCEPTION 'MARKETROUTE_R5_REFERENCE_TIME_TOO_OLD_FOR_AUTHORITY'; END IF;
  IF p_engine_version<>'MRV2-R5-ENGINE-1.0.0' OR p_semantics_version<>'MRV2-R5-SEMANTICS-1.0.0' THEN RAISE EXCEPTION 'MARKETROUTE_R5_VERSION_MISMATCH'; END IF;
  IF jsonb_typeof(p_paths_json)<>'array' OR jsonb_typeof(p_open_access_point_ids)<>'array' OR jsonb_typeof(p_contact_truth_required_access_point_ids)<>'array' THEN RAISE EXCEPTION 'MARKETROUTE_R5_PAYLOAD_SHAPE_INVALID'; END IF;
  IF jsonb_array_length(p_paths_json)>512 THEN RAISE EXCEPTION 'MARKETROUTE_R5_PATH_LIMIT_EXCEEDED'; END IF;
  v_context:=public.marketroute_get_r5_context_v1(p_organisation_id,p_campaign_id,p_company_id,p_reference_time,p_relationship_truth_snapshot_map);
  v_r4_id:=(v_context#>>'{parentR4,authorityRecordId}')::uuid; v_r4_fp:=v_context#>>'{parentR4,authorityFingerprint}'; v_r4_decision:=v_context#>>'{parentR4,decisionCode}'; v_r4_until:=(v_context#>>'{parentR4,validUntil}')::timestamptz; v_universe:=v_context->>'relationshipUniverseFingerprint';
  IF p_parent_authority_fingerprint IS DISTINCT FROM v_r4_fp THEN RAISE EXCEPTION 'MARKETROUTE_R5_PARENT_FINGERPRINT_MISMATCH'; END IF;
  IF p_relationship_universe_fingerprint IS DISTINCT FROM v_universe THEN RAISE EXCEPTION 'MARKETROUTE_R5_UNIVERSE_FINGERPRINT_MISMATCH'; END IF;
  v_expected_decision:=public.marketroute_r5_expected_decision_v1(v_r4_decision,p_organisation_id,p_company_id,p_reference_time,p_relationship_truth_snapshot_map);
  IF p_decision_code IS DISTINCT FROM v_expected_decision THEN RAISE EXCEPTION 'MARKETROUTE_R5_DECISION_MISMATCH'; END IF;
  IF v_r4_decision<>'COMMERCIAL_CANDIDATE' THEN
    v_expected_open:='[]'::jsonb; v_expected_contact:='[]'::jsonb;
  ELSE
    SELECT COALESCE(jsonb_agg(access_point_id::text ORDER BY access_point_id::text),'[]'::jsonb) INTO v_expected_open FROM public.marketroute_r5_access_points_v1(p_organisation_id,p_company_id,p_reference_time,p_relationship_truth_snapshot_map);
    SELECT COALESCE(jsonb_agg(access_point_id::text ORDER BY access_point_id::text),'[]'::jsonb) INTO v_expected_contact FROM public.marketroute_r5_access_points_v1(p_organisation_id,p_company_id,p_reference_time,p_relationship_truth_snapshot_map) WHERE requires_contact_truth;
  END IF;
  SELECT COALESCE(jsonb_agg(value ORDER BY value),'[]'::jsonb) INTO p_open_access_point_ids FROM jsonb_array_elements_text(p_open_access_point_ids) value;
  SELECT COALESCE(jsonb_agg(value ORDER BY value),'[]'::jsonb) INTO p_contact_truth_required_access_point_ids FROM jsonb_array_elements_text(p_contact_truth_required_access_point_ids) value;
  IF p_open_access_point_ids IS DISTINCT FROM v_expected_open THEN RAISE EXCEPTION 'MARKETROUTE_R5_OPEN_ACCESS_POINT_SET_MISMATCH'; END IF;
  IF p_contact_truth_required_access_point_ids IS DISTINCT FROM v_expected_contact THEN RAISE EXCEPTION 'MARKETROUTE_R5_CONTACT_REQUIRED_SET_MISMATCH'; END IF;
  IF p_distinct_access_point_count<>jsonb_array_length(v_expected_open) THEN RAISE EXCEPTION 'MARKETROUTE_R5_ACCESS_POINT_COUNT_MISMATCH'; END IF;
  SELECT LEAST(v_r4_until,p_reference_time+interval '12 hours',COALESCE(MIN(ts.next_revalidation_at),p_reference_time+interval '12 hours')) INTO v_expected_next
  FROM public.commercial_relationships cr JOIN public.truth_claim_snapshots ts ON ts.id=(p_relationship_truth_snapshot_map->>cr.id::text)::uuid
  WHERE cr.id IN(SELECT relationship_id FROM public.marketroute_r5_universe_v1(p_organisation_id,p_company_id));
  IF p_next_revalidation_at IS DISTINCT FROM v_expected_next THEN RAISE EXCEPTION 'MARKETROUTE_R5_REVALIDATION_MISMATCH'; END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_paths_json) p WHERE NOT (p ? 'pathFingerprint' AND p ? 'nodeIds' AND p ? 'relationshipIds' AND p ? 'terminalAccessPointId' AND p ? 'pathState' AND p ? 'knowledgeState' AND p ? 'canonicalRelations')) THEN RAISE EXCEPTION 'MARKETROUTE_R5_PATH_PROVENANCE_INCOMPLETE'; END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_paths_json) p WHERE NOT public.marketroute_r5_path_valid_v1(p_organisation_id,p_company_id,p_reference_time,p_relationship_truth_snapshot_map,p)) THEN RAISE EXCEPTION 'MARKETROUTE_R5_PATH_PROVENANCE_INVALID'; END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_paths_json) p WHERE (p->>'terminalAccessPointId') NOT IN (SELECT jsonb_array_elements_text(v_expected_open))) THEN RAISE EXCEPTION 'MARKETROUTE_R5_PATH_TERMINAL_NOT_OPEN'; END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements_text(v_expected_open) a WHERE NOT EXISTS(SELECT 1 FROM jsonb_array_elements(p_paths_json) p WHERE p->>'terminalAccessPointId'=a)) THEN RAISE EXCEPTION 'MARKETROUTE_R5_PATH_SET_OMITS_ACCESS_POINT'; END IF;
  v_valid_until:=v_expected_next;
  IF v_valid_until<=p_reference_time THEN RAISE EXCEPTION 'MARKETROUTE_R5_VALIDITY_INVALID'; END IF;
  v_input_fp:=encode(extensions.digest(concat_ws('|','MRV2-R5-INPUT-1.0.0',p_organisation_id::text,p_campaign_id::text,p_company_id::text,to_char(p_reference_time AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),v_r4_fp,v_universe,p_relationship_truth_snapshot_map::text),'sha256'),'hex');
  SELECT * INTO v_existing FROM public.route_authority_r5_records rr WHERE rr.organisation_id=p_organisation_id AND rr.campaign_id=p_campaign_id AND rr.company_id=p_company_id AND rr.input_fingerprint=v_input_fp ORDER BY rr.created_at DESC LIMIT 1;
  IF FOUND THEN SELECT a.id,a.reasoning_run_id,a.reasoning_artifact_id,a.authority_fingerprint,a.valid_until INTO v_auth,v_run,v_art,v_auth_fp,v_valid_until FROM public.authority_records a WHERE a.id=v_existing.authority_record_id; RETURN QUERY SELECT v_existing.id,v_auth,v_run,v_art,v_input_fp,v_auth_fp,v_valid_until,true; RETURN; END IF;
  INSERT INTO public.reasoning_runs(organisation_id,campaign_id,reasoning_kind,engine_version,input_fingerprint,status,started_at,completed_at,metadata_json) VALUES(p_organisation_id,p_campaign_id,'RELATIONSHIP_GRAPH',p_engine_version,v_input_fp,'SUCCEEDED',p_reference_time,p_reference_time,jsonb_build_object('semanticsVersion',p_semantics_version)) RETURNING id INTO v_run;
  v_payload:=jsonb_build_object('decision',p_decision_code,'parentR4AuthorityFingerprint',v_r4_fp,'relationshipUniverseFingerprint',v_universe,'relationshipTruthSnapshotMap',p_relationship_truth_snapshot_map,'paths',p_paths_json,'openAccessPointIds',v_expected_open,'contactTruthRequiredAccessPointIds',v_expected_contact,'distinctAccessPointCount',p_distinct_access_point_count,'nextRevalidationAt',v_valid_until);
  v_art_fp:=encode(extensions.digest('MRV2-R5-ARTIFACT-1.0.0|'||v_input_fp||'|'||v_payload::text,'sha256'),'hex');
  INSERT INTO public.reasoning_artifacts(reasoning_run_id,artifact_kind,subject_type,subject_id,artifact_fingerprint,payload_json,evaluated_at) VALUES(v_run,'ROUTE_AUTHORITY_R5','COMPANY',p_company_id,v_art_fp,v_payload,p_reference_time) RETURNING id INTO v_art;
  v_auth_fp:=encode(extensions.digest(concat_ws('|','MRV2-R5-AUTHORITY-1.0.0',v_input_fp,p_decision_code,p_paths_json::text,v_expected_open::text,v_expected_contact::text,to_char(v_valid_until AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"')),'sha256'),'hex');
  SELECT a.id INTO v_previous FROM public.authority_records a JOIN public.route_authority_r5_records r ON r.authority_record_id=a.id WHERE r.organisation_id=p_organisation_id AND r.campaign_id=p_campaign_id AND r.company_id=p_company_id AND NOT EXISTS(SELECT 1 FROM public.authority_events e WHERE e.authority_record_id=a.id AND e.event_type IN('SUPERSEDED','INVALIDATED','REVOKED')) ORDER BY a.created_at DESC LIMIT 1;
  PERFORM set_config('marketroute.authority_writer','marketroute.r5.relationship-graph',true);
  IF v_previous IS NOT NULL THEN INSERT INTO public.authority_events(authority_record_id,event_type,writer_key,reason_code,metadata_json,occurred_at) VALUES(v_previous,'SUPERSEDED','marketroute.r5.relationship-graph','R5_NEW_GRAPH_INPUT',jsonb_build_object('newInputFingerprint',v_input_fp),p_reference_time); END IF;
  INSERT INTO public.authority_records(organisation_id,campaign_id,reasoning_run_id,reasoning_artifact_id,authority_stage,subject_type,subject_id,decision_code,writer_key,writer_version,input_fingerprint,authority_fingerprint,parent_authority_fingerprints,payload_json,valid_from,valid_until)
  VALUES(p_organisation_id,p_campaign_id,v_run,v_art,'ROUTE_AUTHORITY','COMPANY',p_company_id,p_decision_code,'marketroute.r5.relationship-graph','1.0.0',v_input_fp,v_auth_fp,jsonb_build_array(v_r4_fp),v_payload,p_reference_time,v_valid_until) RETURNING id INTO v_auth;
  INSERT INTO public.authority_events(authority_record_id,event_type,writer_key,reason_code,metadata_json,occurred_at) VALUES(v_auth,'GRANTED','marketroute.r5.relationship-graph','R5_TRUTH_QUALIFIED_GRAPH',jsonb_build_object('decision',p_decision_code),p_reference_time);
  INSERT INTO public.route_authority_r5_records(organisation_id,campaign_id,company_id,authority_record_id,parent_r4_authority_record_id,parent_r4_authority_fingerprint,relationship_universe_fingerprint,relationship_truth_snapshot_map,engine_version,semantics_version,decision_code,paths_json,open_access_point_ids,contact_truth_required_access_point_ids,distinct_access_point_count,input_fingerprint,authority_fingerprint,reference_time,next_revalidation_at)
  VALUES(p_organisation_id,p_campaign_id,p_company_id,v_auth,v_r4_id,v_r4_fp,v_universe,p_relationship_truth_snapshot_map,p_engine_version,p_semantics_version,p_decision_code,p_paths_json,v_expected_open,v_expected_contact,p_distinct_access_point_count,v_input_fp,v_auth_fp,p_reference_time,v_valid_until) RETURNING id INTO v_r5;
  RETURN QUERY SELECT v_r5,v_auth,v_run,v_art,v_input_fp,v_auth_fp,v_valid_until,false;
END; $$;

CREATE OR REPLACE FUNCTION public.marketroute_r5_authority_current_v1(p_authority_record_id uuid,p_at timestamptz DEFAULT now())
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT EXISTS(
    SELECT 1 FROM public.authority_records a JOIN public.route_authority_r5_records r ON r.authority_record_id=a.id
    WHERE a.id=p_authority_record_id AND a.writer_key='marketroute.r5.relationship-graph' AND a.writer_version='1.0.0' AND a.authority_stage='ROUTE_AUTHORITY'
      AND a.valid_from<=p_at AND p_at<a.valid_until AND r.next_revalidation_at>p_at
      AND public.marketroute_r4_authority_current_v1(r.parent_r4_authority_record_id,p_at)
      AND r.parent_r4_authority_fingerprint=(SELECT authority_fingerprint FROM public.authority_records WHERE id=r.parent_r4_authority_record_id)
      AND r.relationship_universe_fingerprint=public.marketroute_r5_universe_fingerprint_v1(r.organisation_id,r.company_id)
      AND NOT EXISTS(
        SELECT 1 FROM public.commercial_relationships cr
        JOIN public.truth_claim_snapshots ts ON ts.id=(r.relationship_truth_snapshot_map->>cr.id::text)::uuid
        WHERE cr.id IN(SELECT relationship_id FROM public.marketroute_r5_universe_v1(r.organisation_id,r.company_id))
          AND (ts.input_fingerprint<>public.marketroute_truth_context_fingerprint_v1(cr.claim_id,ts.reference_time) OR (ts.next_revalidation_at IS NOT NULL AND ts.next_revalidation_at<=p_at))
      )
      AND NOT EXISTS(SELECT 1 FROM public.authority_events e WHERE e.authority_record_id=a.id AND e.event_type IN('SUPERSEDED','INVALIDATED','REVOKED') AND e.occurred_at<=p_at)
  );
$$;

CREATE OR REPLACE VIEW public.current_route_authority_r5 AS
SELECT r.*,a.valid_from,a.valid_until,a.payload_json AS authority_payload_json FROM public.route_authority_r5_records r JOIN public.authority_records a ON a.id=r.authority_record_id WHERE public.marketroute_r5_authority_current_v1(a.id,now());

ALTER TABLE public.commercial_relationship_type_registry ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.commercial_graph_nodes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.commercial_relationships ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.route_authority_r5_records ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.commercial_relationship_type_registry,public.commercial_graph_nodes,public.commercial_relationships,public.route_authority_r5_records,public.current_route_authority_r5 FROM anon,authenticated,service_role;
GRANT SELECT ON public.commercial_relationship_type_registry,public.commercial_graph_nodes,public.commercial_relationships,public.route_authority_r5_records,public.current_route_authority_r5 TO service_role;

REVOKE ALL ON FUNCTION public.marketroute_graph_node_fingerprint_v1(uuid,text,uuid,uuid,text,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_prevent_relationship_claim_supersession_v1() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_r5_target_node_v1(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_r5_universe_v1(uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_r5_universe_fingerprint_v1(uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_r5_access_points_v1(uuid,uuid,timestamptz,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_r5_expected_decision_v1(text,uuid,uuid,timestamptz,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_ensure_graph_node_v1(uuid,text,uuid,uuid,text,text,text,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_ensure_commercial_relationship_v1(uuid,text,uuid,uuid,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_link_relationship_evidence_v1(uuid,uuid,text,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_get_r5_relationship_claim_ids_v1(uuid,uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_get_r5_context_v1(uuid,uuid,uuid,timestamptz,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_r5_path_valid_v1(uuid,uuid,timestamptz,jsonb,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_persist_route_authority_r5_v1(uuid,uuid,uuid,timestamptz,text,text,jsonb,text,text,text,jsonb,jsonb,jsonb,integer,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_r5_authority_current_v1(uuid,timestamptz) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.marketroute_ensure_graph_node_v1(uuid,text,uuid,uuid,text,text,text,text,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_ensure_commercial_relationship_v1(uuid,text,uuid,uuid,text,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_link_relationship_evidence_v1(uuid,uuid,text,text,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_get_r5_relationship_claim_ids_v1(uuid,uuid,uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_get_r5_context_v1(uuid,uuid,uuid,timestamptz,jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_persist_route_authority_r5_v1(uuid,uuid,uuid,timestamptz,text,text,jsonb,text,text,text,jsonb,jsonb,jsonb,integer,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_r5_authority_current_v1(uuid,timestamptz) TO service_role;

INSERT INTO public.marketroute_schema_releases(release_key,build_number,constitution_version,metadata_json)
VALUES('MARKETROUTE_V2_BUILD7_RELATIONSHIP_GRAPH_R5',7,'MRV2-CONSTITUTION-1.0.0',jsonb_build_object('migration','0010_relationship_truth_and_route_authority_r5.sql','authority_writers',2,'authority_writer','marketroute.r5.relationship-graph','relationship_truth_required',true,'numeric_route_authority',false,'contact_truth_deferred_to_build8',true))
ON CONFLICT(release_key) DO NOTHING;

NOTIFY pgrst,'reload schema';
COMMIT;
