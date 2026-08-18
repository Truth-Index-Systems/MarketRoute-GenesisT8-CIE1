BEGIN;

-- MarketRoute V2 RC: anonymous Discovery quota refill cycle hardening.
-- The 10-company launch target remains bounded by the original 1 USD / 12 hour
-- Discovery envelope. This migration changes only orchestration timing: extension
-- attempts may not be consumed while the current scoped batch is still awaiting
-- its first COMPANY_CORE_V1 Truth snapshot.

ALTER TABLE public.anonymous_discovery_extension_jobs
  ADD COLUMN IF NOT EXISTS cycle_policy_version integer NOT NULL DEFAULT 1
  CHECK (cycle_policy_version BETWEEN 1 AND 2);

CREATE OR REPLACE FUNCTION public.marketroute_anonymous_discovery_research_cycle_ready_v1(p_run_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
  SELECT COALESCE((
    SELECT r.original_campaign_id IS NOT NULL
      AND NOT EXISTS(
        SELECT 1
        FROM public.organisation_company_scopes s
        WHERE s.organisation_id=r.organisation_id
          AND s.campaign_id=r.original_campaign_id
          AND s.scope_kind='CAMPAIGN'
          AND NOT EXISTS(
            SELECT 1
            FROM public.truth_entity_snapshots t
            WHERE t.subject_type='COMPANY'
              AND t.subject_id=s.company_id
              AND t.profile_key='COMPANY_CORE_V1'
              AND (
                t.tenant_scope_organisation_id IS NULL
                OR t.tenant_scope_organisation_id=r.organisation_id
              )
          )
      )
    FROM public.anonymous_discovery_runs r
    WHERE r.id=p_run_id
  ),false);
$fn$;

REVOKE ALL ON FUNCTION public.marketroute_anonymous_discovery_research_cycle_ready_v1(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_anonymous_discovery_research_cycle_ready_v1(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.marketroute_claim_anonymous_discovery_extension_v1(p_worker_id text,p_at timestamptz DEFAULT now())
RETURNS TABLE(job_id uuid,run_id uuid,organisation_id uuid,campaign_id uuid,seller_business_id uuid,seller_name text,canonical_domain text,website_url text,objective_text text,target_market_text text,target_count integer,scoped_count integer,remaining_count integer,attempt_count integer,existing_domains text[])
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_job uuid;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF length(btrim(COALESCE(p_worker_id,'')))<3 THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_EXTENSION_WORKER_REQUIRED'; END IF;

  -- Seed/re-arm only after the currently scoped batch has completed its first
  -- research pass. This prevents the three bounded continuation attempts from
  -- being burned back-to-back before research can enrich the current batch.
  INSERT INTO public.anonymous_discovery_extension_jobs(
    run_id,organisation_id,campaign_id,status,available_at,cycle_policy_version
  )
  SELECT r.id,r.organisation_id,r.original_campaign_id,'PENDING',p_at,2
  FROM public.anonymous_discovery_runs r
  JOIN public.campaigns c ON c.id=r.original_campaign_id AND c.organisation_id=r.organisation_id
  WHERE r.status IN('ACTIVE','CLAIMED')
    AND r.original_campaign_id IS NOT NULL
    AND c.workflow_state='ACTIVE'
    AND r.research_expires_at>p_at
    AND NOT public.marketroute_paid_entitlement_active_v1(r.organisation_id,p_at)
    AND public.marketroute_anonymous_discovery_research_cycle_ready_v1(r.id)
    AND (
      SELECT count(DISTINCT s.company_id)
      FROM public.organisation_company_scopes s
      WHERE s.organisation_id=r.organisation_id
        AND s.campaign_id=r.original_campaign_id
        AND s.scope_kind='CAMPAIGN'
    )<r.target_count
  ON CONFLICT ON CONSTRAINT anonymous_discovery_extension_jobs_run_id_key DO UPDATE SET
    campaign_id=EXCLUDED.campaign_id,
    cycle_policy_version=2,
    attempt_count=CASE
      WHEN anonymous_discovery_extension_jobs.cycle_policy_version<2
       AND anonymous_discovery_extension_jobs.status='EXHAUSTED'
      THEN 0
      ELSE anonymous_discovery_extension_jobs.attempt_count
    END,
    status=CASE
      WHEN anonymous_discovery_extension_jobs.cycle_policy_version<2
       AND anonymous_discovery_extension_jobs.status='EXHAUSTED'
      THEN 'PENDING'
      WHEN anonymous_discovery_extension_jobs.status IN('SUCCEEDED','EXHAUSTED')
       AND anonymous_discovery_extension_jobs.attempt_count<3
      THEN 'PENDING'
      ELSE anonymous_discovery_extension_jobs.status
    END,
    available_at=CASE
      WHEN anonymous_discovery_extension_jobs.cycle_policy_version<2
       AND anonymous_discovery_extension_jobs.status='EXHAUSTED'
      THEN p_at
      WHEN anonymous_discovery_extension_jobs.status IN('SUCCEEDED','EXHAUSTED')
       AND anonymous_discovery_extension_jobs.attempt_count<3
      THEN p_at
      ELSE anonymous_discovery_extension_jobs.available_at
    END,
    last_error_code=CASE
      WHEN anonymous_discovery_extension_jobs.cycle_policy_version<2
       AND anonymous_discovery_extension_jobs.status='EXHAUSTED'
      THEN 'MARKETROUTE_ANONYMOUS_EXTENSION_REARMED_FOR_RESEARCH_CYCLE_POLICY'
      ELSE anonymous_discovery_extension_jobs.last_error_code
    END;

  UPDATE public.anonymous_discovery_extension_jobs j
  SET status='DEFERRED',worker_id=NULL,lease_expires_at=NULL,available_at=p_at,
      last_error_code='MARKETROUTE_ANONYMOUS_EXTENSION_LEASE_RECOVERED'
  WHERE j.status='RUNNING' AND j.lease_expires_at<p_at;

  SELECT j.id INTO v_job
  FROM public.anonymous_discovery_extension_jobs j
  JOIN public.anonymous_discovery_runs r ON r.id=j.run_id AND r.original_campaign_id=j.campaign_id
  JOIN public.campaigns c ON c.id=j.campaign_id AND c.organisation_id=j.organisation_id
  WHERE j.status IN('PENDING','DEFERRED')
    AND j.available_at<=p_at
    AND j.attempt_count<3
    AND r.status IN('ACTIVE','CLAIMED')
    AND r.research_expires_at>p_at
    AND c.workflow_state='ACTIVE'
    AND NOT public.marketroute_paid_entitlement_active_v1(j.organisation_id,p_at)
    AND public.marketroute_anonymous_discovery_research_cycle_ready_v1(r.id)
    AND (
      SELECT count(DISTINCT s.company_id)
      FROM public.organisation_company_scopes s
      WHERE s.organisation_id=j.organisation_id
        AND s.campaign_id=j.campaign_id
        AND s.scope_kind='CAMPAIGN'
    )<r.target_count
  ORDER BY j.available_at,j.created_at,j.id
  FOR UPDATE OF j SKIP LOCKED
  LIMIT 1;

  IF v_job IS NULL THEN RETURN; END IF;

  UPDATE public.anonymous_discovery_extension_jobs
  SET status='RUNNING',
      attempt_count=anonymous_discovery_extension_jobs.attempt_count+1,
      cycle_policy_version=2,
      worker_id=left(btrim(p_worker_id),200),
      lease_expires_at=p_at+interval '5 minutes',
      last_error_code=NULL
  WHERE id=v_job;

  RETURN QUERY
  SELECT j.id,r.id,r.organisation_id,j.campaign_id,r.seller_business_id,s.name,s.canonical_domain,s.website_url,
    COALESCE(r.objective_text,'Win new B2B contracts'),COALESCE(r.target_market_text,'Target market'),r.target_count,
    (SELECT count(DISTINCT sc.company_id)::int FROM public.organisation_company_scopes sc WHERE sc.organisation_id=r.organisation_id AND sc.campaign_id=j.campaign_id AND sc.scope_kind='CAMPAIGN'),
    greatest(0,r.target_count-(SELECT count(DISTINCT sc.company_id)::int FROM public.organisation_company_scopes sc WHERE sc.organisation_id=r.organisation_id AND sc.campaign_id=j.campaign_id AND sc.scope_kind='CAMPAIGN')),
    j.attempt_count,
    COALESCE((SELECT array_agg(DISTINCT lower(cmp.canonical_domain) ORDER BY lower(cmp.canonical_domain)) FROM public.organisation_company_scopes sc JOIN public.companies cmp ON cmp.id=sc.company_id WHERE sc.organisation_id=r.organisation_id AND sc.campaign_id=j.campaign_id AND sc.scope_kind='CAMPAIGN' AND cmp.canonical_domain IS NOT NULL),'{}'::text[])
  FROM public.anonymous_discovery_extension_jobs j
  JOIN public.anonymous_discovery_runs r ON r.id=j.run_id
  JOIN public.seller_businesses s ON s.id=r.seller_business_id AND s.organisation_id=r.organisation_id
  WHERE j.id=v_job;
END;
$fn$;

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
  UPDATE public.anonymous_discovery_extension_jobs
  SET status=v_status,
      cycle_policy_version=2,
      worker_id=NULL,
      lease_expires_at=NULL,
      available_at=CASE WHEN v_status='DEFERRED' THEN p_at+interval '2 minutes' ELSE available_at END,
      result_json=COALESCE(p_result_json,'{}'::jsonb) || jsonb_build_object(
        'scopedCount',v_count,
        'targetCount',v_run.target_count,
        'completedAt',p_at,
        'quotaCyclePolicyVersion',2,
        'researchCycleGated',true
      )
  WHERE id=p_job_id;
  RETURN QUERY SELECT v_status,v_count,v_run.target_count;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.marketroute_fail_anonymous_discovery_extension_v1(p_job_id uuid,p_worker_id text,p_error_code text,p_retryable boolean,p_at timestamptz DEFAULT now())
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_job public.anonymous_discovery_extension_jobs%ROWTYPE;
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT * INTO v_job FROM public.anonymous_discovery_extension_jobs WHERE id=p_job_id FOR UPDATE;
  IF NOT FOUND OR v_job.status<>'RUNNING' OR v_job.worker_id IS DISTINCT FROM left(btrim(COALESCE(p_worker_id,'')),200) THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_EXTENSION_LEASE_INVALID'; END IF;
  UPDATE public.anonymous_discovery_extension_jobs
  SET status=CASE WHEN COALESCE(p_retryable,false) AND attempt_count<3 THEN 'DEFERRED' ELSE 'FAILED' END,
      cycle_policy_version=2,
      worker_id=NULL,
      lease_expires_at=NULL,
      available_at=CASE WHEN COALESCE(p_retryable,false) AND attempt_count<3 THEN p_at+interval '2 minutes' ELSE available_at END,
      last_error_code=left(COALESCE(NULLIF(btrim(p_error_code),''),'MARKETROUTE_ANONYMOUS_EXTENSION_FAILED'),240)
  WHERE id=p_job_id;
END;
$fn$;

REVOKE ALL ON FUNCTION public.marketroute_claim_anonymous_discovery_extension_v1(text,timestamptz) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_complete_anonymous_discovery_extension_v1(uuid,text,jsonb,timestamptz) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_fail_anonymous_discovery_extension_v1(uuid,text,text,boolean,timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_claim_anonymous_discovery_extension_v1(text,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_complete_anonymous_discovery_extension_v1(uuid,text,jsonb,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_fail_anonymous_discovery_extension_v1(uuid,text,text,boolean,timestamptz) TO service_role;

INSERT INTO public.marketroute_schema_releases(release_key,build_number,constitution_version,metadata_json)
VALUES(
  'MARKETROUTE_V2_RC_ANONYMOUS_DISCOVERY_QUOTA_REFILL_CYCLE',59,'MRV2-CONSTITUTION-1.0.0',
  jsonb_build_object(
    'migration','0059_anonymous_discovery_quota_refill_cycle.sql',
    'new_authority_writer',false,
    'authority_semantics_unchanged',true,
    'anonymous_target_company_ceiling',10,
    'anonymous_lifetime_ai_budget_usd',1.00,
    'anonymous_research_window_hours',12,
    'extension_attempt_ceiling',3,
    'provider_backed_extension_attempts',2,
    'research_cycle_gated_refill',true,
    'company_core_truth_snapshot_is_cycle_marker',true,
    'pre_fix_exhausted_jobs_rearmed_once',true,
    'paid_conversion_stops_refill',true,
    'original_campaign_lineage_required',true,
    'autonomous_delivery_enabled',false
  )
)
ON CONFLICT(release_key) DO NOTHING;

NOTIFY pgrst,'reload schema';
COMMIT;
