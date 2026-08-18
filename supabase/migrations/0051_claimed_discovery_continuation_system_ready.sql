BEGIN;

-- MarketRoute V2 RC: claimed Discovery continuation + system-owned opportunity readiness.
-- This migration creates no new commercial/truth authority writer. R4/R5/R6 remain
-- the sole authority chain. REVIEWABLE is retained as the storage value for backward
-- compatibility, but from this release it means system-ready rather than awaiting
-- customer approval.

CREATE TABLE IF NOT EXISTS public.anonymous_discovery_extension_jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id uuid NOT NULL UNIQUE REFERENCES public.anonymous_discovery_runs(id) ON DELETE RESTRICT,
  organisation_id uuid NOT NULL REFERENCES public.organisations(id) ON DELETE RESTRICT,
  campaign_id uuid NOT NULL,
  status text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','RUNNING','DEFERRED','SUCCEEDED','EXHAUSTED','FAILED')),
  attempt_count integer NOT NULL DEFAULT 0 CHECK (attempt_count BETWEEN 0 AND 3),
  available_at timestamptz NOT NULL DEFAULT now(),
  worker_id text,
  lease_expires_at timestamptz,
  last_error_code text,
  result_json jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(result_json)='object'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT anonymous_discovery_extension_campaign_scope_fk FOREIGN KEY(organisation_id,campaign_id) REFERENCES public.campaigns(organisation_id,id) ON DELETE RESTRICT
);
CREATE INDEX IF NOT EXISTS anonymous_discovery_extension_queue_idx ON public.anonymous_discovery_extension_jobs(status,available_at,created_at);
DROP TRIGGER IF EXISTS anonymous_discovery_extension_touch_updated_at ON public.anonymous_discovery_extension_jobs;
CREATE TRIGGER anonymous_discovery_extension_touch_updated_at BEFORE UPDATE ON public.anonymous_discovery_extension_jobs FOR EACH ROW EXECUTE FUNCTION public.marketroute_touch_updated_at();
ALTER TABLE public.anonymous_discovery_extension_jobs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.anonymous_discovery_extension_jobs FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT,INSERT,UPDATE ON public.anonymous_discovery_extension_jobs TO service_role;

CREATE OR REPLACE FUNCTION public.marketroute_claim_anonymous_discovery_extension_v1(p_worker_id text,p_at timestamptz DEFAULT now())
RETURNS TABLE(job_id uuid,run_id uuid,organisation_id uuid,campaign_id uuid,seller_business_id uuid,seller_name text,canonical_domain text,website_url text,objective_text text,target_market_text text,target_count integer,scoped_count integer,remaining_count integer,attempt_count integer,existing_domains text[])
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_job uuid;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF length(btrim(COALESCE(p_worker_id,'')))<3 THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_EXTENSION_WORKER_REQUIRED'; END IF;

  -- Auto-seed both anonymous and claimed runs. Account creation therefore never
  -- ends the original bounded discovery envelope. Paid workspaces leave this queue.
  INSERT INTO public.anonymous_discovery_extension_jobs(run_id,organisation_id,campaign_id,status,available_at)
  SELECT r.id,r.organisation_id,c.id,'PENDING',p_at
  FROM public.anonymous_discovery_runs r
  JOIN LATERAL (SELECT c1.id FROM public.campaigns c1 WHERE c1.organisation_id=r.organisation_id AND c1.workflow_state='ACTIVE' ORDER BY c1.created_at LIMIT 1) c ON true
  WHERE r.status IN('ACTIVE','CLAIMED')
    AND r.research_expires_at>p_at
    AND NOT public.marketroute_paid_entitlement_active_v1(r.organisation_id,p_at)
    AND (SELECT count(DISTINCT s.company_id) FROM public.organisation_company_scopes s WHERE s.organisation_id=r.organisation_id AND s.campaign_id=c.id AND s.scope_kind='CAMPAIGN') < r.target_count
  ON CONFLICT(run_id) DO UPDATE SET
    campaign_id=EXCLUDED.campaign_id,
    status=CASE WHEN anonymous_discovery_extension_jobs.status IN('SUCCEEDED','EXHAUSTED') AND anonymous_discovery_extension_jobs.attempt_count<3 THEN 'PENDING' ELSE anonymous_discovery_extension_jobs.status END,
    available_at=CASE WHEN anonymous_discovery_extension_jobs.status IN('SUCCEEDED','EXHAUSTED') AND anonymous_discovery_extension_jobs.attempt_count<3 THEN p_at ELSE anonymous_discovery_extension_jobs.available_at END;

  UPDATE public.anonymous_discovery_extension_jobs j
  SET status='DEFERRED',worker_id=NULL,lease_expires_at=NULL,available_at=p_at,last_error_code='MARKETROUTE_ANONYMOUS_EXTENSION_LEASE_RECOVERED'
  WHERE j.status='RUNNING' AND j.lease_expires_at<p_at;

  SELECT j.id INTO v_job
  FROM public.anonymous_discovery_extension_jobs j
  JOIN public.anonymous_discovery_runs r ON r.id=j.run_id
  JOIN public.campaigns c ON c.id=j.campaign_id AND c.organisation_id=j.organisation_id
  WHERE j.status IN('PENDING','DEFERRED') AND j.available_at<=p_at AND j.attempt_count<3
    AND r.status IN('ACTIVE','CLAIMED') AND r.research_expires_at>p_at AND c.workflow_state='ACTIVE'
    AND NOT public.marketroute_paid_entitlement_active_v1(j.organisation_id,p_at)
    AND (SELECT count(DISTINCT s.company_id) FROM public.organisation_company_scopes s WHERE s.organisation_id=j.organisation_id AND s.campaign_id=j.campaign_id AND s.scope_kind='CAMPAIGN') < r.target_count
  ORDER BY j.available_at,j.created_at,j.id FOR UPDATE OF j SKIP LOCKED LIMIT 1;
  IF v_job IS NULL THEN RETURN; END IF;

  UPDATE public.anonymous_discovery_extension_jobs SET status='RUNNING',attempt_count=attempt_count+1,worker_id=left(btrim(p_worker_id),200),lease_expires_at=p_at+interval '5 minutes',last_error_code=NULL WHERE id=v_job;

  RETURN QUERY
  SELECT j.id,r.id,r.organisation_id,j.campaign_id,r.seller_business_id,s.name,s.canonical_domain,s.website_url,a.objective_text,a.target_market_text,r.target_count,
    (SELECT count(DISTINCT sc.company_id)::int FROM public.organisation_company_scopes sc WHERE sc.organisation_id=r.organisation_id AND sc.campaign_id=j.campaign_id AND sc.scope_kind='CAMPAIGN') AS scoped_count,
    greatest(0,r.target_count-(SELECT count(DISTINCT sc.company_id)::int FROM public.organisation_company_scopes sc WHERE sc.organisation_id=r.organisation_id AND sc.campaign_id=j.campaign_id AND sc.scope_kind='CAMPAIGN')) AS remaining_count,
    j.attempt_count,
    COALESCE((SELECT array_agg(DISTINCT lower(cmp.canonical_domain) ORDER BY lower(cmp.canonical_domain)) FROM public.organisation_company_scopes sc JOIN public.companies cmp ON cmp.id=sc.company_id WHERE sc.organisation_id=r.organisation_id AND sc.campaign_id=j.campaign_id AND sc.scope_kind='CAMPAIGN' AND cmp.canonical_domain IS NOT NULL),'{}'::text[]) AS existing_domains
  FROM public.anonymous_discovery_extension_jobs j
  JOIN public.anonymous_discovery_runs r ON r.id=j.run_id
  JOIN public.seller_businesses s ON s.id=r.seller_business_id AND s.organisation_id=r.organisation_id
  JOIN public.workspace_activation_jobs a ON a.id=r.activation_job_id
  WHERE j.id=v_job;
