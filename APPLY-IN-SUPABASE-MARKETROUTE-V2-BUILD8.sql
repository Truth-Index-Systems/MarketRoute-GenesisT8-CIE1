BEGIN;

-- MarketRoute V2 Build 8: Contact Truth / R6
-- R5 proves route structure. R6 proves named-person identity, current employment, current role and exact channel ownership.

INSERT INTO public.authority_writer_registry(writer_key,authority_stage,writer_version,enabled,registered_by_build,metadata_json)
VALUES('marketroute.r6.contact-truth','CONTACT_AUTHORITY','1.0.0',true,8,jsonb_build_object('engine_version','MRV2-R6-ENGINE-1.0.0','semantics_version','MRV2-R6-SEMANTICS-1.0.0','numeric_authority',false,'named_contact_truth_required',true,'organisational_routes_do_not_require_person',true))
ON CONFLICT(writer_key) DO NOTHING;
DO $writer_contract$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.authority_writer_registry WHERE writer_key='marketroute.r6.contact-truth' AND authority_stage='CONTACT_AUTHORITY' AND writer_version='1.0.0' AND enabled=true AND registered_by_build=8 AND metadata_json->>'engine_version'='MRV2-R6-ENGINE-1.0.0') THEN RAISE EXCEPTION 'MARKETROUTE_R6_WRITER_REGISTRY_COLLISION'; END IF;
END $writer_contract$;

INSERT INTO public.truth_claim_policy_registry(policy_key,policy_version,max_age_days,known_support_family_requirement,metadata_json) VALUES
('PERSON_CURRENT_EMPLOYMENT_V1','1.0.0',180,2,jsonb_build_object('purpose','current employer relationship for contact authority')),
('PERSON_CURRENT_ROLE_V1','1.0.0',180,2,jsonb_build_object('purpose','current role at employer for contact authority')),
('CHANNEL_OWNERSHIP_CURRENT_V1','1.0.0',120,2,jsonb_build_object('purpose','current person ownership of personal contact channel'))
ON CONFLICT(policy_key) DO NOTHING;
UPDATE public.truth_claim_policy_bindings SET policy_key='PERSON_CURRENT_EMPLOYMENT_V1' WHERE subject_type='PERSON' AND claim_key='employment.current';
UPDATE public.truth_claim_policy_bindings SET policy_key='PERSON_CURRENT_ROLE_V1' WHERE subject_type='PERSON' AND claim_key='role.current';
UPDATE public.truth_claim_policy_bindings SET policy_key='CHANNEL_OWNERSHIP_CURRENT_V1' WHERE subject_type='CHANNEL' AND claim_key='ownership.current';

CREATE TABLE public.contact_authority_r6_records(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 organisation_id uuid NOT NULL REFERENCES public.organisations(id) ON DELETE RESTRICT,
 campaign_id uuid NOT NULL,
 company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
 authority_record_id uuid NOT NULL UNIQUE REFERENCES public.authority_records(id) ON DELETE RESTRICT,
 parent_r5_authority_record_id uuid NOT NULL REFERENCES public.authority_records(id) ON DELETE RESTRICT,
 parent_r5_authority_fingerprint text NOT NULL CHECK(parent_r5_authority_fingerprint ~ '^[a-f0-9]{64}$'),
 contact_claim_universe_fingerprint text NOT NULL CHECK(contact_claim_universe_fingerprint ~ '^[a-f0-9]{64}$'),
 contact_truth_snapshot_map jsonb NOT NULL CHECK(jsonb_typeof(contact_truth_snapshot_map)='object'),
 engine_version text NOT NULL,
 semantics_version text NOT NULL,
 decision_code text NOT NULL CHECK(decision_code IN ('CONTACT_AUTHORISED','CONTACT_RESEARCH_REQUIRED','CONTACT_NOT_APPLICABLE')),
 bindings_json jsonb NOT NULL CHECK(jsonb_typeof(bindings_json)='array'),
 authorised_path_fingerprints jsonb NOT NULL CHECK(jsonb_typeof(authorised_path_fingerprints)='array'),
 authorised_access_point_ids jsonb NOT NULL CHECK(jsonb_typeof(authorised_access_point_ids)='array'),
 research_required_access_point_ids jsonb NOT NULL CHECK(jsonb_typeof(research_required_access_point_ids)='array'),
 distinct_authorised_access_point_count integer NOT NULL CHECK(distinct_authorised_access_point_count>=0),
 input_fingerprint text NOT NULL CHECK(input_fingerprint ~ '^[a-f0-9]{64}$'),
 authority_fingerprint text NOT NULL CHECK(authority_fingerprint ~ '^[a-f0-9]{64}$'),
 reference_time timestamptz NOT NULL,
 next_revalidation_at timestamptz NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),
 CONSTRAINT contact_authority_r6_campaign_scope_fk FOREIGN KEY(organisation_id,campaign_id) REFERENCES public.campaigns(organisation_id,id) ON DELETE RESTRICT,
 CHECK(next_revalidation_at>reference_time)
);
CREATE INDEX contact_authority_r6_scope_idx ON public.contact_authority_r6_records(organisation_id,campaign_id,company_id,created_at DESC);
CREATE TRIGGER contact_authority_r6_records_append_only BEFORE UPDATE OR DELETE ON public.contact_authority_r6_records FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

CREATE OR REPLACE FUNCTION public.marketroute_prevent_contact_claim_supersession_v1()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_claim public.claims%ROWTYPE;
BEGIN
 SELECT * INTO v_claim FROM public.claims WHERE id=NEW.prior_claim_id;
 IF FOUND AND ((v_claim.subject_type='PERSON' AND v_claim.claim_key IN('identity.canonical_name','employment.current','role.current')) OR (v_claim.subject_type='CHANNEL' AND v_claim.claim_key='ownership.current')) THEN
   RAISE EXCEPTION 'MARKETROUTE_CANONICAL_CONTACT_CLAIM_SUPERSESSION_FORBIDDEN';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER contact_claim_supersession_guard BEFORE INSERT ON public.claim_supersessions FOR EACH ROW EXECUTE FUNCTION public.marketroute_prevent_contact_claim_supersession_v1();

