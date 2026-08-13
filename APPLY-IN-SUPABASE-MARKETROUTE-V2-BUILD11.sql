BEGIN;

-- MarketRoute V2 Build 11: Opportunity Engine
-- Opportunity is a product-layer projection of current R4/R5/R6 authority, never a fourth authority writer.

CREATE TABLE public.opportunity_sync_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id uuid NOT NULL UNIQUE,
  organisation_id uuid NOT NULL REFERENCES public.organisations(id) ON DELETE RESTRICT,
  campaign_id uuid NOT NULL,
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  opportunity_id uuid REFERENCES public.opportunities(id) ON DELETE RESTRICT,
  outcome_code text NOT NULL CHECK (outcome_code IN ('NOT_MATERIALISED','MATERIALISED_REVIEWABLE','BECAME_REVIEWABLE','BECAME_RESEARCHING','UNCHANGED','FOUNDER_RESEARCH_HOLD')),
  prior_workflow_state text CHECK (prior_workflow_state IS NULL OR prior_workflow_state IN ('RESEARCHING','REVIEWABLE','APPROVED','REJECTED','ENGAGED','ARCHIVED')),
  resulting_workflow_state text CHECK (resulting_workflow_state IS NULL OR resulting_workflow_state IN ('RESEARCHING','REVIEWABLE','APPROVED','REJECTED','ENGAGED','ARCHIVED')),
  authority_envelope_json jsonb NOT NULL CHECK (jsonb_typeof(authority_envelope_json)='object'),
  authority_envelope_fingerprint text NOT NULL CHECK (authority_envelope_fingerprint ~ '^[a-f0-9]{64}$'),
  occurred_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT opportunity_sync_events_campaign_scope_fk FOREIGN KEY(organisation_id,campaign_id) REFERENCES public.campaigns(organisation_id,id) ON DELETE RESTRICT,
  CONSTRAINT opportunity_sync_events_opportunity_scope_fk FOREIGN KEY(opportunity_id,organisation_id) REFERENCES public.opportunities(id,organisation_id) ON DELETE RESTRICT
);
CREATE INDEX opportunity_sync_events_scope_time_idx ON public.opportunity_sync_events(organisation_id,campaign_id,company_id,occurred_at DESC);
CREATE TRIGGER opportunity_sync_events_append_only BEFORE UPDATE OR DELETE ON public.opportunity_sync_events FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

CREATE OR REPLACE FUNCTION public.marketroute_opportunity_disposition_v1(p_lifecycle_state text)
RETURNS text LANGUAGE sql IMMUTABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
 SELECT CASE
  WHEN p_lifecycle_state='AUTHORITY_READY' THEN 'ACTIONABLE'
  WHEN p_lifecycle_state='NOT_ADMISSIBLE' THEN 'NOT_ADMISSIBLE'
  WHEN p_lifecycle_state IN('ROUTE_NOT_APPLICABLE','CONTACT_NOT_APPLICABLE') THEN 'NOT_APPLICABLE'
  WHEN p_lifecycle_state IN('R4_REVALIDATION_REQUIRED','R5_REVALIDATION_REQUIRED','R6_REVALIDATION_REQUIRED') THEN 'REVALIDATION_REQUIRED'
  WHEN p_lifecycle_state IN('COMMERCIAL_RESEARCH_REQUIRED','ROUTE_RESEARCH_REQUIRED','CONTACT_RESEARCH_REQUIRED') THEN 'RESEARCH_REQUIRED'
  ELSE NULL
 END;
$$;

CREATE OR REPLACE FUNCTION public.marketroute_opportunity_research_pressure_v1(p_lifecycle_state text)
RETURNS text LANGUAGE sql IMMUTABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
 SELECT CASE
  WHEN p_lifecycle_state IN('R4_REVALIDATION_REQUIRED','COMMERCIAL_RESEARCH_REQUIRED') THEN 'R4'
  WHEN p_lifecycle_state IN('R5_REVALIDATION_REQUIRED','ROUTE_RESEARCH_REQUIRED') THEN 'R5'
  WHEN p_lifecycle_state IN('R6_REVALIDATION_REQUIRED','CONTACT_RESEARCH_REQUIRED') THEN 'R6'
  ELSE 'NONE'
 END;
$$;