END $fn$;

CREATE OR REPLACE FUNCTION public.marketroute_link_anonymous_discovery_extension_company_v1(p_job_id uuid,p_worker_id text,p_name text,p_domain text,p_website_url text,p_country_code text,p_at timestamptz DEFAULT now())
RETURNS TABLE(company_id uuid,scoped_count integer,target_count integer,inserted_scope boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_job public.anonymous_discovery_extension_jobs%ROWTYPE;v_run public.anonymous_discovery_runs%ROWTYPE;v_domain text;v_company uuid;v_before integer;v_after integer;v_seller_domain text;
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT * INTO v_job FROM public.anonymous_discovery_extension_jobs WHERE id=p_job_id FOR UPDATE;
  IF NOT FOUND OR v_job.status<>'RUNNING' OR v_job.worker_id IS DISTINCT FROM left(btrim(COALESCE(p_worker_id,'')),200) OR v_job.lease_expires_at<=p_at THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_EXTENSION_LEASE_INVALID'; END IF;
  SELECT * INTO v_run FROM public.anonymous_discovery_runs WHERE id=v_job.run_id FOR UPDATE;
  IF v_run.status NOT IN('ACTIVE','CLAIMED') OR v_run.research_expires_at<=p_at OR public.marketroute_paid_entitlement_active_v1(v_run.organisation_id,p_at) THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_EXTENSION_RUN_NOT_ELIGIBLE'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.campaigns c WHERE c.id=v_job.campaign_id AND c.organisation_id=v_run.organisation_id AND c.workflow_state='ACTIVE') THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_EXTENSION_CAMPAIGN_NOT_ACTIVE'; END IF;
  SELECT lower(canonical_domain) INTO v_seller_domain FROM public.seller_businesses WHERE id=v_run.seller_business_id AND organisation_id=v_run.organisation_id;
  v_domain:=lower(regexp_replace(btrim(COALESCE(p_domain,'')),'^www[.]','','i'));
  IF v_domain !~ '^[a-z0-9][a-z0-9.-]*[.][a-z]{2,63}$' OR v_domain~'[.][.]' OR v_domain=v_seller_domain THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_EXTENSION_DOMAIN_INVALID'; END IF;
  SELECT count(DISTINCT s.company_id)::int INTO v_before FROM public.organisation_company_scopes s WHERE s.organisation_id=v_run.organisation_id AND s.campaign_id=v_job.campaign_id AND s.scope_kind='CAMPAIGN';
  IF v_before>=v_run.target_count THEN RETURN; END IF;
  SELECT id INTO v_company FROM public.companies WHERE canonical_domain=v_domain LIMIT 1;
  IF v_company IS NULL THEN
    INSERT INTO public.companies(canonical_name,canonical_domain,website_url,country_code,lifecycle_state) VALUES(left(btrim(COALESCE(p_name,'')),240),v_domain,COALESCE(NULLIF(btrim(COALESCE(p_website_url,'')),''),'https://' || v_domain),CASE WHEN upper(COALESCE(p_country_code,''))~'^[A-Z]{2}$' THEN upper(p_country_code) ELSE NULL END,'ACTIVE') RETURNING id INTO v_company;
  END IF;
  INSERT INTO public.organisation_company_scopes(organisation_id,company_id,campaign_id,scope_kind) VALUES(v_run.organisation_id,v_company,v_job.campaign_id,'CAMPAIGN') ON CONFLICT DO NOTHING;
  SELECT count(DISTINCT s.company_id)::int INTO v_after FROM public.organisation_company_scopes s WHERE s.organisation_id=v_run.organisation_id AND s.campaign_id=v_job.campaign_id AND s.scope_kind='CAMPAIGN';
  IF v_after>v_run.target_count THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_EXTENSION_TARGET_OVERSCOPE'; END IF;
  RETURN QUERY SELECT v_company,v_after,v_run.target_count,(v_after>v_before);
END $fn$;

CREATE OR REPLACE FUNCTION public.marketroute_complete_anonymous_discovery_extension_v1(p_job_id uuid,p_worker_id text,p_result_json jsonb,p_at timestamptz DEFAULT now())
RETURNS TABLE(status text,scoped_count integer,target_count integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_job public.anonymous_discovery_extension_jobs%ROWTYPE;v_run public.anonymous_discovery_runs%ROWTYPE;v_count integer;v_status text;
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT * INTO v_job FROM public.anonymous_discovery_extension_jobs WHERE id=p_job_id FOR UPDATE;
  IF NOT FOUND OR v_job.status<>'RUNNING' OR v_job.worker_id IS DISTINCT FROM left(btrim(COALESCE(p_worker_id,'')),200) THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_EXTENSION_LEASE_INVALID'; END IF;
  SELECT * INTO v_run FROM public.anonymous_discovery_runs WHERE id=v_job.run_id;
  SELECT count(DISTINCT s.company_id)::int INTO v_count FROM public.organisation_company_scopes s WHERE s.organisation_id=v_job.organisation_id AND s.campaign_id=v_job.campaign_id AND s.scope_kind='CAMPAIGN';
  v_status:=CASE WHEN v_count>=v_run.target_count THEN 'SUCCEEDED' WHEN v_job.attempt_count>=3 OR v_run.research_expires_at<=p_at THEN 'EXHAUSTED' ELSE 'DEFERRED' END;
  UPDATE public.anonymous_discovery_extension_jobs SET status=v_status,worker_id=NULL,lease_expires_at=NULL,available_at=CASE WHEN v_status='DEFERRED' THEN p_at+interval '2 minutes' ELSE available_at END,result_json=COALESCE(p_result_json,'{}'::jsonb) || jsonb_build_object('scopedCount',v_count,'targetCount',v_run.target_count,'completedAt',p_at) WHERE id=p_job_id;
  RETURN QUERY SELECT v_status,v_count,v_run.target_count;
END $fn$;

CREATE OR REPLACE FUNCTION public.marketroute_fail_anonymous_discovery_extension_v1(p_job_id uuid,p_worker_id text,p_error_code text,p_retryable boolean,p_at timestamptz DEFAULT now())
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_job public.anonymous_discovery_extension_jobs%ROWTYPE;
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT * INTO v_job FROM public.anonymous_discovery_extension_jobs WHERE id=p_job_id FOR UPDATE;
  IF NOT FOUND OR v_job.status<>'RUNNING' OR v_job.worker_id IS DISTINCT FROM left(btrim(COALESCE(p_worker_id,'')),200) THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_EXTENSION_LEASE_INVALID'; END IF;
  UPDATE public.anonymous_discovery_extension_jobs SET status=CASE WHEN COALESCE(p_retryable,false) AND attempt_count<3 THEN 'DEFERRED' ELSE 'FAILED' END,worker_id=NULL,lease_expires_at=NULL,available_at=CASE WHEN COALESCE(p_retryable,false) AND attempt_count<3 THEN p_at+interval '2 minutes' ELSE available_at END,last_error_code=left(COALESCE(NULLIF(btrim(p_error_code),''),'MARKETROUTE_ANONYMOUS_EXTENSION_FAILED'),240) WHERE id=p_job_id;
END $fn$;

REVOKE ALL ON FUNCTION public.marketroute_claim_anonymous_discovery_extension_v1(text,timestamptz) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_link_anonymous_discovery_extension_company_v1(uuid,text,text,text,text,text,timestamptz) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_complete_anonymous_discovery_extension_v1(uuid,text,jsonb,timestamptz) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_fail_anonymous_discovery_extension_v1(uuid,text,text,boolean,timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_claim_anonymous_discovery_extension_v1(text,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_link_anonymous_discovery_extension_company_v1(uuid,text,text,text,text,text,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_complete_anonymous_discovery_extension_v1(uuid,text,jsonb,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_fail_anonymous_discovery_extension_v1(uuid,text,text,boolean,timestamptz) TO service_role;

-- REVIEWABLE is retained as a storage-compatible state but now means READY.
CREATE OR REPLACE FUNCTION public.marketroute_opportunity_executable_now_v1(p_opportunity_id uuid,p_at timestamptz DEFAULT now())
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
 SELECT COALESCE((SELECT o.workflow_state IN('REVIEWABLE','APPROVED') AND public.marketroute_authority_ready_v1(o.organisation_id,o.campaign_id,o.company_id,p_at) FROM public.opportunities o WHERE o.id=p_opportunity_id),false);
$$;

CREATE OR REPLACE FUNCTION public.marketroute_engagement_generation_context_v1(p_opportunity_id uuid,p_path_fingerprint text,p_at timestamptz DEFAULT now())
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE
 v_opp public.opportunities%ROWTYPE; v_company public.companies%ROWTYPE; v_env jsonb; v_envfp text;
 v_r4 public.commercial_reality_r4_records%ROWTYPE; v_r6 public.contact_authority_r6_records%ROWTYPE; v_a6 public.authority_records%ROWTYPE; v_r5 public.route_authority_r5_records%ROWTYPE;
 v_binding jsonb; v_path jsonb; v_node public.commercial_graph_nodes%ROWTYPE; v_person public.people%ROWTYPE; v_seller jsonb;
 v_objective text; v_objective_statement text; v_offering_keys jsonb:='[]'::jsonb; v_offering_labels jsonb:='[]'::jsonb; v_offering_summaries jsonb:='[]'::jsonb; v_boundary_facts jsonb:='[]'::jsonb; v_channel text;
BEGIN
 PERFORM public.marketroute_require_service_role();
 IF p_at IS NULL OR abs(extract(epoch FROM(now()-p_at)))>300 THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_CONTEXT_TIME_NOT_CURRENT'; END IF;
 IF p_path_fingerprint IS NULL OR p_path_fingerprint !~ '^[a-f0-9]{64}$' THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_PATH_FINGERPRINT_INVALID'; END IF;
 SELECT * INTO v_opp FROM public.opportunities WHERE id=p_opportunity_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_OPPORTUNITY_NOT_FOUND'; END IF;
 IF NOT EXISTS(
   SELECT 1 FROM public.organisations o
   JOIN public.campaigns c ON c.organisation_id=o.id AND c.id=v_opp.campaign_id
   JOIN public.seller_businesses sb ON sb.organisation_id=c.organisation_id AND sb.id=c.seller_business_id
   WHERE o.id=v_opp.organisation_id AND o.status='ACTIVE' AND c.workflow_state='ACTIVE' AND sb.lifecycle_state='ACTIVE'
 ) THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_ACTIVE_COMMERCIAL_CONTEXT_REQUIRED'; END IF;
 IF v_opp.workflow_state NOT IN('REVIEWABLE','APPROVED') THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_REQUIRES_READY_OPPORTUNITY'; END IF;
 IF NOT public.marketroute_opportunity_executable_now_v1(v_opp.id,p_at) THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_REQUIRES_CURRENT_AUTHORITY'; END IF;
 SELECT * INTO v_company FROM public.companies WHERE id=v_opp.company_id;
 IF NOT FOUND OR v_company.lifecycle_state<>'ACTIVE' THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_ACTIVE_TARGET_COMPANY_REQUIRED'; END IF;
 v_env:=public.marketroute_authority_envelope_v1(v_opp.organisation_id,v_opp.campaign_id,v_opp.company_id,p_at); v_envfp:=public.marketroute_authority_envelope_fingerprint_v1(v_env);
 SELECT r.* INTO v_r4 FROM public.commercial_reality_r4_records r WHERE r.authority_record_id=(v_env->'r4'->>'authorityRecordId')::uuid;
 IF NOT FOUND OR v_r4.decision_code<>'COMMERCIAL_CANDIDATE' THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_CURRENT_R4_REQUIRED'; END IF;
 SELECT COALESCE(jsonb_agg(jsonb_build_object('boundaryKey',b.value->>'boundaryKey','claimKey',b.value->>'claimKey','observedValue',b.value->>'observedValue') ORDER BY b.value->>'boundaryKey'),'[]'::jsonb) INTO v_boundary_facts
 FROM jsonb_array_elements(v_r4.boundaries_json) b(value)
 WHERE b.value->>'state'='SATISFIED' AND NULLIF(b.value->>'claimKey','') IS NOT NULL AND NULLIF(b.value->>'observedValue','') IS NOT NULL;
 SELECT r.* INTO v_r6 FROM public.contact_authority_r6_records r WHERE r.authority_record_id=(v_env->'r6'->>'authorityRecordId')::uuid;
 IF NOT FOUND OR v_r6.decision_code<>'CONTACT_AUTHORISED' THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_CURRENT_R6_REQUIRED'; END IF;
 SELECT * INTO v_a6 FROM public.authority_records WHERE id=v_r6.authority_record_id;
 SELECT r.* INTO v_r5 FROM public.route_authority_r5_records r WHERE r.authority_record_id=v_r6.parent_r5_authority_record_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_PARENT_R5_NOT_FOUND'; END IF;
 SELECT b.value INTO v_binding FROM jsonb_array_elements(v_r6.bindings_json) b(value) WHERE b.value->>'pathFingerprint'=p_path_fingerprint AND b.value->>'authorityState'='AUTHORISED' LIMIT 1;
 IF v_binding IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_PATH_NOT_R6_AUTHORISED'; END IF;
 SELECT p.value INTO v_path FROM jsonb_array_elements(v_r5.paths_json) p(value) WHERE p.value->>'pathFingerprint'=p_path_fingerprint LIMIT 1;
 IF v_path IS NULL OR v_path->>'terminalAccessPointId' IS DISTINCT FROM v_binding->>'terminalAccessPointId' THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_R5_R6_PATH_MISMATCH'; END IF;
 SELECT * INTO v_node FROM public.commercial_graph_nodes WHERE id=(v_binding->>'terminalAccessPointId')::uuid AND node_kind='ACCESS_POINT';
 IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_ACCESS_POINT_NOT_FOUND'; END IF;
 v_channel:=public.marketroute_engagement_channel_kind_v1(v_node.access_point_kind); IF v_channel IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_ACCESS_POINT_KIND_UNSUPPORTED'; END IF;
 IF NULLIF(v_binding->>'personId','') IS NOT NULL THEN SELECT * INTO v_person FROM public.people WHERE id=(v_binding->>'personId')::uuid AND lifecycle_state='ACTIVE'; IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_PERSON_NOT_ACTIVE'; END IF; END IF;
 v_seller:=public.marketroute_get_current_campaign_seller_context_v1(v_opp.organisation_id,v_opp.campaign_id); IF v_seller IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_SELLER_CONTEXT_REQUIRED'; END IF;
 v_objective:=v_seller->>'objectiveKey';
 SELECT e.value->>'statement' INTO v_objective_statement FROM jsonb_array_elements(COALESCE(v_seller->'canonicalGenome'->'explanatory'->'objectiveCopy','[]'::jsonb)) e(value) WHERE e.value->>'objectiveKey'=v_objective LIMIT 1;
 SELECT COALESCE(o.value->'offeringKeys','[]'::jsonb) INTO v_offering_keys FROM jsonb_array_elements(COALESCE(v_seller->'canonicalGenome'->'semantic'->'commercialObjectives'->'items','[]'::jsonb)) o(value) WHERE o.value->>'objectiveKey'=v_objective LIMIT 1;
 SELECT COALESCE(jsonb_agg(c.value->>'label' ORDER BY c.value->>'offeringKey'),'[]'::jsonb),
        COALESCE(jsonb_agg(jsonb_build_object('offeringKey',c.value->>'offeringKey','label',c.value->>'label','description',c.value->'description') ORDER BY c.value->>'offeringKey'),'[]'::jsonb)
 INTO v_offering_labels,v_offering_summaries
 FROM jsonb_array_elements(COALESCE(v_seller->'canonicalGenome'->'explanatory'->'offeringCopy','[]'::jsonb)) c(value)
 WHERE (c.value->>'offeringKey') IN (SELECT jsonb_array_elements_text(COALESCE(v_offering_keys,'[]'::jsonb)));
 RETURN jsonb_build_object(
  'opportunityId',v_opp.id::text,'organisationId',v_opp.organisation_id::text,'campaignId',v_opp.campaign_id::text,'companyId',v_opp.company_id::text,
  'companyName',v_company.canonical_name,'canonicalDomain',v_company.canonical_domain,'pathFingerprint',p_path_fingerprint,
  'accessPointId',v_node.id::text,'accessPointKind',v_node.access_point_kind,'accessPointValue',v_node.canonical_value,
  'routeMode',v_binding->>'mode','personId',NULLIF(v_binding->>'personId',''),'personName',CASE WHEN v_person.id IS NULL THEN NULL ELSE COALESCE(v_person.canonical_name,v_person.display_name) END,
  'sellerObjectiveKey',v_objective,'sellerObjectiveStatement',v_objective_statement,'sellerOfferingLabels',COALESCE(v_offering_labels,'[]'::jsonb),
  'sellerOfferings',COALESCE(v_offering_summaries,'[]'::jsonb),'commercialBoundaryFacts',COALESCE(v_boundary_facts,'[]'::jsonb),
  'authorityEnvelopeFingerprint',v_envfp,'r6AuthorityRecordId',v_r6.authority_record_id::text,'r6AuthorityFingerprint',v_a6.authority_fingerprint,
  'evaluatedAt',to_jsonb(p_at),'executableNow',true
 );
END $fn$;

CREATE OR REPLACE FUNCTION public.marketroute_record_manual_engagement_v1(
  p_opportunity_id uuid,
  p_path_fingerprint text,
  p_message_id uuid,
  p_actor_user_id uuid,
  p_request_id uuid,
  p_note text DEFAULT NULL,
  p_at timestamptz DEFAULT now()
)
RETURNS TABLE(
  manual_action_id uuid,
  workflow_event_id uuid,
  prior_workflow_state text,
  resulting_workflow_state text,
  channel_kind text,
  deduplicated boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
DECLARE
  v_existing public.engagement_manual_actions%ROWTYPE;
  v_opp public.opportunities%ROWTYPE;
  v_strategy public.engagement_strategies%ROWTYPE;
  v_message public.engagement_messages%ROWTYPE;
  v_review public.engagement_ai_reviews%ROWTYPE;
  v_approval public.engagement_message_approvals%ROWTYPE;
  v_context jsonb;
  v_envelope jsonb;
  v_envelope_fp text;
  v_action_id uuid;
  v_event_id uuid;
  v_note text:=NULLIF(left(btrim(COALESCE(p_note,'')),1000),'');
  v_prior text;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF p_request_id IS NULL OR p_actor_user_id IS NULL OR p_opportunity_id IS NULL OR p_message_id IS NULL THEN
    RAISE EXCEPTION 'MARKETROUTE_MANUAL_ENGAGEMENT_IDENTITY_REQUIRED';
  END IF;
  IF p_path_fingerprint IS NULL OR p_path_fingerprint !~ '^[a-f0-9]{64}$' THEN
    RAISE EXCEPTION 'MARKETROUTE_MANUAL_ENGAGEMENT_PATH_INVALID';
  END IF;

  SELECT * INTO v_existing FROM public.engagement_manual_actions WHERE request_id=p_request_id;
  IF FOUND THEN
    IF v_existing.opportunity_id IS DISTINCT FROM p_opportunity_id
      OR v_existing.path_fingerprint IS DISTINCT FROM p_path_fingerprint
      OR v_existing.message_id IS DISTINCT FROM p_message_id
      OR v_existing.actor_user_id IS DISTINCT FROM p_actor_user_id
      OR v_existing.note IS DISTINCT FROM v_note THEN
      RAISE EXCEPTION 'MARKETROUTE_MANUAL_ENGAGEMENT_IDEMPOTENCY_COLLISION';
    END IF;
    RETURN QUERY SELECT v_existing.id,NULL::uuid,'REVIEWABLE'::text,'ENGAGED'::text,v_existing.channel_kind,true;
    RETURN;
  END IF;

  IF p_at IS NULL OR abs(extract(epoch FROM(now()-p_at)))>300 THEN
    RAISE EXCEPTION 'MARKETROUTE_MANUAL_ENGAGEMENT_TIME_NOT_CURRENT';
  END IF;

  SELECT * INTO v_opp FROM public.opportunities WHERE id=p_opportunity_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_MANUAL_ENGAGEMENT_OPPORTUNITY_NOT_FOUND'; END IF;
  IF v_opp.workflow_state NOT IN('REVIEWABLE','APPROVED') THEN
    RAISE EXCEPTION 'MARKETROUTE_MANUAL_ENGAGEMENT_REQUIRES_READY_OPPORTUNITY';
  END IF;
  v_prior:=v_opp.workflow_state;
  IF NOT EXISTS(
    SELECT 1 FROM public.organisation_memberships m
    WHERE m.organisation_id=v_opp.organisation_id
      AND m.user_id=p_actor_user_id
      AND m.status='ACTIVE'
      AND m.role IN('OWNER','ADMIN','MEMBER')
  ) THEN RAISE EXCEPTION 'MARKETROUTE_MANUAL_ENGAGEMENT_ACTOR_NOT_AUTHORISED'; END IF;

  -- The context function revalidates ACTIVE organisation/campaign, system-ready
  -- workflow, current R4/R5/R6, executable authority and an R6-authorised path.
  v_context:=public.marketroute_engagement_generation_context_v1(p_opportunity_id,p_path_fingerprint,p_at);

  SELECT * INTO v_strategy
  FROM public.engagement_strategies s
  WHERE s.opportunity_id=p_opportunity_id AND s.path_fingerprint=p_path_fingerprint
  ORDER BY s.created_at DESC,s.id DESC LIMIT 1;
  IF NOT FOUND OR public.marketroute_engagement_strategy_current_v1(v_strategy.id,p_at) IS NOT TRUE THEN
    RAISE EXCEPTION 'MARKETROUTE_MANUAL_ENGAGEMENT_CURRENT_STRATEGY_REQUIRED';
  END IF;

  SELECT * INTO v_message FROM public.engagement_messages WHERE id=p_message_id AND strategy_id=v_strategy.id;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_MANUAL_ENGAGEMENT_MESSAGE_SCOPE_MISMATCH'; END IF;
  IF EXISTS(SELECT 1 FROM public.engagement_messages newer WHERE newer.strategy_id=v_strategy.id AND newer.rewrite_ordinal>v_message.rewrite_ordinal) THEN
    RAISE EXCEPTION 'MARKETROUTE_MANUAL_ENGAGEMENT_MESSAGE_NOT_CURRENT';
  END IF;

  SELECT * INTO v_review FROM public.engagement_ai_reviews WHERE message_id=v_message.id ORDER BY created_at DESC,id DESC LIMIT 1;
  IF NOT FOUND OR v_review.verdict<>'PASS' THEN
    RAISE EXCEPTION 'MARKETROUTE_MANUAL_ENGAGEMENT_PASS_REVIEW_REQUIRED';
  END IF;
  SELECT * INTO v_approval FROM public.engagement_message_approvals WHERE message_id=v_message.id ORDER BY created_at DESC,id DESC LIMIT 1;
  IF NOT FOUND OR v_approval.approval_mode<>'HUMAN' OR v_approval.decision<>'APPROVE' THEN
    RAISE EXCEPTION 'MARKETROUTE_MANUAL_ENGAGEMENT_HUMAN_APPROVAL_REQUIRED';
  END IF;

  v_envelope:=public.marketroute_authority_envelope_v1(v_opp.organisation_id,v_opp.campaign_id,v_opp.company_id,p_at);
  v_envelope_fp:=public.marketroute_authority_envelope_fingerprint_v1(v_envelope);
  IF v_envelope_fp IS DISTINCT FROM v_strategy.authority_envelope_fingerprint
    OR v_envelope_fp IS DISTINCT FROM v_approval.authority_envelope_fingerprint THEN
    RAISE EXCEPTION 'MARKETROUTE_MANUAL_ENGAGEMENT_AUTHORITY_CHANGED';
  END IF;

  INSERT INTO public.engagement_manual_actions(
    request_id,opportunity_id,organisation_id,campaign_id,company_id,strategy_id,message_id,actor_user_id,
    path_fingerprint,channel_kind,access_point_id,person_id,authority_envelope_fingerprint,note,occurred_at
  ) VALUES(
    p_request_id,v_opp.id,v_opp.organisation_id,v_opp.campaign_id,v_opp.company_id,v_strategy.id,v_message.id,p_actor_user_id,
    p_path_fingerprint,v_strategy.channel_kind,v_strategy.access_point_id,v_strategy.person_id,v_envelope_fp,v_note,p_at
  ) RETURNING id INTO v_action_id;

  UPDATE public.opportunities SET workflow_state='ENGAGED',updated_at=p_at WHERE id=v_opp.id;
  INSERT INTO public.opportunity_workflow_events(
    opportunity_id,organisation_id,event_type,prior_workflow_state,resulting_workflow_state,
    actor_user_id,request_id,reason_code,authority_envelope_json,authority_envelope_fingerprint,occurred_at
  ) VALUES(
    v_opp.id,v_opp.organisation_id,'ENGAGEMENT',v_prior,'ENGAGED',p_actor_user_id,p_request_id,
    'FIRST_MANUAL_ENGAGEMENT_RECORDED',v_envelope,v_envelope_fp,p_at
  ) RETURNING id INTO v_event_id;

  RETURN QUERY SELECT v_action_id,v_event_id,v_prior,'ENGAGED'::text,v_strategy.channel_kind,false;
END $fn$;

CREATE OR REPLACE FUNCTION public.marketroute_application_engagement_read_v1(p_opportunity_id uuid,p_at timestamptz DEFAULT now())
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE
  v_opp public.opportunities%ROWTYPE;
  v_policy text;
  v_strategy public.engagement_strategies%ROWTYPE;
  v_message public.engagement_messages%ROWTYPE;
  v_review public.engagement_ai_reviews%ROWTYPE;
  v_approval public.engagement_message_approvals%ROWTYPE;
  v_queue public.engagement_queue_items%ROWTYPE;
  v_job public.engagement_delivery_jobs%ROWTYPE;
  v_last_delivery public.engagement_delivery_events%ROWTYPE;
  v_manual public.engagement_manual_actions%ROWTYPE;
  v_strategy_current boolean:=false;
  v_executable boolean:=false;
BEGIN
  PERFORM public.marketroute_require_service_role();
  PERFORM public.marketroute_application_require_current_read_time_v1(p_at);
  SELECT * INTO v_opp FROM public.opportunities WHERE id=p_opportunity_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_APPLICATION_ENGAGEMENT_OPPORTUNITY_NOT_FOUND'; END IF;
  v_policy:=public.marketroute_current_engagement_policy_v1(v_opp.organisation_id,v_opp.campaign_id);
  v_executable:=public.marketroute_opportunity_executable_now_v1(v_opp.id,p_at);

  SELECT * INTO v_strategy FROM public.engagement_strategies WHERE opportunity_id=v_opp.id ORDER BY created_at DESC,id DESC LIMIT 1;
  IF v_strategy.id IS NOT NULL THEN
    v_strategy_current:=public.marketroute_engagement_strategy_current_v1(v_strategy.id,p_at);
    SELECT * INTO v_message FROM public.engagement_messages WHERE strategy_id=v_strategy.id ORDER BY rewrite_ordinal DESC,created_at DESC,id DESC LIMIT 1;
  END IF;
  IF v_message.id IS NOT NULL THEN
    SELECT * INTO v_review FROM public.engagement_ai_reviews WHERE message_id=v_message.id ORDER BY created_at DESC,id DESC LIMIT 1;
    SELECT * INTO v_approval FROM public.engagement_message_approvals WHERE message_id=v_message.id ORDER BY created_at DESC,id DESC LIMIT 1;
    SELECT * INTO v_queue FROM public.engagement_queue_items WHERE message_id=v_message.id ORDER BY queued_at DESC,id DESC LIMIT 1;
  END IF;
  IF v_queue.id IS NOT NULL THEN
    SELECT * INTO v_job FROM public.engagement_delivery_jobs WHERE queue_item_id=v_queue.id;
    SELECT * INTO v_last_delivery FROM public.engagement_delivery_events WHERE queue_item_id=v_queue.id ORDER BY occurred_at DESC,id DESC LIMIT 1;
  END IF;
  SELECT * INTO v_manual FROM public.engagement_manual_actions WHERE opportunity_id=v_opp.id ORDER BY occurred_at DESC,id DESC LIMIT 1;

  RETURN jsonb_build_object(
    'contractVersion','MRV2-APPLICATION-READ-1.0.0',
    'evaluatedAt',to_jsonb(p_at),
    'policyMode','HUMAN_ONLY',
    'engagementMode','ASSISTED_ONLY',
    'opportunityExecutableNow',v_executable,
    'strategy',CASE WHEN v_strategy.id IS NULL THEN NULL ELSE jsonb_build_object(
      'strategyId',v_strategy.id,'strategyFingerprint',v_strategy.strategy_fingerprint,'strategyVersion',v_strategy.strategy_version,
      'pathFingerprint',v_strategy.path_fingerprint,'channel',v_strategy.channel_kind,'routeMode',v_strategy.route_mode,
      'accessPointId',v_strategy.access_point_id,'accessPointKind',v_strategy.access_point_kind,'accessPointValue',v_strategy.access_point_value,
      'personId',v_strategy.person_id,'authorityEnvelopeFingerprint',v_strategy.authority_envelope_fingerprint,
      'r6AuthorityRecordId',v_strategy.r6_authority_record_id,'r6AuthorityFingerprint',v_strategy.r6_authority_fingerprint,
      'current',v_strategy_current,'createdAt',v_strategy.created_at
    ) END,
    'message',CASE WHEN v_message.id IS NULL THEN NULL ELSE jsonb_build_object(
      'messageId',v_message.id,'rewriteOrdinal',v_message.rewrite_ordinal,'generationContractVersion',v_message.generation_contract_version,
      'generatorVersion',v_message.generator_version,'subjectText',v_message.subject_text,'bodyText',v_message.body_text,
      'messageFingerprint',v_message.message_fingerprint,'createdAt',v_message.created_at
    ) END,
    'aiReview',CASE WHEN v_review.id IS NULL THEN NULL ELSE jsonb_build_object(
      'reviewId',v_review.id,'reviewContractVersion',v_review.review_contract_version,'reviewerVersion',v_review.reviewer_version,
      'verdict',v_review.verdict,'reasonCodes',to_jsonb(v_review.reason_codes),'diagnostics',v_review.diagnostics_json,
      'reviewFingerprint',v_review.review_fingerprint,'createdAt',v_review.created_at
    ) END,
    'approval',CASE WHEN v_approval.id IS NULL THEN NULL ELSE jsonb_build_object(
      'approvalId',v_approval.id,'mode',v_approval.approval_mode,'decision',v_approval.decision,'actorUserId',v_approval.actor_user_id,
      'authorityEnvelopeFingerprint',v_approval.authority_envelope_fingerprint,'createdAt',v_approval.created_at
    ) END,
    'manualAction',CASE WHEN v_manual.id IS NULL THEN NULL ELSE jsonb_build_object(
      'manualActionId',v_manual.id,'actorUserId',v_manual.actor_user_id,'channel',v_manual.channel_kind,
      'pathFingerprint',v_manual.path_fingerprint,'messageId',v_manual.message_id,
      'authorityEnvelopeFingerprint',v_manual.authority_envelope_fingerprint,'note',v_manual.note,'occurredAt',v_manual.occurred_at
    ) END,
    'queue',CASE WHEN v_queue.id IS NULL THEN NULL ELSE jsonb_build_object(
      'queueItemId',v_queue.id,'approvalMode',v_queue.approval_mode,'authorityEnvelopeFingerprint',v_queue.authority_envelope_fingerprint,'queuedAt',v_queue.queued_at
    ) END,
    'delivery',CASE WHEN v_job.id IS NULL THEN NULL ELSE jsonb_build_object(
      'jobId',v_job.id,'status',v_job.status,'attemptNumber',v_job.attempt_number,'claimedAt',v_job.claimed_at,
      'sendGateFingerprint',v_job.send_gate_fingerprint,'lastErrorCode',v_job.last_error_code,'finishedAt',v_job.finished_at,
      'lastEvent',CASE WHEN v_last_delivery.id IS NULL THEN NULL ELSE jsonb_build_object(
        'eventType',v_last_delivery.event_type,'providerMessageId',v_last_delivery.provider_message_id,
        'sendGateFingerprint',v_last_delivery.send_gate_fingerprint,'occurredAt',v_last_delivery.occurred_at
      ) END
    ) END,
    'actions',jsonb_build_object(
      'canGenerateDraft',v_opp.workflow_state IN('REVIEWABLE','APPROVED') AND v_executable,
      'canApproveMessage',v_message.id IS NOT NULL AND COALESCE(v_review.verdict,'')='PASS' AND v_executable AND v_strategy_current,
      'canQueue',false,
      'canMarkContacted',v_manual.id IS NULL AND v_message.id IS NOT NULL AND COALESCE(v_review.verdict,'')='PASS'
        AND COALESCE(v_approval.decision,'')='APPROVE' AND COALESCE(v_approval.approval_mode,'')='HUMAN'
        AND v_executable AND v_strategy_current,
      'deliveryNeedsReconciliation',COALESCE(v_job.status,'')='RECONCILIATION_REQUIRED'
    )
  );
END $fn$;

-- Customer-facing opportunity approval/rejection is retired. The legacy review
-- RPC remains for RETURN_TO_RESEARCH compatibility and historical audit only.

INSERT INTO public.marketroute_schema_releases(release_key,build_number,constitution_version,metadata_json) VALUES(
  'MARKETROUTE_V2_RC_CLAIM_CONTINUATION_SYSTEM_READY_2026_08_18',26,'MRV2-CONSTITUTION-1.0.0',jsonb_build_object(
    'migration','0051_claimed_discovery_continuation_system_ready.sql','new_authority_writer',false,'authority_semantics_unchanged',true,
    'claimed_discovery_continues',true,'anonymous_target_cap',10,'account_claim_does_not_reset_run',true,
    'reviewable_storage_means_ready',true,'opportunity_human_approval_required',false,'message_human_approval_required',true
  )
) ON CONFLICT(release_key) DO NOTHING;

NOTIFY pgrst,'reload schema';
COMMIT;
