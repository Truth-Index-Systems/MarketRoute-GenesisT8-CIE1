BEGIN;

-- MarketRoute V2 RC: launch certification + anonymous Discovery refill liveness.
-- This is orchestration-only. It does not grant commercial authority and it does not
-- write R4, R5, R6 or authority_records. It makes the ready-opportunity refill cycle
-- terminally budget-aware so a free Discovery run cannot remain "researching" after
-- its immutable lifetime research envelope can no longer advance the scoped batch.

ALTER TABLE public.anonymous_discovery_extension_jobs
  DROP CONSTRAINT IF EXISTS anonymous_discovery_extension_jobs_cycle_policy_version_check;
ALTER TABLE public.anonymous_discovery_extension_jobs
  ADD CONSTRAINT anonymous_discovery_extension_jobs_cycle_policy_version_check
  CHECK (cycle_policy_version BETWEEN 1 AND 4);

CREATE OR REPLACE FUNCTION public.marketroute_anonymous_discovery_budget_state_v1(
  p_run_id uuid,
  p_at timestamptz DEFAULT now()
)
RETURNS TABLE(
  budget_state text,
  remaining_usd numeric,
  active_research_jobs integer,
  zero_cost_waiting integer,
  minimum_positive_waiting_cost_usd numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
  WITH run_scope AS (
    SELECT r.id,r.organisation_id,r.original_campaign_id,r.lifetime_budget_usd,r.research_expires_at
    FROM public.anonymous_discovery_runs r
    WHERE r.id=p_run_id
  ),
  committed AS (
    SELECT COALESCE(sum(e.amount_usd),0)::numeric AS amount
    FROM run_scope r
    LEFT JOIN public.research_budget_events e
      ON e.organisation_id=r.organisation_id
     AND e.campaign_id=r.original_campaign_id
     AND e.event_type='COMMIT'
  ),
  reserved AS (
    SELECT COALESCE(sum(e.amount_usd),0)::numeric AS amount
    FROM run_scope r
    LEFT JOIN public.research_budget_events e
      ON e.organisation_id=r.organisation_id
     AND e.campaign_id=r.original_campaign_id
     AND e.event_type='RESERVE'
     AND NOT EXISTS(
       SELECT 1
       FROM public.research_budget_events x
       WHERE x.work_unit_id=e.work_unit_id
         AND x.attempt_number=e.attempt_number
         AND x.event_type IN('COMMIT','RELEASE')
     )
  ),
  queue AS (
    SELECT
      count(*) FILTER (WHERE j.status IN('RESERVED','RUNNING'))::int AS active_jobs,
      count(*) FILTER (WHERE j.status IN('PENDING','DEFERRED') AND w.cost_ceiling_usd=0)::int AS zero_waiting,
      min(w.cost_ceiling_usd) FILTER (WHERE j.status IN('PENDING','DEFERRED') AND w.cost_ceiling_usd>0) AS min_positive,
      bool_or(j.status='CANCELLED' AND j.last_error_code='MARKETROUTE_ANONYMOUS_RESEARCH_BUDGET_EXHAUSTED') AS budget_cancel_seen
    FROM run_scope r
    LEFT JOIN public.research_work_units w
      ON w.organisation_id=r.organisation_id
     AND w.campaign_id=r.original_campaign_id
    LEFT JOIN public.background_jobs j ON j.id=w.background_job_id
  ),
  state AS (
    SELECT
      r.*,
      GREATEST(0,r.lifetime_budget_usd-(SELECT amount FROM committed)-(SELECT amount FROM reserved))::numeric AS remaining,
      COALESCE(q.active_jobs,0)::int AS active_jobs,
      COALESCE(q.zero_waiting,0)::int AS zero_waiting,
      q.min_positive,
      COALESCE(q.budget_cancel_seen,false) AS budget_cancel_seen
    FROM run_scope r
    CROSS JOIN queue q
  )
  SELECT
    CASE
      WHEN s.research_expires_at<=COALESCE(p_at,now()) THEN 'WINDOW_CLOSED'
      WHEN s.active_jobs>0 OR s.zero_waiting>0 THEN 'AVAILABLE'
      WHEN s.remaining<=0 AND (s.budget_cancel_seen OR s.min_positive IS NOT NULL) THEN 'EXHAUSTED'
      WHEN s.remaining>0 AND s.min_positive IS NOT NULL AND s.min_positive>s.remaining THEN 'INSUFFICIENT_FOR_WAITING_WORK'
      ELSE 'AVAILABLE'
    END,
    s.remaining,
    s.active_jobs,
    s.zero_waiting,
    s.min_positive
  FROM state s;
$fn$;

CREATE OR REPLACE FUNCTION public.marketroute_anonymous_discovery_budget_terminal_v1(
  p_run_id uuid,
  p_at timestamptz DEFAULT now()
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
  SELECT COALESCE((
    SELECT b.budget_state IN('WINDOW_CLOSED','EXHAUSTED','INSUFFICIENT_FOR_WAITING_WORK')
    FROM public.marketroute_anonymous_discovery_budget_state_v1(p_run_id,p_at) b
  ),false);
$fn$;

REVOKE ALL ON FUNCTION public.marketroute_anonymous_discovery_budget_state_v1(uuid,timestamptz) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_anonymous_discovery_budget_terminal_v1(uuid,timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_anonymous_discovery_budget_state_v1(uuid,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_anonymous_discovery_budget_terminal_v1(uuid,timestamptz) TO service_role;

CREATE OR REPLACE FUNCTION public.marketroute_claim_anonymous_discovery_extension_v1(p_worker_id text,p_at timestamptz DEFAULT now())
RETURNS TABLE(job_id uuid,run_id uuid,organisation_id uuid,campaign_id uuid,seller_business_id uuid,seller_name text,canonical_domain text,website_url text,objective_text text,target_market_text text,target_count integer,scoped_count integer,remaining_count integer,attempt_count integer,existing_domains text[])
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_job uuid;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF length(btrim(COALESCE(p_worker_id,'')))<3 THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_EXTENSION_WORKER_REQUIRED'; END IF;

  -- Seed a tracking job as soon as a run has a READY deficit. Unlike v3 this does
  -- not require the research-cycle marker first. That lets the same controller
  -- terminate truthfully if the batch becomes economically unable to finish.
  INSERT INTO public.anonymous_discovery_extension_jobs(
    run_id,organisation_id,campaign_id,status,available_at,cycle_policy_version
  )
  SELECT r.id,r.organisation_id,r.original_campaign_id,'PENDING',p_at,4
  FROM public.anonymous_discovery_runs r
  JOIN public.campaigns c ON c.id=r.original_campaign_id AND c.organisation_id=r.organisation_id
  WHERE r.status IN('ACTIVE','CLAIMED')
    AND r.original_campaign_id IS NOT NULL
    AND c.workflow_state='ACTIVE'
    AND NOT public.marketroute_paid_entitlement_active_v1(r.organisation_id,p_at)
    AND public.marketroute_anonymous_discovery_ready_count_v1(r.id,p_at)<r.target_count
  ON CONFLICT ON CONSTRAINT anonymous_discovery_extension_jobs_run_id_key DO UPDATE SET
    campaign_id=EXCLUDED.campaign_id,
    cycle_policy_version=4,
    attempt_count=CASE
      WHEN anonymous_discovery_extension_jobs.cycle_policy_version<4
       AND anonymous_discovery_extension_jobs.status IN('SUCCEEDED','EXHAUSTED')
      THEN 0
      ELSE anonymous_discovery_extension_jobs.attempt_count
    END,
    status=CASE
      WHEN anonymous_discovery_extension_jobs.cycle_policy_version<4
       AND anonymous_discovery_extension_jobs.status IN('SUCCEEDED','EXHAUSTED')
      THEN 'PENDING'
      ELSE anonymous_discovery_extension_jobs.status
    END,
    available_at=CASE
      WHEN anonymous_discovery_extension_jobs.cycle_policy_version<4
       AND anonymous_discovery_extension_jobs.status IN('SUCCEEDED','EXHAUSTED')
      THEN p_at
      ELSE anonymous_discovery_extension_jobs.available_at
    END,
    last_error_code=CASE
      WHEN anonymous_discovery_extension_jobs.cycle_policy_version<4
       AND anonymous_discovery_extension_jobs.status IN('SUCCEEDED','EXHAUSTED')
      THEN 'MARKETROUTE_ANONYMOUS_EXTENSION_REARMED_FOR_BUDGET_LIVENESS_POLICY'
      ELSE anonymous_discovery_extension_jobs.last_error_code
    END;

  -- Terminalise jobs that can no longer make progress. This runs before the
  -- research-cycle gate so "missing COMPANY_CORE" cannot deadlock an exhausted run.
  UPDATE public.anonymous_discovery_extension_jobs j
  SET status='EXHAUSTED',
      cycle_policy_version=4,
      worker_id=NULL,
      lease_expires_at=NULL,
      last_error_code=CASE
        WHEN public.marketroute_paid_entitlement_active_v1(j.organisation_id,p_at)
          THEN 'MARKETROUTE_ANONYMOUS_EXTENSION_STOPPED_PAID_CONVERSION'
        WHEN r.research_expires_at<=p_at
          THEN 'MARKETROUTE_ANONYMOUS_EXTENSION_RESEARCH_WINDOW_CLOSED'
        WHEN j.attempt_count>=3
          THEN 'MARKETROUTE_ANONYMOUS_EXTENSION_ATTEMPT_CEILING_REACHED'
        WHEN (SELECT count(DISTINCT s.company_id) FROM public.organisation_company_scopes s WHERE s.organisation_id=j.organisation_id AND s.campaign_id=j.campaign_id AND s.scope_kind='CAMPAIGN')>=LEAST(40,GREATEST(r.target_count,r.target_count*4))
          THEN 'MARKETROUTE_ANONYMOUS_EXTENSION_CANDIDATE_CEILING_REACHED'
        WHEN public.marketroute_anonymous_discovery_budget_terminal_v1(r.id,p_at)
          THEN 'MARKETROUTE_ANONYMOUS_EXTENSION_RESEARCH_CAPACITY_EXHAUSTED'
        ELSE 'MARKETROUTE_ANONYMOUS_EXTENSION_EXHAUSTED'
      END,
      result_json=COALESCE(j.result_json,'{}'::jsonb)||jsonb_build_object(
        'terminalAt',p_at,
        'readyCount',public.marketroute_anonymous_discovery_ready_count_v1(r.id,p_at),
        'readyTarget',r.target_count,
        'quotaCyclePolicyVersion',4,
        'terminallyBudgetAware',true,
        'completionMetric','AUTHORITY_READY_OPPORTUNITIES'
      )
  FROM public.anonymous_discovery_runs r
  WHERE r.id=j.run_id
    AND j.status IN('PENDING','DEFERRED','SUCCEEDED','EXHAUSTED')
    AND public.marketroute_anonymous_discovery_ready_count_v1(r.id,p_at)<r.target_count
    AND (
      public.marketroute_paid_entitlement_active_v1(j.organisation_id,p_at)
      OR r.research_expires_at<=p_at
      OR j.attempt_count>=3
      OR (SELECT count(DISTINCT s.company_id) FROM public.organisation_company_scopes s WHERE s.organisation_id=j.organisation_id AND s.campaign_id=j.campaign_id AND s.scope_kind='CAMPAIGN')>=LEAST(40,GREATEST(r.target_count,r.target_count*4))
      OR public.marketroute_anonymous_discovery_budget_terminal_v1(r.id,p_at)
    );

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
    AND NOT public.marketroute_anonymous_discovery_budget_terminal_v1(r.id,p_at)
    AND public.marketroute_anonymous_discovery_research_cycle_ready_v1(r.id)
    AND public.marketroute_anonymous_discovery_ready_count_v1(r.id,p_at)<r.target_count
    AND (
      SELECT count(DISTINCT s.company_id)
      FROM public.organisation_company_scopes s
      WHERE s.organisation_id=j.organisation_id
        AND s.campaign_id=j.campaign_id
        AND s.scope_kind='CAMPAIGN'
    ) < LEAST(40,GREATEST(r.target_count,r.target_count*4))
  ORDER BY j.available_at,j.created_at,j.id
  FOR UPDATE OF j SKIP LOCKED
  LIMIT 1;

  IF v_job IS NULL THEN RETURN; END IF;

  UPDATE public.anonymous_discovery_extension_jobs
  SET status='RUNNING',
      attempt_count=anonymous_discovery_extension_jobs.attempt_count+1,
      cycle_policy_version=4,
      worker_id=left(btrim(p_worker_id),200),
      lease_expires_at=p_at+interval '5 minutes',
      last_error_code=NULL
  WHERE id=v_job;

  RETURN QUERY
  SELECT j.id,r.id,r.organisation_id,j.campaign_id,r.seller_business_id,s.name,s.canonical_domain,s.website_url,
    COALESCE(r.objective_text,'Win new B2B contracts'),COALESCE(r.target_market_text,'Target market'),r.target_count,
    (SELECT count(DISTINCT sc.company_id)::int FROM public.organisation_company_scopes sc WHERE sc.organisation_id=r.organisation_id AND sc.campaign_id=j.campaign_id AND sc.scope_kind='CAMPAIGN'),
    greatest(0,r.target_count-public.marketroute_anonymous_discovery_ready_count_v1(r.id,p_at)),
    j.attempt_count,
    COALESCE((SELECT array_agg(DISTINCT lower(cmp.canonical_domain) ORDER BY lower(cmp.canonical_domain)) FROM public.organisation_company_scopes sc JOIN public.companies cmp ON cmp.id=sc.company_id WHERE sc.organisation_id=r.organisation_id AND sc.campaign_id=j.campaign_id AND sc.scope_kind='CAMPAIGN' AND cmp.canonical_domain IS NOT NULL),'{}'::text[])
  FROM public.anonymous_discovery_extension_jobs j
  JOIN public.anonymous_discovery_runs r ON r.id=j.run_id
  JOIN public.seller_businesses s ON s.id=r.seller_business_id AND s.organisation_id=r.organisation_id
  WHERE j.id=v_job;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.marketroute_link_anonymous_discovery_extension_company_v1(p_job_id uuid,p_worker_id text,p_name text,p_domain text,p_website_url text,p_country_code text,p_at timestamptz DEFAULT now())
RETURNS TABLE(company_id uuid,scoped_count integer,target_count integer,inserted_scope boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE
  v_job public.anonymous_discovery_extension_jobs%ROWTYPE;v_run public.anonymous_discovery_runs%ROWTYPE;
  v_domain text;v_company uuid;v_before integer;v_after integer;v_seller_domain text;v_candidate_ceiling integer;
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT * INTO v_job FROM public.anonymous_discovery_extension_jobs WHERE id=p_job_id FOR UPDATE;
  IF NOT FOUND OR v_job.status<>'RUNNING' OR v_job.worker_id IS DISTINCT FROM left(btrim(COALESCE(p_worker_id,'')),200) OR v_job.lease_expires_at<=p_at THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_EXTENSION_LEASE_INVALID'; END IF;
  SELECT * INTO v_run FROM public.anonymous_discovery_runs WHERE id=v_job.run_id FOR UPDATE;
  IF v_run.status NOT IN('ACTIVE','CLAIMED') OR v_run.research_expires_at<=p_at OR public.marketroute_paid_entitlement_active_v1(v_run.organisation_id,p_at) THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_EXTENSION_RUN_NOT_ELIGIBLE'; END IF;
  IF public.marketroute_anonymous_discovery_budget_terminal_v1(v_run.id,p_at) THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_EXTENSION_RESEARCH_CAPACITY_EXHAUSTED'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.campaigns c WHERE c.id=v_job.campaign_id AND c.organisation_id=v_run.organisation_id AND c.workflow_state='ACTIVE') THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_EXTENSION_CAMPAIGN_NOT_ACTIVE'; END IF;
  SELECT lower(canonical_domain) INTO v_seller_domain FROM public.seller_businesses WHERE id=v_run.seller_business_id AND organisation_id=v_run.organisation_id;
  v_domain:=lower(regexp_replace(btrim(COALESCE(p_domain,'')),'^www[.]','','i'));
  IF v_domain !~ '^[a-z0-9][a-z0-9.-]*[.][a-z]{2,63}$' OR v_domain~'[.][.]' OR v_domain=v_seller_domain THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_EXTENSION_DOMAIN_INVALID'; END IF;
  v_candidate_ceiling:=LEAST(40,GREATEST(v_run.target_count,v_run.target_count*4));
  SELECT count(DISTINCT s.company_id)::int INTO v_before FROM public.organisation_company_scopes s WHERE s.organisation_id=v_run.organisation_id AND s.campaign_id=v_job.campaign_id AND s.scope_kind='CAMPAIGN';
  IF v_before>=v_candidate_ceiling THEN RETURN; END IF;
  SELECT id INTO v_company FROM public.companies WHERE canonical_domain=v_domain LIMIT 1;
  IF v_company IS NULL THEN
    INSERT INTO public.companies(canonical_name,canonical_domain,website_url,country_code,lifecycle_state)
    VALUES(left(btrim(COALESCE(p_name,'')),240),v_domain,COALESCE(NULLIF(btrim(COALESCE(p_website_url,'')),''),'https://' || v_domain),CASE WHEN upper(COALESCE(p_country_code,''))~'^[A-Z]{2}$' THEN upper(p_country_code) ELSE NULL END,'ACTIVE')
    RETURNING id INTO v_company;
  END IF;
  INSERT INTO public.organisation_company_scopes(organisation_id,company_id,campaign_id,scope_kind)
  VALUES(v_run.organisation_id,v_company,v_job.campaign_id,'CAMPAIGN') ON CONFLICT DO NOTHING;
  SELECT count(DISTINCT s.company_id)::int INTO v_after FROM public.organisation_company_scopes s WHERE s.organisation_id=v_run.organisation_id AND s.campaign_id=v_job.campaign_id AND s.scope_kind='CAMPAIGN';
  IF v_after>v_candidate_ceiling THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_EXTENSION_CANDIDATE_CEILING_EXCEEDED'; END IF;
  RETURN QUERY SELECT v_company,v_after,v_run.target_count,(v_after>v_before);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.marketroute_complete_anonymous_discovery_extension_v1(p_job_id uuid,p_worker_id text,p_result_json jsonb,p_at timestamptz DEFAULT now())
RETURNS TABLE(status text,scoped_count integer,target_count integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE
  v_job public.anonymous_discovery_extension_jobs%ROWTYPE;v_run public.anonymous_discovery_runs%ROWTYPE;
  v_count integer;v_ready integer;v_status text;v_candidate_ceiling integer;v_budget_state text;v_budget_remaining numeric;v_terminal_reason text;
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT * INTO v_job FROM public.anonymous_discovery_extension_jobs WHERE id=p_job_id FOR UPDATE;
  IF NOT FOUND OR v_job.status<>'RUNNING' OR v_job.worker_id IS DISTINCT FROM left(btrim(COALESCE(p_worker_id,'')),200) THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_EXTENSION_LEASE_INVALID'; END IF;
  SELECT * INTO v_run FROM public.anonymous_discovery_runs WHERE id=v_job.run_id;
  SELECT count(DISTINCT s.company_id)::int INTO v_count FROM public.organisation_company_scopes s WHERE s.organisation_id=v_job.organisation_id AND s.campaign_id=v_job.campaign_id AND s.scope_kind='CAMPAIGN';
  v_ready:=public.marketroute_anonymous_discovery_ready_count_v1(v_run.id,p_at);
  v_candidate_ceiling:=LEAST(40,GREATEST(v_run.target_count,v_run.target_count*4));
  SELECT b.budget_state,b.remaining_usd INTO v_budget_state,v_budget_remaining FROM public.marketroute_anonymous_discovery_budget_state_v1(v_run.id,p_at) b;
  v_status:=CASE
    WHEN v_ready>=v_run.target_count THEN 'SUCCEEDED'
    WHEN public.marketroute_paid_entitlement_active_v1(v_run.organisation_id,p_at) THEN 'EXHAUSTED'
    WHEN v_budget_state IN('WINDOW_CLOSED','EXHAUSTED','INSUFFICIENT_FOR_WAITING_WORK') THEN 'EXHAUSTED'
    WHEN v_job.attempt_count>=3 OR v_run.research_expires_at<=p_at OR v_count>=v_candidate_ceiling THEN 'EXHAUSTED'
    ELSE 'DEFERRED'
  END;
  v_terminal_reason:=CASE
    WHEN v_status<>'EXHAUSTED' THEN NULL
    WHEN public.marketroute_paid_entitlement_active_v1(v_run.organisation_id,p_at) THEN 'MARKETROUTE_ANONYMOUS_EXTENSION_STOPPED_PAID_CONVERSION'
    WHEN v_budget_state IN('EXHAUSTED','INSUFFICIENT_FOR_WAITING_WORK') THEN 'MARKETROUTE_ANONYMOUS_EXTENSION_RESEARCH_CAPACITY_EXHAUSTED'
    WHEN v_budget_state='WINDOW_CLOSED' OR v_run.research_expires_at<=p_at THEN 'MARKETROUTE_ANONYMOUS_EXTENSION_RESEARCH_WINDOW_CLOSED'
    WHEN v_job.attempt_count>=3 THEN 'MARKETROUTE_ANONYMOUS_EXTENSION_ATTEMPT_CEILING_REACHED'
    WHEN v_count>=v_candidate_ceiling THEN 'MARKETROUTE_ANONYMOUS_EXTENSION_CANDIDATE_CEILING_REACHED'
    ELSE 'MARKETROUTE_ANONYMOUS_EXTENSION_EXHAUSTED'
  END;
  UPDATE public.anonymous_discovery_extension_jobs
  SET status=v_status,
      cycle_policy_version=4,
      worker_id=NULL,
      lease_expires_at=NULL,
      available_at=CASE WHEN v_status='DEFERRED' THEN p_at+interval '2 minutes' ELSE available_at END,
      last_error_code=v_terminal_reason,
      result_json=COALESCE(p_result_json,'{}'::jsonb) || jsonb_build_object(
        'scopedCount',v_count,
        'readyCount',v_ready,
        'readyTarget',v_run.target_count,
        'candidateCeiling',v_candidate_ceiling,
        'completedAt',p_at,
        'quotaCyclePolicyVersion',4,
        'completionMetric','AUTHORITY_READY_OPPORTUNITIES',
        'researchCycleGated',true,
        'terminallyBudgetAware',true,
        'budgetState',COALESCE(v_budget_state,'UNKNOWN'),
        'budgetRemainingUsd',v_budget_remaining,
        'terminalReason',v_terminal_reason
      )
  WHERE id=p_job_id;
  RETURN QUERY SELECT v_status,v_count,v_run.target_count;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.marketroute_fail_anonymous_discovery_extension_v1(p_job_id uuid,p_worker_id text,p_error_code text,p_retryable boolean,p_at timestamptz DEFAULT now())
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_job public.anonymous_discovery_extension_jobs%ROWTYPE;v_terminal boolean:=false;
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT * INTO v_job FROM public.anonymous_discovery_extension_jobs WHERE id=p_job_id FOR UPDATE;
  IF NOT FOUND OR v_job.status<>'RUNNING' OR v_job.worker_id IS DISTINCT FROM left(btrim(COALESCE(p_worker_id,'')),200) THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_EXTENSION_LEASE_INVALID'; END IF;
  v_terminal:=public.marketroute_anonymous_discovery_budget_terminal_v1(v_job.run_id,p_at);
  UPDATE public.anonymous_discovery_extension_jobs
  SET status=CASE WHEN COALESCE(p_retryable,false) AND attempt_count<3 AND NOT v_terminal THEN 'DEFERRED' ELSE CASE WHEN v_terminal THEN 'EXHAUSTED' ELSE 'FAILED' END END,
      cycle_policy_version=4,
      worker_id=NULL,
      lease_expires_at=NULL,
      available_at=CASE WHEN COALESCE(p_retryable,false) AND attempt_count<3 AND NOT v_terminal THEN p_at+interval '2 minutes' ELSE available_at END,
      last_error_code=CASE WHEN v_terminal THEN 'MARKETROUTE_ANONYMOUS_EXTENSION_RESEARCH_CAPACITY_EXHAUSTED' ELSE left(COALESCE(NULLIF(btrim(p_error_code),''),'MARKETROUTE_ANONYMOUS_EXTENSION_FAILED'),240) END
  WHERE id=p_job_id;
END;
$fn$;

REVOKE ALL ON FUNCTION public.marketroute_claim_anonymous_discovery_extension_v1(text,timestamptz) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_link_anonymous_discovery_extension_company_v1(uuid,text,text,text,text,text,timestamptz) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_complete_anonymous_discovery_extension_v1(uuid,text,jsonb,timestamptz) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_fail_anonymous_discovery_extension_v1(uuid,text,text,boolean,timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_claim_anonymous_discovery_extension_v1(text,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_link_anonymous_discovery_extension_company_v1(uuid,text,text,text,text,text,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_complete_anonymous_discovery_extension_v1(uuid,text,jsonb,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_fail_anonymous_discovery_extension_v1(uuid,text,text,boolean,timestamptz) TO service_role;

INSERT INTO public.marketroute_schema_releases(release_key,build_number,constitution_version,metadata_json)
VALUES(
  'MARKETROUTE_V2_RC_LAUNCH_CERTIFICATION_REFILL_LIVENESS',61,'MRV2-CONSTITUTION-1.0.0',
  jsonb_build_object(
    'migration','0061_anonymous_discovery_refill_liveness_launch_certification.sql',
    'new_authority_writer',false,
    'authority_semantics_unchanged',true,
    'anonymous_ready_opportunity_target',10,
    'anonymous_free_opportunity_limit',8,
    'anonymous_locked_teaser_target',2,
    'candidate_pool_ceiling',40,
    'extension_attempt_ceiling',3,
    'completion_metric','AUTHORITY_READY_OPPORTUNITIES',
    'budget_terminal_liveness',true,
    'budget_insufficient_for_waiting_work_terminal',true,
    'research_cycle_deadlock_removed',true,
    'paid_conversion_stops_refill',true,
    'original_campaign_lineage_required',true,
    'autonomous_delivery_enabled',false
  )
)
ON CONFLICT(release_key) DO NOTHING;

NOTIFY pgrst,'reload schema';
COMMIT;