CREATE OR REPLACE FUNCTION public.marketroute_opportunity_profile_v1(
  p_organisation_id uuid,p_campaign_id uuid,p_company_id uuid,p_at timestamptz DEFAULT now()
)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
  v_company public.companies%ROWTYPE; v_opp public.opportunities%ROWTYPE; v_env jsonb;
  v_r4 public.commercial_reality_r4_records%ROWTYPE; v_r5 public.route_authority_r5_records%ROWTYPE; v_r6 public.contact_authority_r6_records%ROWTYPE;
  v_truth public.truth_entity_snapshots%ROWTYPE; v_ready boolean; v_state text; v_workflow text; v_struct int:=0; v_auth int:=0;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF p_at IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_OPPORTUNITY_PROFILE_TIME_REQUIRED'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.campaigns c WHERE c.id=p_campaign_id AND c.organisation_id=p_organisation_id) THEN RAISE EXCEPTION 'MARKETROUTE_OPPORTUNITY_PROFILE_CAMPAIGN_SCOPE_MISMATCH'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.organisation_company_scopes s WHERE s.organisation_id=p_organisation_id AND s.campaign_id=p_campaign_id AND s.company_id=p_company_id AND s.scope_kind='CAMPAIGN') THEN RAISE EXCEPTION 'MARKETROUTE_OPPORTUNITY_PROFILE_COMPANY_NOT_IN_CAMPAIGN'; END IF;
  SELECT * INTO v_company FROM public.companies WHERE id=p_company_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_OPPORTUNITY_PROFILE_COMPANY_NOT_FOUND'; END IF;
  SELECT * INTO v_opp FROM public.opportunities WHERE organisation_id=p_organisation_id AND campaign_id=p_campaign_id AND company_id=p_company_id LIMIT 1;
  v_workflow:=CASE WHEN v_opp.id IS NULL THEN NULL ELSE v_opp.workflow_state END;
  v_env:=public.marketroute_authority_envelope_v1(p_organisation_id,p_campaign_id,p_company_id,p_at);
  v_ready:=COALESCE((v_env->>'authorityReady')::boolean,false); v_state:=v_env->>'lifecycleState';
  IF public.marketroute_opportunity_disposition_v1(v_state) IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_OPPORTUNITY_LIFECYCLE_STATE_UNKNOWN'; END IF;
  IF NULLIF(v_env->'r4'->>'authorityRecordId','') IS NOT NULL THEN
    SELECT r.* INTO v_r4 FROM public.commercial_reality_r4_records r WHERE r.authority_record_id=(v_env->'r4'->>'authorityRecordId')::uuid;
    IF v_r4.id IS NOT NULL THEN SELECT * INTO v_truth FROM public.truth_entity_snapshots WHERE id=v_r4.target_truth_entity_snapshot_id; END IF;
  END IF;
  IF NULLIF(v_env->'r5'->>'authorityRecordId','') IS NOT NULL THEN SELECT r.* INTO v_r5 FROM public.route_authority_r5_records r WHERE r.authority_record_id=(v_env->'r5'->>'authorityRecordId')::uuid; END IF;
  IF NULLIF(v_env->'r6'->>'authorityRecordId','') IS NOT NULL THEN SELECT r.* INTO v_r6 FROM public.contact_authority_r6_records r WHERE r.authority_record_id=(v_env->'r6'->>'authorityRecordId')::uuid; END IF;
  v_struct:=COALESCE(v_r5.distinct_access_point_count,0); v_auth:=COALESCE(v_r6.distinct_authorised_access_point_count,0);
  IF v_auth>v_struct THEN RAISE EXCEPTION 'MARKETROUTE_OPPORTUNITY_AUTHORISED_ROUTE_COUNT_EXCEEDS_STRUCTURE'; END IF;
  IF v_ready AND (COALESCE(v_r4.decision_code,'')<>'COMMERCIAL_CANDIDATE' OR COALESCE(v_r5.decision_code,'')<>'ROUTE_STRUCTURALLY_OPEN' OR COALESCE(v_r6.decision_code,'')<>'CONTACT_AUTHORISED' OR v_struct<1 OR v_auth<1 OR v_truth.id IS NULL) THEN RAISE EXCEPTION 'MARKETROUTE_OPPORTUNITY_ACTIONABLE_PROFILE_INCONSISTENT'; END IF;
  RETURN jsonb_build_object(
    'engineVersion','MRV2-OPPORTUNITY-ENGINE-1.0.0','semanticsVersion','MRV2-OPPORTUNITY-SEMANTICS-1.0.0',
    'organisationId',p_organisation_id::text,'campaignId',p_campaign_id::text,'companyId',p_company_id::text,
    'opportunityId',v_opp.id,'companyName',v_company.canonical_name,'canonicalDomain',v_company.canonical_domain,'evaluatedAt',to_jsonb(p_at),
    'workflowState',v_workflow,'lifecycleState',v_state,'disposition',public.marketroute_opportunity_disposition_v1(v_state),
    'researchPressure',public.marketroute_opportunity_research_pressure_v1(v_state),'authorityReady',v_ready,
    'reviewableNow',COALESCE(v_workflow='REVIEWABLE' AND v_ready,false),
    'executableNow',CASE WHEN v_opp.id IS NULL THEN false ELSE public.marketroute_opportunity_executable_now_v1(v_opp.id,p_at) END,
    'reasonCode',v_env->>'reasonCode','nextRevalidationAt',v_env->'nextRevalidationAt',
    'commercialReality',v_env->'r4'->>'decision','routeAuthority',v_env->'r5'->>'decision','contactAuthority',v_env->'r6'->>'decision',
    'truth',jsonb_build_object(
      'entityState',v_truth.entity_state,'currentCoverage',v_truth.current_coverage,'evidenceSufficiency',v_truth.evidence_sufficiency,
      'freshnessCoverage',v_truth.freshness_coverage,'coherence',v_truth.coherence,'truthIndex',v_truth.truth_index,
      'probabilityState',CASE WHEN v_truth.id IS NULL THEN NULL ELSE v_truth.probability_state END
    ),
    'structurallyOpenAccessPointCount',v_struct,'authorisedAccessPointCount',v_auth,
    'routeRedundancy',CASE WHEN v_auth=0 THEN 'NONE' WHEN v_auth=1 THEN 'SINGLE' ELSE 'MULTIPLE' END,
    'authorityEnvelope',v_env
  );