CREATE OR REPLACE FUNCTION public.marketroute_r6_current_r5_record_v1(p_organisation_id uuid,p_campaign_id uuid,p_company_id uuid,p_at timestamptz)
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
 SELECT r.id FROM public.route_authority_r5_records r WHERE r.organisation_id=p_organisation_id AND r.campaign_id=p_campaign_id AND r.company_id=p_company_id AND public.marketroute_r5_authority_current_v1(r.authority_record_id,p_at) ORDER BY r.created_at DESC,r.id DESC LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.marketroute_r6_path_structure_v1(p_r5_record_id uuid)
RETURNS TABLE(path_fingerprint text,terminal_access_point_id uuid,r5_path_state text,person_id uuid,employer_company_id uuid,structurally_bindable boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
 WITH paths AS (
   SELECT p.value path FROM public.route_authority_r5_records r CROSS JOIN LATERAL jsonb_array_elements(r.paths_json) p(value) WHERE r.id=p_r5_record_id
 ), base AS (
   SELECT path->>'pathFingerprint' path_fingerprint,(path->>'terminalAccessPointId')::uuid terminal_access_point_id,path->>'pathState' r5_path_state,path
   FROM paths
 ), people AS (
   SELECT b.path_fingerprint,array_agg(n.person_id ORDER BY n.id) person_ids,array_agg(n.id ORDER BY n.id) person_node_ids
   FROM base b CROSS JOIN LATERAL jsonb_array_elements_text(b.path->'nodeIds') x(node_id)
   JOIN public.commercial_graph_nodes n ON n.id=x.node_id::uuid AND n.node_kind='PERSON' GROUP BY b.path_fingerprint
 ), employers AS (
   SELECT b.path_fingerprint,array_agg(DISTINCT cn.company_id ORDER BY cn.company_id) employer_ids
   FROM base b CROSS JOIN LATERAL jsonb_array_elements_text(b.path->'relationshipIds') x(rel_id)
   JOIN public.commercial_relationships cr ON cr.id=x.rel_id::uuid AND cr.relation_type='employs'
   JOIN public.commercial_graph_nodes cn ON cn.id=cr.from_node_id AND cn.node_kind='COMPANY'
   JOIN public.commercial_graph_nodes pn ON pn.id=cr.to_node_id AND pn.node_kind='PERSON'
   GROUP BY b.path_fingerprint
 )
 SELECT b.path_fingerprint,b.terminal_access_point_id,b.r5_path_state,
   CASE WHEN cardinality(COALESCE(p.person_ids,'{}'::uuid[]))=1 THEN p.person_ids[1] ELSE NULL END,
   CASE WHEN cardinality(COALESCE(e.employer_ids,'{}'::uuid[]))=1 THEN e.employer_ids[1] ELSE NULL END,
   CASE WHEN b.r5_path_state='ORGANISATIONAL_OPEN' THEN true ELSE cardinality(COALESCE(p.person_ids,'{}'::uuid[]))=1 AND cardinality(COALESCE(e.employer_ids,'{}'::uuid[]))=1 END
 FROM base b LEFT JOIN people p USING(path_fingerprint) LEFT JOIN employers e USING(path_fingerprint);
$$;

CREATE OR REPLACE FUNCTION public.marketroute_r6_claim_universe_v1(p_organisation_id uuid,p_r5_record_id uuid)
RETURNS TABLE(claim_id uuid) LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
 WITH req AS (SELECT * FROM public.marketroute_r6_path_structure_v1(p_r5_record_id) WHERE r5_path_state='CONTACT_TRUTH_REQUIRED' AND structurally_bindable),
 scoped_claims AS (
   SELECT c.* FROM public.claims c WHERE (c.tenant_scope_organisation_id IS NULL OR c.tenant_scope_organisation_id=p_organisation_id) AND NOT EXISTS(SELECT 1 FROM public.claim_supersessions s WHERE s.prior_claim_id=c.id)
 )
 SELECT DISTINCT c.id FROM req r JOIN scoped_claims c ON
   (c.subject_type='PERSON' AND c.subject_id=r.person_id AND c.claim_key='identity.canonical_name') OR
   (c.subject_type='PERSON' AND c.subject_id=r.person_id AND c.claim_key='employment.current' AND c.object_json->>'companyId'=r.employer_company_id::text) OR
   (c.subject_type='PERSON' AND c.subject_id=r.person_id AND c.claim_key='role.current' AND c.object_json->>'companyId'=r.employer_company_id::text) OR
   (c.subject_type='CHANNEL' AND c.subject_id=r.terminal_access_point_id AND c.claim_key='ownership.current')
 ORDER BY c.id;
$$;

CREATE OR REPLACE FUNCTION public.marketroute_r6_claim_universe_fingerprint_v1(p_organisation_id uuid,p_r5_record_id uuid)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_claims text; v_people text; v_parent text;
BEGIN
 SELECT a.authority_fingerprint INTO v_parent FROM public.route_authority_r5_records r JOIN public.authority_records a ON a.id=r.authority_record_id WHERE r.id=p_r5_record_id;
 IF v_parent IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_R6_PARENT_R5_NOT_FOUND'; END IF;
 SELECT COALESCE(string_agg(c.claim_fingerprint,',' ORDER BY c.claim_fingerprint),'') INTO v_claims FROM public.claims c WHERE c.id IN(SELECT claim_id FROM public.marketroute_r6_claim_universe_v1(p_organisation_id,p_r5_record_id));
 SELECT COALESCE(string_agg(p.id::text||':'||p.lifecycle_state,',' ORDER BY p.id::text),'') INTO v_people FROM public.people p WHERE p.id IN(SELECT DISTINCT person_id FROM public.marketroute_r6_path_structure_v1(p_r5_record_id) WHERE person_id IS NOT NULL);
 RETURN encode(extensions.digest(concat_ws('|','MRV2-R6-CLAIM-UNIVERSE-1.0.0',p_organisation_id::text,p_r5_record_id::text,v_parent,v_claims,v_people),'sha256'),'hex');
END $$;

CREATE OR REPLACE FUNCTION public.marketroute_get_r6_contact_claim_ids_v1(p_organisation_id uuid,p_campaign_id uuid,p_company_id uuid,p_reference_time timestamptz)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_r5 uuid; v_result jsonb;
BEGIN
 PERFORM public.marketroute_require_service_role();
 v_r5:=public.marketroute_r6_current_r5_record_v1(p_organisation_id,p_campaign_id,p_company_id,p_reference_time);
 IF v_r5 IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_R6_CURRENT_R5_REQUIRED'; END IF;
 SELECT COALESCE(jsonb_object_agg(claim_id::text,claim_id::text ORDER BY claim_id::text),'{}'::jsonb) INTO v_result FROM public.marketroute_r6_claim_universe_v1(p_organisation_id,v_r5);
 RETURN v_result;
END $$;

CREATE OR REPLACE FUNCTION public.marketroute_r6_claim_refs_v1(p_organisation_id uuid,p_person_id uuid,p_employer_company_id uuid,p_access_point_id uuid,p_kind text,p_snapshot_map jsonb)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
 WITH c AS (
   SELECT c.* FROM public.claims c WHERE (c.tenant_scope_organisation_id IS NULL OR c.tenant_scope_organisation_id=p_organisation_id) AND NOT EXISTS(SELECT 1 FROM public.claim_supersessions s WHERE s.prior_claim_id=c.id) AND (
     (p_kind='IDENTITY' AND c.subject_type='PERSON' AND c.subject_id=p_person_id AND c.claim_key='identity.canonical_name') OR
     (p_kind='EMPLOYMENT' AND c.subject_type='PERSON' AND c.subject_id=p_person_id AND c.claim_key='employment.current' AND c.object_json->>'companyId'=p_employer_company_id::text) OR
     (p_kind='ROLE' AND c.subject_type='PERSON' AND c.subject_id=p_person_id AND c.claim_key='role.current' AND c.object_json->>'companyId'=p_employer_company_id::text) OR
     (p_kind='CHANNEL' AND c.subject_type='CHANNEL' AND c.subject_id=p_access_point_id AND c.claim_key='ownership.current')
   )
 )
 SELECT COALESCE(jsonb_agg(jsonb_build_object('claimId',c.id,'snapshotId',ts.id,'snapshotFingerprint',ts.snapshot_fingerprint,'truthState',ts.truth_state,'nextRevalidationAt',ts.next_revalidation_at,'roleTitle',c.object_json->>'roleTitle','canonicalValueText',c.canonical_value_text,'objectJson',c.object_json) ORDER BY c.claim_fingerprint),'[]'::jsonb)
 FROM c JOIN public.truth_claim_snapshots ts ON ts.id=(p_snapshot_map->>c.id::text)::uuid;
$$;

CREATE OR REPLACE FUNCTION public.marketroute_get_r6_context_v1(p_organisation_id uuid,p_campaign_id uuid,p_company_id uuid,p_reference_time timestamptz,p_contact_truth_snapshot_map jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_r5_id uuid; v_r5 public.route_authority_r5_records%ROWTYPE; v_auth public.authority_records%ROWTYPE; v_expected text[]; v_given text[]; v_universe text; v_paths jsonb;
BEGIN
 PERFORM public.marketroute_require_service_role();
 IF jsonb_typeof(p_contact_truth_snapshot_map)<>'object' THEN RAISE EXCEPTION 'MARKETROUTE_R6_SNAPSHOT_MAP_INVALID'; END IF;
 v_r5_id:=public.marketroute_r6_current_r5_record_v1(p_organisation_id,p_campaign_id,p_company_id,p_reference_time); IF v_r5_id IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_R6_CURRENT_R5_REQUIRED'; END IF;
 SELECT * INTO v_r5 FROM public.route_authority_r5_records WHERE id=v_r5_id; SELECT * INTO v_auth FROM public.authority_records WHERE id=v_r5.authority_record_id;
 SELECT array_agg(claim_id::text ORDER BY claim_id::text) INTO v_expected FROM public.marketroute_r6_claim_universe_v1(p_organisation_id,v_r5_id); SELECT array_agg(key ORDER BY key) INTO v_given FROM jsonb_object_keys(p_contact_truth_snapshot_map) key;
 IF COALESCE(v_expected,'{}'::text[]) IS DISTINCT FROM COALESCE(v_given,'{}'::text[]) THEN RAISE EXCEPTION 'MARKETROUTE_R6_CONTACT_CLAIM_UNIVERSE_OMISSION'; END IF;
 IF EXISTS(SELECT 1 FROM public.claims c LEFT JOIN public.truth_claim_snapshots ts ON ts.id=(p_contact_truth_snapshot_map->>c.id::text)::uuid WHERE c.id IN(SELECT claim_id FROM public.marketroute_r6_claim_universe_v1(p_organisation_id,v_r5_id)) AND (ts.id IS NULL OR ts.claim_id<>c.id OR ts.reference_time<>p_reference_time OR ts.input_fingerprint<>public.marketroute_truth_context_fingerprint_v1(c.id,p_reference_time))) THEN RAISE EXCEPTION 'MARKETROUTE_R6_CONTACT_TRUTH_SNAPSHOT_INVALID'; END IF;
 v_universe:=public.marketroute_r6_claim_universe_fingerprint_v1(p_organisation_id,v_r5_id);
 SELECT COALESCE(jsonb_agg(jsonb_build_object(
   'pathFingerprint',s.path_fingerprint,'terminalAccessPointId',s.terminal_access_point_id,'r5PathState',s.r5_path_state,
   'personId',s.person_id,'expectedPersonName',CASE WHEN s.person_id IS NULL THEN NULL ELSE COALESCE(p.canonical_name,p.display_name) END,
   'personLifecycleState',p.lifecycle_state,'employerCompanyId',s.employer_company_id,'accessPointKind',ap.access_point_kind,'accessPointValue',ap.canonical_value,
   'identityClaims',CASE WHEN s.person_id IS NULL THEN '[]'::jsonb ELSE public.marketroute_r6_claim_refs_v1(p_organisation_id,s.person_id,s.employer_company_id,s.terminal_access_point_id,'IDENTITY',p_contact_truth_snapshot_map) END,
   'employmentClaims',CASE WHEN s.person_id IS NULL THEN '[]'::jsonb ELSE public.marketroute_r6_claim_refs_v1(p_organisation_id,s.person_id,s.employer_company_id,s.terminal_access_point_id,'EMPLOYMENT',p_contact_truth_snapshot_map) END,
   'roleClaims',CASE WHEN s.person_id IS NULL THEN '[]'::jsonb ELSE public.marketroute_r6_claim_refs_v1(p_organisation_id,s.person_id,s.employer_company_id,s.terminal_access_point_id,'ROLE',p_contact_truth_snapshot_map) END,
   'channelOwnershipClaims',CASE WHEN s.person_id IS NULL THEN '[]'::jsonb ELSE public.marketroute_r6_claim_refs_v1(p_organisation_id,s.person_id,s.employer_company_id,s.terminal_access_point_id,'CHANNEL',p_contact_truth_snapshot_map) END
 ) ORDER BY s.path_fingerprint),'[]'::jsonb) INTO v_paths
 FROM public.marketroute_r6_path_structure_v1(v_r5_id) s LEFT JOIN public.people p ON p.id=s.person_id LEFT JOIN public.commercial_graph_nodes ap ON ap.id=s.terminal_access_point_id;
 RETURN jsonb_build_object('organisationId',p_organisation_id,'campaignId',p_campaign_id,'companyId',p_company_id,'referenceTime',p_reference_time,'contactClaimUniverseFingerprint',v_universe,'paths',v_paths,'parentR5',jsonb_build_object('authorityRecordId',v_auth.id,'authorityFingerprint',v_auth.authority_fingerprint,'decisionCode',v_auth.decision_code,'validUntil',v_auth.valid_until,'current',true));
END $$;

CREATE OR REPLACE FUNCTION public.marketroute_r6_exact_group_qualified_v1(p_claims jsonb,p_reference_time timestamptz,p_object_key text,p_expected text,p_block_competing boolean DEFAULT false)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
 SELECT CASE WHEN p_claims IS NULL OR jsonb_typeof(p_claims)<>'array' THEN false
   WHEN EXISTS(SELECT 1 FROM jsonb_array_elements(p_claims) c WHERE lower(btrim(COALESCE(c->'objectJson'->>p_object_key,'')))=lower(btrim(COALESCE(p_expected,''))) AND c->>'truthState'='CONTRADICTED') THEN false
   WHEN p_block_competing AND EXISTS(SELECT 1 FROM jsonb_array_elements(p_claims) c WHERE lower(btrim(COALESCE(c->'objectJson'->>p_object_key,'')))<>lower(btrim(COALESCE(p_expected,''))) AND c->>'truthState' IN('KNOWN','SUPPORTED') AND NULLIF(c->>'nextRevalidationAt','')::timestamptz>p_reference_time) THEN false
   ELSE EXISTS(SELECT 1 FROM jsonb_array_elements(p_claims) c WHERE lower(btrim(COALESCE(c->'objectJson'->>p_object_key,'')))=lower(btrim(COALESCE(p_expected,''))) AND c->>'truthState' IN('KNOWN','SUPPORTED') AND NULLIF(c->>'nextRevalidationAt','')::timestamptz>p_reference_time) END;
$$;

CREATE OR REPLACE FUNCTION public.marketroute_r6_role_qualified_v1(p_claims jsonb,p_reference_time timestamptz,p_employer_company_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
 WITH matching AS (SELECT c FROM jsonb_array_elements(COALESCE(p_claims,'[]'::jsonb)) c WHERE c->'objectJson'->>'companyId'=p_employer_company_id::text AND length(btrim(COALESCE(c->>'roleTitle','')))>0), roles AS (SELECT lower(btrim(c->>'roleTitle')) role FROM matching GROUP BY lower(btrim(c->>'roleTitle')))
 SELECT EXISTS(SELECT 1 FROM roles r WHERE EXISTS(SELECT 1 FROM matching m WHERE lower(btrim(m.c->>'roleTitle'))=r.role AND m.c->>'truthState' IN('KNOWN','SUPPORTED') AND NULLIF(m.c->>'nextRevalidationAt','')::timestamptz>p_reference_time) AND NOT EXISTS(SELECT 1 FROM matching m WHERE lower(btrim(m.c->>'roleTitle'))=r.role AND m.c->>'truthState'='CONTRADICTED'));
$$;

CREATE OR REPLACE FUNCTION public.marketroute_r6_expected_v1(p_context jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE p jsonb; v_bindings jsonb:='[]'::jsonb; v_auth_paths jsonb:='[]'::jsonb; v_auth_access jsonb:='[]'::jsonb; v_research jsonb:='[]'::jsonb; v_ref timestamptz:=(p_context->>'referenceTime')::timestamptz; v_ok boolean; v_reason text; v_mode text; v_state text; v_decision text;
BEGIN
 IF NOT COALESCE((p_context#>>'{parentR5,current}')::boolean,false) OR p_context#>>'{parentR5,decisionCode}'<>'ROUTE_STRUCTURALLY_OPEN' THEN RETURN jsonb_build_object('decision','CONTACT_NOT_APPLICABLE','bindings','[]'::jsonb,'authorisedPathFingerprints','[]'::jsonb,'authorisedAccessPointIds','[]'::jsonb,'researchRequiredAccessPointIds','[]'::jsonb,'distinctAuthorisedAccessPointCount',0); END IF;
 FOR p IN SELECT value FROM jsonb_array_elements(p_context->'paths') LOOP
   IF p->>'r5PathState'='ORGANISATIONAL_OPEN' THEN v_ok:=true;v_mode:='ORGANISATIONAL_ROUTE';v_reason:='ORGANISATIONAL_ACCESS_REQUIRES_NO_PERSON_TRUTH';
   ELSE
     v_ok:=true;v_mode:='NAMED_CONTACT';v_reason:='CONTACT_TRUTH_QUALIFIED';
     IF NULLIF(p->>'personId','') IS NULL OR NULLIF(p->>'employerCompanyId','') IS NULL THEN v_ok:=false;v_reason:='PERSON_OR_EMPLOYER_NOT_STRUCTURALLY_IDENTIFIED';
     ELSIF p->>'personLifecycleState'<>'ACTIVE' THEN v_ok:=false;v_reason:='PERSON_CANONICAL_RECORD_NOT_ACTIVE';
     ELSIF NOT public.marketroute_r6_exact_group_qualified_v1(p->'identityClaims',v_ref,'name',p->>'expectedPersonName',true) THEN v_ok:=false;v_reason:='IDENTITY_NOT_TRUTH_QUALIFIED';
     ELSIF NOT public.marketroute_r6_exact_group_qualified_v1(p->'employmentClaims',v_ref,'companyId',p->>'employerCompanyId',false) THEN v_ok:=false;v_reason:='CURRENT_EMPLOYMENT_NOT_TRUTH_QUALIFIED';
     ELSIF NOT public.marketroute_r6_role_qualified_v1(p->'roleClaims',v_ref,(p->>'employerCompanyId')::uuid) THEN v_ok:=false;v_reason:='CURRENT_ROLE_NOT_TRUTH_QUALIFIED';
     ELSIF NOT public.marketroute_r6_exact_group_qualified_v1(p->'channelOwnershipClaims',v_ref,'personId',p->>'personId',true) THEN v_ok:=false;v_reason:='CHANNEL_OWNERSHIP_NOT_TRUTH_QUALIFIED'; END IF;
   END IF;
   v_state:=CASE WHEN v_ok THEN 'AUTHORISED' ELSE 'CONTACT_TRUTH_REQUIRED' END;
   v_bindings:=v_bindings||jsonb_build_array(jsonb_build_object('pathFingerprint',p->>'pathFingerprint','terminalAccessPointId',p->>'terminalAccessPointId','mode',v_mode,'authorityState',v_state,'personId',NULLIF(p->>'personId',''),'employerCompanyId',NULLIF(p->>'employerCompanyId',''),'reasonCode',v_reason));
   IF v_ok THEN v_auth_paths:=v_auth_paths||jsonb_build_array(p->>'pathFingerprint');v_auth_access:=v_auth_access||jsonb_build_array(p->>'terminalAccessPointId'); ELSE v_research:=v_research||jsonb_build_array(p->>'terminalAccessPointId'); END IF;
 END LOOP;
 SELECT COALESCE(jsonb_agg(DISTINCT value ORDER BY value),'[]'::jsonb) INTO v_auth_paths FROM jsonb_array_elements_text(v_auth_paths) value;
 SELECT COALESCE(jsonb_agg(DISTINCT value ORDER BY value),'[]'::jsonb) INTO v_auth_access FROM jsonb_array_elements_text(v_auth_access) value;
 SELECT COALESCE(jsonb_agg(DISTINCT value ORDER BY value),'[]'::jsonb) INTO v_research FROM jsonb_array_elements_text(v_research) value;
 SELECT COALESCE(jsonb_agg(value ORDER BY value->>'pathFingerprint'),'[]'::jsonb) INTO v_bindings FROM jsonb_array_elements(v_bindings) value;
 v_decision:=CASE WHEN jsonb_array_length(v_auth_paths)>0 THEN 'CONTACT_AUTHORISED' ELSE 'CONTACT_RESEARCH_REQUIRED' END;
 RETURN jsonb_build_object('decision',v_decision,'bindings',v_bindings,'authorisedPathFingerprints',v_auth_paths,'authorisedAccessPointIds',v_auth_access,'researchRequiredAccessPointIds',v_research,'distinctAuthorisedAccessPointCount',jsonb_array_length(v_auth_access));
END $$;

CREATE OR REPLACE FUNCTION public.marketroute_persist_contact_authority_r6_v1(
 p_organisation_id uuid,p_campaign_id uuid,p_company_id uuid,p_reference_time timestamptz,p_parent_authority_fingerprint text,p_contact_claim_universe_fingerprint text,p_contact_truth_snapshot_map jsonb,p_engine_version text,p_semantics_version text,p_decision_code text,p_bindings_json jsonb,p_authorised_path_fingerprints jsonb,p_authorised_access_point_ids jsonb,p_research_required_access_point_ids jsonb,p_distinct_authorised_access_point_count integer,p_next_revalidation_at timestamptz
) RETURNS TABLE(r6_record_id uuid,authority_record_id uuid,reasoning_run_id uuid,reasoning_artifact_id uuid,input_fingerprint text,authority_fingerprint text,valid_until timestamptz,deduplicated boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_context jsonb; v_expected jsonb; v_r5_id uuid; v_r5 public.route_authority_r5_records%ROWTYPE; v_r5_auth public.authority_records%ROWTYPE; v_universe text; v_expected_next timestamptz; v_input text; v_artfp text; v_authfp text; v_run uuid; v_art uuid; v_auth uuid; v_r6 uuid; v_prev uuid; v_payload jsonb; v_existing public.contact_authority_r6_records%ROWTYPE;
BEGIN
 PERFORM public.marketroute_require_service_role();
 IF p_reference_time>now()+interval '5 minutes' THEN RAISE EXCEPTION 'MARKETROUTE_R6_REFERENCE_TIME_IN_FUTURE'; END IF; IF p_reference_time<now()-interval '15 minutes' THEN RAISE EXCEPTION 'MARKETROUTE_R6_REFERENCE_TIME_TOO_OLD_FOR_AUTHORITY'; END IF;
 IF p_engine_version<>'MRV2-R6-ENGINE-1.0.0' OR p_semantics_version<>'MRV2-R6-SEMANTICS-1.0.0' THEN RAISE EXCEPTION 'MARKETROUTE_R6_VERSION_MISMATCH'; END IF;
 IF jsonb_typeof(p_bindings_json)<>'array' OR jsonb_typeof(p_authorised_path_fingerprints)<>'array' OR jsonb_typeof(p_authorised_access_point_ids)<>'array' OR jsonb_typeof(p_research_required_access_point_ids)<>'array' THEN RAISE EXCEPTION 'MARKETROUTE_R6_PAYLOAD_SHAPE_INVALID'; END IF;
 v_context:=public.marketroute_get_r6_context_v1(p_organisation_id,p_campaign_id,p_company_id,p_reference_time,p_contact_truth_snapshot_map); v_expected:=public.marketroute_r6_expected_v1(v_context);
 v_r5_id:=(v_context#>>'{parentR5,authorityRecordId}')::uuid; SELECT * INTO v_r5 FROM public.route_authority_r5_records WHERE authority_record_id=v_r5_id; IF NOT FOUND THEN SELECT * INTO v_r5 FROM public.route_authority_r5_records WHERE id=public.marketroute_r6_current_r5_record_v1(p_organisation_id,p_campaign_id,p_company_id,p_reference_time); END IF; SELECT * INTO v_r5_auth FROM public.authority_records WHERE id=v_r5.authority_record_id;
 v_universe:=v_context->>'contactClaimUniverseFingerprint'; IF p_parent_authority_fingerprint IS DISTINCT FROM v_r5_auth.authority_fingerprint THEN RAISE EXCEPTION 'MARKETROUTE_R6_PARENT_FINGERPRINT_MISMATCH'; END IF; IF p_contact_claim_universe_fingerprint IS DISTINCT FROM v_universe THEN RAISE EXCEPTION 'MARKETROUTE_R6_CONTACT_CLAIM_UNIVERSE_FINGERPRINT_MISMATCH'; END IF;
 SELECT COALESCE(jsonb_agg(value ORDER BY value->>'pathFingerprint'),'[]'::jsonb) INTO p_bindings_json FROM jsonb_array_elements(p_bindings_json) value;
 SELECT COALESCE(jsonb_agg(DISTINCT value ORDER BY value),'[]'::jsonb) INTO p_authorised_path_fingerprints FROM jsonb_array_elements_text(p_authorised_path_fingerprints) value; SELECT COALESCE(jsonb_agg(DISTINCT value ORDER BY value),'[]'::jsonb) INTO p_authorised_access_point_ids FROM jsonb_array_elements_text(p_authorised_access_point_ids) value; SELECT COALESCE(jsonb_agg(DISTINCT value ORDER BY value),'[]'::jsonb) INTO p_research_required_access_point_ids FROM jsonb_array_elements_text(p_research_required_access_point_ids) value;
 IF p_decision_code IS DISTINCT FROM v_expected->>'decision' THEN RAISE EXCEPTION 'MARKETROUTE_R6_DECISION_MISMATCH'; END IF; IF p_bindings_json IS DISTINCT FROM v_expected->'bindings' THEN RAISE EXCEPTION 'MARKETROUTE_R6_BINDINGS_MISMATCH'; END IF; IF p_authorised_path_fingerprints IS DISTINCT FROM v_expected->'authorisedPathFingerprints' THEN RAISE EXCEPTION 'MARKETROUTE_R6_AUTHORISED_PATH_SET_MISMATCH'; END IF; IF p_authorised_access_point_ids IS DISTINCT FROM v_expected->'authorisedAccessPointIds' THEN RAISE EXCEPTION 'MARKETROUTE_R6_AUTHORISED_ACCESS_POINT_SET_MISMATCH'; END IF; IF p_research_required_access_point_ids IS DISTINCT FROM v_expected->'researchRequiredAccessPointIds' THEN RAISE EXCEPTION 'MARKETROUTE_R6_RESEARCH_REQUIRED_SET_MISMATCH'; END IF; IF p_distinct_authorised_access_point_count<>(v_expected->>'distinctAuthorisedAccessPointCount')::integer THEN RAISE EXCEPTION 'MARKETROUTE_R6_ACCESS_POINT_COUNT_MISMATCH'; END IF;
 SELECT LEAST(v_r5_auth.valid_until,p_reference_time+interval '8 hours',COALESCE(MIN(ts.next_revalidation_at),p_reference_time+interval '8 hours')) INTO v_expected_next FROM public.truth_claim_snapshots ts WHERE ts.id IN(SELECT value::uuid FROM jsonb_each_text(p_contact_truth_snapshot_map));
 IF v_expected_next IS NULL THEN v_expected_next:=LEAST(v_r5_auth.valid_until,p_reference_time+interval '8 hours'); END IF; IF p_next_revalidation_at IS DISTINCT FROM v_expected_next THEN RAISE EXCEPTION 'MARKETROUTE_R6_REVALIDATION_MISMATCH'; END IF; IF v_expected_next<=p_reference_time THEN RAISE EXCEPTION 'MARKETROUTE_R6_VALIDITY_INVALID'; END IF;
 v_input:=encode(extensions.digest(concat_ws('|','MRV2-R6-INPUT-1.0.0',p_organisation_id::text,p_campaign_id::text,p_company_id::text,to_char(p_reference_time AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),v_r5_auth.authority_fingerprint,v_universe,p_contact_truth_snapshot_map::text),'sha256'),'hex');
 SELECT * INTO v_existing FROM public.contact_authority_r6_records r WHERE r.organisation_id=p_organisation_id AND r.campaign_id=p_campaign_id AND r.company_id=p_company_id AND r.input_fingerprint=v_input ORDER BY r.created_at DESC LIMIT 1; IF FOUND THEN SELECT a.id,a.reasoning_run_id,a.reasoning_artifact_id,a.authority_fingerprint,a.valid_until INTO v_auth,v_run,v_art,v_authfp,v_expected_next FROM public.authority_records a WHERE a.id=v_existing.authority_record_id; RETURN QUERY SELECT v_existing.id,v_auth,v_run,v_art,v_input,v_authfp,v_expected_next,true; RETURN; END IF;
 INSERT INTO public.reasoning_runs(organisation_id,campaign_id,reasoning_kind,engine_version,input_fingerprint,status,started_at,completed_at,metadata_json) VALUES(p_organisation_id,p_campaign_id,'CONTACT_TRUTH_AUTHORITY',p_engine_version,v_input,'SUCCEEDED',p_reference_time,p_reference_time,jsonb_build_object('semanticsVersion',p_semantics_version)) RETURNING id INTO v_run;
 v_payload:=jsonb_build_object('decision',p_decision_code,'parentR5AuthorityFingerprint',v_r5_auth.authority_fingerprint,'contactClaimUniverseFingerprint',v_universe,'contactTruthSnapshotMap',p_contact_truth_snapshot_map,'bindings',p_bindings_json,'authorisedPathFingerprints',p_authorised_path_fingerprints,'authorisedAccessPointIds',p_authorised_access_point_ids,'researchRequiredAccessPointIds',p_research_required_access_point_ids,'distinctAuthorisedAccessPointCount',p_distinct_authorised_access_point_count,'nextRevalidationAt',v_expected_next);
 v_artfp:=encode(extensions.digest('MRV2-R6-ARTIFACT-1.0.0|'||v_input||'|'||v_payload::text,'sha256'),'hex'); INSERT INTO public.reasoning_artifacts(reasoning_run_id,artifact_kind,subject_type,subject_id,artifact_fingerprint,payload_json,evaluated_at) VALUES(v_run,'CONTACT_AUTHORITY_R6','COMPANY',p_company_id,v_artfp,v_payload,p_reference_time) RETURNING id INTO v_art;
 v_authfp:=encode(extensions.digest(concat_ws('|','MRV2-R6-AUTHORITY-1.0.0',v_input,p_decision_code,p_bindings_json::text,p_authorised_path_fingerprints::text,p_authorised_access_point_ids::text,to_char(v_expected_next AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"')),'sha256'),'hex');
 SELECT a.id INTO v_prev FROM public.authority_records a JOIN public.contact_authority_r6_records r ON r.authority_record_id=a.id WHERE r.organisation_id=p_organisation_id AND r.campaign_id=p_campaign_id AND r.company_id=p_company_id AND NOT EXISTS(SELECT 1 FROM public.authority_events e WHERE e.authority_record_id=a.id AND e.event_type IN('SUPERSEDED','INVALIDATED','REVOKED')) ORDER BY a.created_at DESC LIMIT 1;
 PERFORM set_config('marketroute.authority_writer','marketroute.r6.contact-truth',true); IF v_prev IS NOT NULL THEN INSERT INTO public.authority_events(authority_record_id,event_type,writer_key,reason_code,metadata_json,occurred_at) VALUES(v_prev,'SUPERSEDED','marketroute.r6.contact-truth','R6_NEW_CONTACT_TRUTH_INPUT',jsonb_build_object('newInputFingerprint',v_input),p_reference_time); END IF;
 INSERT INTO public.authority_records(organisation_id,campaign_id,reasoning_run_id,reasoning_artifact_id,authority_stage,subject_type,subject_id,decision_code,writer_key,writer_version,input_fingerprint,authority_fingerprint,parent_authority_fingerprints,payload_json,valid_from,valid_until) VALUES(p_organisation_id,p_campaign_id,v_run,v_art,'CONTACT_AUTHORITY','COMPANY',p_company_id,p_decision_code,'marketroute.r6.contact-truth','1.0.0',v_input,v_authfp,jsonb_build_array(v_r5_auth.authority_fingerprint),v_payload,p_reference_time,v_expected_next) RETURNING id INTO v_auth;
 INSERT INTO public.authority_events(authority_record_id,event_type,writer_key,reason_code,metadata_json,occurred_at) VALUES(v_auth,'GRANTED','marketroute.r6.contact-truth','R6_CONTACT_TRUTH_QUALIFIED',jsonb_build_object('decision',p_decision_code),p_reference_time);
 INSERT INTO public.contact_authority_r6_records(organisation_id,campaign_id,company_id,authority_record_id,parent_r5_authority_record_id,parent_r5_authority_fingerprint,contact_claim_universe_fingerprint,contact_truth_snapshot_map,engine_version,semantics_version,decision_code,bindings_json,authorised_path_fingerprints,authorised_access_point_ids,research_required_access_point_ids,distinct_authorised_access_point_count,input_fingerprint,authority_fingerprint,reference_time,next_revalidation_at) VALUES(p_organisation_id,p_campaign_id,p_company_id,v_auth,v_r5.authority_record_id,v_r5_auth.authority_fingerprint,v_universe,p_contact_truth_snapshot_map,p_engine_version,p_semantics_version,p_decision_code,p_bindings_json,p_authorised_path_fingerprints,p_authorised_access_point_ids,p_research_required_access_point_ids,p_distinct_authorised_access_point_count,v_input,v_authfp,p_reference_time,v_expected_next) RETURNING id INTO v_r6;
 RETURN QUERY SELECT v_r6,v_auth,v_run,v_art,v_input,v_authfp,v_expected_next,false;
END $$;

CREATE OR REPLACE FUNCTION public.marketroute_r6_authority_current_v1(p_authority_record_id uuid,p_at timestamptz DEFAULT now())
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
 SELECT EXISTS(SELECT 1 FROM public.authority_records a JOIN public.contact_authority_r6_records r ON r.authority_record_id=a.id WHERE a.id=p_authority_record_id AND a.writer_key='marketroute.r6.contact-truth' AND a.writer_version='1.0.0' AND a.authority_stage='CONTACT_AUTHORITY' AND a.valid_from<=p_at AND p_at<a.valid_until AND r.next_revalidation_at>p_at AND public.marketroute_r5_authority_current_v1(r.parent_r5_authority_record_id,p_at) AND r.parent_r5_authority_fingerprint=(SELECT authority_fingerprint FROM public.authority_records WHERE id=r.parent_r5_authority_record_id) AND r.contact_claim_universe_fingerprint=public.marketroute_r6_claim_universe_fingerprint_v1(r.organisation_id,(SELECT id FROM public.route_authority_r5_records WHERE authority_record_id=r.parent_r5_authority_record_id)) AND NOT EXISTS(SELECT 1 FROM public.claims c JOIN public.truth_claim_snapshots ts ON ts.id=(r.contact_truth_snapshot_map->>c.id::text)::uuid WHERE c.id IN(SELECT claim_id FROM public.marketroute_r6_claim_universe_v1(r.organisation_id,(SELECT id FROM public.route_authority_r5_records WHERE authority_record_id=r.parent_r5_authority_record_id))) AND (ts.input_fingerprint<>public.marketroute_truth_context_fingerprint_v1(c.id,ts.reference_time) OR (ts.next_revalidation_at IS NOT NULL AND ts.next_revalidation_at<=p_at))) AND NOT EXISTS(SELECT 1 FROM public.authority_events e WHERE e.authority_record_id=a.id AND e.event_type IN('SUPERSEDED','INVALIDATED','REVOKED') AND e.occurred_at<=p_at));
$$;

CREATE OR REPLACE VIEW public.current_contact_authority_r6 AS SELECT r.*,a.valid_from,a.valid_until,a.payload_json AS authority_payload_json FROM public.contact_authority_r6_records r JOIN public.authority_records a ON a.id=r.authority_record_id WHERE public.marketroute_r6_authority_current_v1(a.id,now());

ALTER TABLE public.contact_authority_r6_records ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.contact_authority_r6_records,public.current_contact_authority_r6 FROM anon,authenticated,service_role;
GRANT SELECT ON public.contact_authority_r6_records,public.current_contact_authority_r6 TO service_role;

REVOKE ALL ON FUNCTION public.marketroute_prevent_contact_claim_supersession_v1() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_r6_current_r5_record_v1(uuid,uuid,uuid,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_r6_path_structure_v1(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_r6_claim_universe_v1(uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_r6_claim_universe_fingerprint_v1(uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_r6_claim_refs_v1(uuid,uuid,uuid,uuid,text,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_r6_exact_group_qualified_v1(jsonb,timestamptz,text,text,boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_r6_role_qualified_v1(jsonb,timestamptz,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_r6_expected_v1(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_get_r6_contact_claim_ids_v1(uuid,uuid,uuid,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_get_r6_context_v1(uuid,uuid,uuid,timestamptz,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_persist_contact_authority_r6_v1(uuid,uuid,uuid,timestamptz,text,text,jsonb,text,text,text,jsonb,jsonb,jsonb,jsonb,integer,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_r6_authority_current_v1(uuid,timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.marketroute_get_r6_contact_claim_ids_v1(uuid,uuid,uuid,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_get_r6_context_v1(uuid,uuid,uuid,timestamptz,jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_persist_contact_authority_r6_v1(uuid,uuid,uuid,timestamptz,text,text,jsonb,text,text,text,jsonb,jsonb,jsonb,jsonb,integer,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_r6_authority_current_v1(uuid,timestamptz) TO service_role;

INSERT INTO public.marketroute_schema_releases(release_key,build_number,constitution_version,metadata_json) VALUES('MARKETROUTE_V2_BUILD8_CONTACT_TRUTH_R6',8,'MRV2-CONSTITUTION-1.0.0',jsonb_build_object('migration','0011_contact_truth_and_authority_r6.sql','authority_writers',3,'authority_writer','marketroute.r6.contact-truth','numeric_contact_authority',false,'organisational_routes_without_person',true,'contact_claims_truth_qualified',true)) ON CONFLICT(release_key) DO NOTHING;
NOTIFY pgrst,'reload schema';
COMMIT;