END $$;

CREATE OR REPLACE FUNCTION public.marketroute_sync_opportunity_v1(
  p_organisation_id uuid,p_campaign_id uuid,p_company_id uuid,p_request_id uuid,p_at timestamptz DEFAULT now()
)
RETURNS TABLE(opportunity_id uuid,outcome_code text,prior_workflow_state text,resulting_workflow_state text,authority_envelope_fingerprint text,reviewable_now boolean,deduplicated boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
  v_campaign public.campaigns%ROWTYPE; v_opp public.opportunities%ROWTYPE; v_existing public.opportunity_sync_events%ROWTYPE;
  v_env jsonb; v_fp text; v_ready boolean; v_prior text; v_result text; v_outcome text; v_hold boolean:=false; v_event_id uuid;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF p_request_id IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_OPPORTUNITY_SYNC_REQUEST_ID_REQUIRED'; END IF;
  SELECT * INTO v_existing FROM public.opportunity_sync_events WHERE request_id=p_request_id LIMIT 1;
  IF FOUND THEN
    IF v_existing.organisation_id IS DISTINCT FROM p_organisation_id OR v_existing.campaign_id IS DISTINCT FROM p_campaign_id OR v_existing.company_id IS DISTINCT FROM p_company_id THEN RAISE EXCEPTION 'MARKETROUTE_OPPORTUNITY_SYNC_IDEMPOTENCY_COLLISION'; END IF;
    RETURN QUERY SELECT v_existing.opportunity_id,v_existing.outcome_code,v_existing.prior_workflow_state,v_existing.resulting_workflow_state,v_existing.authority_envelope_fingerprint,
      COALESCE(v_existing.resulting_workflow_state='REVIEWABLE' AND (v_existing.authority_envelope_json->>'authorityReady')::boolean,false),true;
    RETURN;
  END IF;
  IF p_at IS NULL OR abs(extract(epoch FROM(now()-p_at)))>300 THEN RAISE EXCEPTION 'MARKETROUTE_OPPORTUNITY_SYNC_TIME_NOT_CURRENT'; END IF;
  SELECT * INTO v_campaign FROM public.campaigns WHERE id=p_campaign_id AND organisation_id=p_organisation_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_OPPORTUNITY_SYNC_CAMPAIGN_SCOPE_MISMATCH'; END IF;
  IF v_campaign.workflow_state<>'ACTIVE' THEN RAISE EXCEPTION 'MARKETROUTE_OPPORTUNITY_SYNC_CAMPAIGN_NOT_ACTIVE'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.organisation_company_scopes s WHERE s.organisation_id=p_organisation_id AND s.campaign_id=p_campaign_id AND s.company_id=p_company_id AND s.scope_kind='CAMPAIGN') THEN RAISE EXCEPTION 'MARKETROUTE_OPPORTUNITY_SYNC_COMPANY_NOT_IN_CAMPAIGN'; END IF;
  v_env:=public.marketroute_authority_envelope_v1(p_organisation_id,p_campaign_id,p_company_id,p_at); v_fp:=public.marketroute_authority_envelope_fingerprint_v1(v_env); v_ready:=COALESCE((v_env->>'authorityReady')::boolean,false);
  SELECT * INTO v_opp FROM public.opportunities WHERE organisation_id=p_organisation_id AND campaign_id=p_campaign_id AND company_id=p_company_id FOR UPDATE;
  IF NOT FOUND THEN
    IF NOT v_ready THEN
      INSERT INTO public.opportunity_sync_events(request_id,organisation_id,campaign_id,company_id,opportunity_id,outcome_code,prior_workflow_state,resulting_workflow_state,authority_envelope_json,authority_envelope_fingerprint,occurred_at)
      VALUES(p_request_id,p_organisation_id,p_campaign_id,p_company_id,NULL,'NOT_MATERIALISED',NULL,NULL,v_env,v_fp,p_at);
      RETURN QUERY SELECT NULL::uuid,'NOT_MATERIALISED'::text,NULL::text,NULL::text,v_fp,false,false; RETURN;
    END IF;
    INSERT INTO public.opportunities(organisation_id,campaign_id,company_id,workflow_state,created_at,updated_at) VALUES(p_organisation_id,p_campaign_id,p_company_id,'RESEARCHING',p_at,p_at) RETURNING * INTO v_opp;
    v_prior:='RESEARCHING'; v_result:='REVIEWABLE'; v_outcome:='MATERIALISED_REVIEWABLE';
    UPDATE public.opportunities SET workflow_state=v_result,updated_at=p_at WHERE id=v_opp.id;
    INSERT INTO public.opportunity_workflow_events(opportunity_id,organisation_id,event_type,prior_workflow_state,resulting_workflow_state,actor_user_id,request_id,reason_code,authority_envelope_json,authority_envelope_fingerprint,occurred_at)
    VALUES(v_opp.id,p_organisation_id,'SYSTEM_REVIEWABILITY',v_prior,v_result,NULL,p_request_id,'AUTHORITY_READY_MATERIALISED',v_env,v_fp,p_at) RETURNING id INTO v_event_id;
  ELSE
    v_prior:=v_opp.workflow_state; v_result:=v_prior; v_outcome:='UNCHANGED';
    IF v_prior='REVIEWABLE' AND NOT v_ready THEN v_result:='RESEARCHING';v_outcome:='BECAME_RESEARCHING';
    ELSIF v_prior='RESEARCHING' AND v_ready THEN
      SELECT EXISTS(
        SELECT 1 FROM public.opportunity_workflow_events e
        WHERE e.opportunity_id=v_opp.id AND e.reason_code='FOUNDER_RETURNED_TO_RESEARCH'
          AND e.occurred_at=(SELECT max(e2.occurred_at) FROM public.opportunity_workflow_events e2 WHERE e2.opportunity_id=v_opp.id)
          AND e.authority_envelope_fingerprint=v_fp
      ) INTO v_hold;
      IF v_hold THEN v_outcome:='FOUNDER_RESEARCH_HOLD'; ELSE v_result:='REVIEWABLE';v_outcome:='BECAME_REVIEWABLE'; END IF;
    END IF;
    IF v_result IS DISTINCT FROM v_prior THEN
      UPDATE public.opportunities SET workflow_state=v_result,updated_at=p_at WHERE id=v_opp.id;
      INSERT INTO public.opportunity_workflow_events(opportunity_id,organisation_id,event_type,prior_workflow_state,resulting_workflow_state,actor_user_id,request_id,reason_code,authority_envelope_json,authority_envelope_fingerprint,occurred_at)
      VALUES(v_opp.id,p_organisation_id,'SYSTEM_REVIEWABILITY',v_prior,v_result,NULL,p_request_id,CASE WHEN v_result='REVIEWABLE' THEN 'AUTHORITY_BECAME_READY' ELSE 'AUTHORITY_NO_LONGER_READY' END,v_env,v_fp,p_at) RETURNING id INTO v_event_id;
    END IF;
  END IF;
  INSERT INTO public.opportunity_sync_events(request_id,organisation_id,campaign_id,company_id,opportunity_id,outcome_code,prior_workflow_state,resulting_workflow_state,authority_envelope_json,authority_envelope_fingerprint,occurred_at)
  VALUES(p_request_id,p_organisation_id,p_campaign_id,p_company_id,v_opp.id,v_outcome,v_prior,v_result,v_env,v_fp,p_at);
  RETURN QUERY SELECT v_opp.id,v_outcome,v_prior,v_result,v_fp,COALESCE(v_result='REVIEWABLE' AND v_ready,false),false;
END $$;

CREATE OR REPLACE FUNCTION public.marketroute_opportunity_sync_targets_v1(p_limit integer DEFAULT 250)
RETURNS TABLE(organisation_id uuid,campaign_id uuid,company_id uuid)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
 SELECT DISTINCT s.organisation_id,s.campaign_id,s.company_id
 FROM public.organisation_company_scopes s
 JOIN public.campaigns c ON c.id=s.campaign_id AND c.organisation_id=s.organisation_id AND c.workflow_state='ACTIVE'
 LEFT JOIN public.opportunities o ON o.organisation_id=s.organisation_id AND o.campaign_id=s.campaign_id AND o.company_id=s.company_id
 WHERE s.scope_kind='CAMPAIGN' AND s.campaign_id IS NOT NULL
   AND (o.id IS NOT NULL OR public.marketroute_authority_ready_v1(s.organisation_id,s.campaign_id,s.company_id,now()))
 ORDER BY s.organisation_id,s.campaign_id,s.company_id
 LIMIT greatest(0,least(COALESCE(p_limit,250),2000));
$$;

CREATE OR REPLACE FUNCTION public.marketroute_list_opportunity_profiles_v1(p_organisation_id uuid,p_campaign_id uuid,p_at timestamptz DEFAULT now())
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_result jsonb;
BEGIN
 PERFORM public.marketroute_require_service_role();
 IF NOT EXISTS(SELECT 1 FROM public.campaigns c WHERE c.id=p_campaign_id AND c.organisation_id=p_organisation_id) THEN RAISE EXCEPTION 'MARKETROUTE_OPPORTUNITY_LIST_CAMPAIGN_SCOPE_MISMATCH'; END IF;
 SELECT COALESCE(jsonb_agg(public.marketroute_opportunity_profile_v1(o.organisation_id,o.campaign_id,o.company_id,p_at) ORDER BY c.canonical_name,o.company_id),'[]'::jsonb) INTO v_result
 FROM public.opportunities o JOIN public.companies c ON c.id=o.company_id WHERE o.organisation_id=p_organisation_id AND o.campaign_id=p_campaign_id;
 RETURN v_result;
END $$;

ALTER TABLE public.opportunity_sync_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.opportunity_sync_events FROM anon,authenticated,service_role;
GRANT SELECT ON public.opportunity_sync_events TO service_role;

-- These helpers are internal/backend only. Build 13 will define user-facing read contracts.
REVOKE ALL ON FUNCTION public.marketroute_opportunity_disposition_v1(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_opportunity_research_pressure_v1(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_opportunity_profile_v1(uuid,uuid,uuid,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_sync_opportunity_v1(uuid,uuid,uuid,uuid,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_opportunity_sync_targets_v1(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_list_opportunity_profiles_v1(uuid,uuid,timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.marketroute_opportunity_profile_v1(uuid,uuid,uuid,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_sync_opportunity_v1(uuid,uuid,uuid,uuid,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_opportunity_sync_targets_v1(integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_list_opportunity_profiles_v1(uuid,uuid,timestamptz) TO service_role;

-- Direct workflow DML remains forbidden despite the new system-owned sync RPC.
REVOKE INSERT,UPDATE,DELETE ON public.opportunities FROM anon,authenticated,service_role;
REVOKE INSERT,UPDATE,DELETE ON public.opportunity_workflow_events FROM anon,authenticated,service_role;

INSERT INTO public.marketroute_schema_releases(release_key,build_number,constitution_version,metadata_json)
VALUES('MARKETROUTE_V2_BUILD11_OPPORTUNITY_ENGINE',11,'MRV2-CONSTITUTION-1.0.0',jsonb_build_object(
 'migration','0014_opportunity_engine.sql','new_authority_writer',false,'opportunity_is_authority',false,'single_numeric_opportunity_metric',false,
 'materialisation_requires_authority_ready',true,'human_workflow_preserved',true,'system_reviewability_derived',true,'pareto_product_ordering_only',true
)) ON CONFLICT(release_key) DO NOTHING;

NOTIFY pgrst,'reload schema';
COMMIT;
