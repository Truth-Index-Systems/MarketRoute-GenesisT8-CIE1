BEGIN;

-- MarketRoute V2 RC: paid entitlement transition + commercial lifecycle hardening.
-- Orchestration and entitlement only. This migration creates no Truth/R4/R5/R6
-- authority writer and does not alter authority semantics.

CREATE OR REPLACE FUNCTION public.marketroute_campaign_authority_ready_count_v1(
  p_organisation_id uuid,p_campaign_id uuid,p_at timestamptz DEFAULT now()
) RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
  SELECT COALESCE(count(DISTINCT o.company_id),0)::int
  FROM public.opportunities o
  WHERE o.organisation_id=p_organisation_id
    AND o.campaign_id=p_campaign_id
    AND o.workflow_state IN('REVIEWABLE','APPROVED','ENGAGED')
    AND public.marketroute_authority_ready_v1(o.organisation_id,o.campaign_id,o.company_id,COALESCE(p_at,now()));
$fn$;

CREATE OR REPLACE FUNCTION public.marketroute_campaign_research_cycle_ready_v1(
  p_organisation_id uuid,p_campaign_id uuid
) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
  -- A refill cycle may widen only after every currently scoped company has had a
  -- campaign-specific research plan since it entered this campaign and that plan's
  -- queued work has settled. A pre-existing global COMPANY_CORE snapshot alone is
  -- not sufficient: otherwise a dense Genesis-bank company could cause repeated
  -- widening before its campaign-specific R4/R5/R6 work has had a chance to run.
  SELECT NOT EXISTS(
    SELECT 1
    FROM public.organisation_company_scopes s
    WHERE s.organisation_id=p_organisation_id
      AND s.campaign_id=p_campaign_id
      AND s.scope_kind='CAMPAIGN'
      AND (
        NOT EXISTS(
          SELECT 1
          FROM public.research_plan_runs p
          WHERE p.organisation_id=s.organisation_id
            AND p.campaign_id=s.campaign_id
            AND p.company_id=s.company_id
            AND p.reference_time>=s.created_at
        )
        OR EXISTS(
          SELECT 1
          FROM public.research_plan_runs p
          JOIN public.research_work_units w ON w.plan_id=p.id
          JOIN public.background_jobs j ON j.id=w.background_job_id
          WHERE p.organisation_id=s.organisation_id
            AND p.campaign_id=s.campaign_id
            AND p.company_id=s.company_id
            AND p.reference_time>=s.created_at
            AND j.status IN('PENDING','DEFERRED','RUNNING')
        )
      )
  );
$fn$;

CREATE OR REPLACE FUNCTION public.marketroute_campaign_research_entitled_v1(
  p_organisation_id uuid,p_campaign_id uuid,p_at timestamptz DEFAULT now()
) RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_limit integer;v_rank integer;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.campaigns c WHERE c.organisation_id=p_organisation_id AND c.id=p_campaign_id AND c.workflow_state<>'ARCHIVED') THEN RETURN false; END IF;
  IF public.marketroute_paid_entitlement_active_v1(p_organisation_id,p_at) THEN
    SELECT p.active_market_limit INTO v_limit
    FROM public.organisation_commercial_entitlements e
    JOIN public.marketroute_plan_catalog p ON p.plan_code=e.plan_code
    WHERE e.organisation_id=p_organisation_id AND e.status='ACTIVE'
      AND e.plan_code IN('STARTER','GROWTH','SCALE','LEGACY_FULL')
      AND (e.current_period_start IS NULL OR e.current_period_start<=p_at)
      AND (e.current_period_end IS NULL OR e.current_period_end>p_at)
    LIMIT 1;
    SELECT count(*)::int INTO v_rank
    FROM public.campaigns c
    WHERE c.organisation_id=p_organisation_id AND c.workflow_state<>'ARCHIVED'
      AND (c.created_at,c.id) <= (
        SELECT cx.created_at,cx.id FROM public.campaigns cx
        WHERE cx.organisation_id=p_organisation_id AND cx.id=p_campaign_id
      );
    RETURN COALESCE(v_rank,2147483647)<=COALESCE(v_limit,0);
  END IF;
  RETURN EXISTS(
    SELECT 1 FROM public.anonymous_discovery_runs r
    WHERE r.organisation_id=p_organisation_id
      AND r.original_campaign_id=p_campaign_id
      AND r.status IN('ACTIVE','CLAIMED')
      AND r.research_expires_at>p_at
      AND NOT public.marketroute_anonymous_discovery_budget_terminal_v1(r.id,p_at)
  );
END;$fn$;

REVOKE ALL ON FUNCTION public.marketroute_campaign_authority_ready_count_v1(uuid,uuid,timestamptz) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_campaign_research_cycle_ready_v1(uuid,uuid) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_campaign_research_entitled_v1(uuid,uuid,timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_campaign_authority_ready_count_v1(uuid,uuid,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_campaign_research_cycle_ready_v1(uuid,uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_campaign_research_entitled_v1(uuid,uuid,timestamptz) TO service_role;

-- Generic paid refill controller. It scopes research candidates only; Truth and
-- authority layers still decide whether any candidate becomes an opportunity.
CREATE TABLE IF NOT EXISTS public.paid_campaign_refill_jobs(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organisation_id uuid NOT NULL REFERENCES public.organisations(id) ON DELETE RESTRICT,
  campaign_id uuid NOT NULL,
  target_count integer NOT NULL DEFAULT 10 CHECK(target_count BETWEEN 1 AND 50),
  candidate_ceiling integer NOT NULL DEFAULT 60 CHECK(candidate_ceiling BETWEEN 10 AND 250),
  status text NOT NULL CHECK(status IN('PENDING','RUNNING','DEFERRED','SUCCEEDED','EXHAUSTED','FAILED')),
  attempt_count integer NOT NULL DEFAULT 0 CHECK(attempt_count BETWEEN 0 AND 20),
  available_at timestamptz NOT NULL DEFAULT now(),
  worker_id text,
  lease_expires_at timestamptz,
  last_error_code text,
  result_json jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(result_json)='object'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(organisation_id,campaign_id),
  CONSTRAINT paid_campaign_refill_campaign_scope_fk FOREIGN KEY(organisation_id,campaign_id)
    REFERENCES public.campaigns(organisation_id,id) ON DELETE RESTRICT
);
CREATE INDEX IF NOT EXISTS paid_campaign_refill_claim_idx ON public.paid_campaign_refill_jobs(status,available_at,created_at);
ALTER TABLE public.paid_campaign_refill_jobs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.paid_campaign_refill_jobs FROM PUBLIC,anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION public.marketroute_claim_paid_campaign_refill_v1(p_worker_id text,p_at timestamptz DEFAULT now())
RETURNS TABLE(job_id uuid,organisation_id uuid,campaign_id uuid,seller_business_id uuid,seller_name text,canonical_domain text,website_url text,objective_text text,target_market_text text,target_count integer,scoped_count integer,remaining_count integer,attempt_count integer,existing_domains text[])
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_job uuid;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF length(btrim(COALESCE(p_worker_id,'')))<3 THEN RAISE EXCEPTION 'MARKETROUTE_PAID_REFILL_WORKER_REQUIRED'; END IF;

  INSERT INTO public.paid_campaign_refill_jobs(organisation_id,campaign_id,target_count,candidate_ceiling,status,available_at)
  SELECT c.organisation_id,c.id,10,60,'PENDING',p_at
  FROM public.campaigns c
  JOIN public.research_budget_policies rp ON rp.organisation_id=c.organisation_id AND rp.campaign_id=c.id AND rp.enabled=true
  WHERE c.workflow_state='ACTIVE'
    AND public.marketroute_paid_entitlement_active_v1(c.organisation_id,p_at)
    AND public.marketroute_campaign_research_entitled_v1(c.organisation_id,c.id,p_at)
    AND public.marketroute_campaign_authority_ready_count_v1(c.organisation_id,c.id,p_at)<10
    AND (SELECT count(DISTINCT s.company_id) FROM public.organisation_company_scopes s WHERE s.organisation_id=c.organisation_id AND s.campaign_id=c.id AND s.scope_kind='CAMPAIGN')<60
  ON CONFLICT(organisation_id,campaign_id) DO UPDATE SET
    status=CASE
      WHEN paid_campaign_refill_jobs.status='SUCCEEDED' THEN 'DEFERRED'
      WHEN paid_campaign_refill_jobs.status='EXHAUSTED'
        AND paid_campaign_refill_jobs.last_error_code='MARKETROUTE_PAID_REFILL_ENTITLEMENT_INACTIVE'
      THEN 'DEFERRED'
      ELSE paid_campaign_refill_jobs.status
    END,
    -- A completed refill reaching ten ready opportunities is one bounded episode.
    -- If evidence later decays below target, or paid entitlement is restored, start a
    -- fresh attempt window without ever resetting the lifetime candidate ceiling.
    attempt_count=CASE
      WHEN paid_campaign_refill_jobs.status='SUCCEEDED' THEN 0
      WHEN paid_campaign_refill_jobs.status='EXHAUSTED'
        AND paid_campaign_refill_jobs.last_error_code='MARKETROUTE_PAID_REFILL_ENTITLEMENT_INACTIVE'
      THEN 0
      ELSE paid_campaign_refill_jobs.attempt_count
    END,
    available_at=CASE
      WHEN paid_campaign_refill_jobs.status='SUCCEEDED' THEN p_at
      WHEN paid_campaign_refill_jobs.status='EXHAUSTED'
        AND paid_campaign_refill_jobs.last_error_code='MARKETROUTE_PAID_REFILL_ENTITLEMENT_INACTIVE'
      THEN p_at
      ELSE paid_campaign_refill_jobs.available_at
    END,
    last_error_code=CASE
      WHEN paid_campaign_refill_jobs.status='SUCCEEDED' THEN NULL
      WHEN paid_campaign_refill_jobs.status='EXHAUSTED'
        AND paid_campaign_refill_jobs.last_error_code='MARKETROUTE_PAID_REFILL_ENTITLEMENT_INACTIVE'
      THEN NULL
      ELSE paid_campaign_refill_jobs.last_error_code
    END,
    updated_at=p_at;

  UPDATE public.paid_campaign_refill_jobs j
  SET status='EXHAUSTED',worker_id=NULL,lease_expires_at=NULL,last_error_code='MARKETROUTE_PAID_REFILL_ENTITLEMENT_INACTIVE',updated_at=p_at
  WHERE j.status IN('PENDING','DEFERRED','RUNNING')
    AND NOT public.marketroute_paid_entitlement_active_v1(j.organisation_id,p_at);

  UPDATE public.paid_campaign_refill_jobs j
  SET status='DEFERRED',worker_id=NULL,lease_expires_at=NULL,available_at=p_at,last_error_code='MARKETROUTE_PAID_REFILL_LEASE_RECOVERED',updated_at=p_at
  WHERE j.status='RUNNING' AND j.lease_expires_at<p_at;

  SELECT j.id INTO v_job
  FROM public.paid_campaign_refill_jobs j
  JOIN public.campaigns c ON c.id=j.campaign_id AND c.organisation_id=j.organisation_id
  JOIN public.research_budget_policies rp ON rp.organisation_id=j.organisation_id AND rp.campaign_id=j.campaign_id
  WHERE j.status IN('PENDING','DEFERRED') AND j.available_at<=p_at AND j.attempt_count<6
    AND c.workflow_state='ACTIVE' AND rp.enabled=true
    AND public.marketroute_paid_entitlement_active_v1(j.organisation_id,p_at)
    AND public.marketroute_campaign_research_entitled_v1(j.organisation_id,j.campaign_id,p_at)
    AND public.marketroute_campaign_research_cycle_ready_v1(j.organisation_id,j.campaign_id)
    AND public.marketroute_campaign_authority_ready_count_v1(j.organisation_id,j.campaign_id,p_at)<j.target_count
    AND COALESCE((public.marketroute_research_capacity_snapshot_v1(j.organisation_id,p_at)->>'available')::boolean,false)=true
    AND (SELECT count(DISTINCT s.company_id) FROM public.organisation_company_scopes s WHERE s.organisation_id=j.organisation_id AND s.campaign_id=j.campaign_id AND s.scope_kind='CAMPAIGN')<j.candidate_ceiling
  ORDER BY j.available_at,j.created_at,j.id FOR UPDATE OF j SKIP LOCKED LIMIT 1;
  IF v_job IS NULL THEN RETURN; END IF;

  UPDATE public.paid_campaign_refill_jobs SET status='RUNNING',attempt_count=attempt_count+1,worker_id=left(btrim(p_worker_id),200),lease_expires_at=p_at+interval '5 minutes',last_error_code=NULL,updated_at=p_at WHERE id=v_job;

  RETURN QUERY
  SELECT j.id,j.organisation_id,j.campaign_id,c.seller_business_id,s.name,s.canonical_domain,s.website_url,
    COALESCE(c.objective_text,'Win new B2B contracts'),
    COALESCE(a.target_market_text,ad.target_market_text,'Target market'),
    j.target_count,
    (SELECT count(DISTINCT sc.company_id)::int FROM public.organisation_company_scopes sc WHERE sc.organisation_id=j.organisation_id AND sc.campaign_id=j.campaign_id AND sc.scope_kind='CAMPAIGN'),
    greatest(0,j.target_count-public.marketroute_campaign_authority_ready_count_v1(j.organisation_id,j.campaign_id,p_at)),
    j.attempt_count,
    COALESCE((SELECT array_agg(DISTINCT lower(cmp.canonical_domain) ORDER BY lower(cmp.canonical_domain)) FROM public.organisation_company_scopes sc JOIN public.companies cmp ON cmp.id=sc.company_id WHERE sc.organisation_id=j.organisation_id AND sc.campaign_id=j.campaign_id AND sc.scope_kind='CAMPAIGN' AND cmp.canonical_domain IS NOT NULL),'{}'::text[])
  FROM public.paid_campaign_refill_jobs j
  JOIN public.campaigns c ON c.id=j.campaign_id AND c.organisation_id=j.organisation_id
  JOIN public.seller_businesses s ON s.id=c.seller_business_id AND s.organisation_id=c.organisation_id
  LEFT JOIN public.workspace_activation_jobs a ON a.id=c.activation_job_id AND a.organisation_id=c.organisation_id
  LEFT JOIN public.anonymous_discovery_runs ad ON ad.original_campaign_id=c.id AND ad.organisation_id=c.organisation_id
  WHERE j.id=v_job;
END;$fn$;

CREATE OR REPLACE FUNCTION public.marketroute_link_paid_campaign_refill_company_v1(p_job_id uuid,p_worker_id text,p_name text,p_domain text,p_website_url text,p_country_code text,p_at timestamptz DEFAULT now())
RETURNS TABLE(company_id uuid,scoped_count integer,target_count integer,inserted_scope boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_job public.paid_campaign_refill_jobs%ROWTYPE;v_domain text;v_company uuid;v_before integer;v_after integer;v_seller_domain text;
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT * INTO v_job FROM public.paid_campaign_refill_jobs WHERE id=p_job_id FOR UPDATE;
  IF NOT FOUND OR v_job.status<>'RUNNING' OR v_job.worker_id IS DISTINCT FROM left(btrim(COALESCE(p_worker_id,'')),200) OR v_job.lease_expires_at<=p_at THEN RAISE EXCEPTION 'MARKETROUTE_PAID_REFILL_LEASE_INVALID'; END IF;
  IF NOT public.marketroute_paid_entitlement_active_v1(v_job.organisation_id,p_at) OR NOT public.marketroute_campaign_research_entitled_v1(v_job.organisation_id,v_job.campaign_id,p_at) THEN RAISE EXCEPTION 'MARKETROUTE_PAID_REFILL_ENTITLEMENT_INACTIVE'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.campaigns c JOIN public.research_budget_policies rp ON rp.organisation_id=c.organisation_id AND rp.campaign_id=c.id WHERE c.id=v_job.campaign_id AND c.organisation_id=v_job.organisation_id AND c.workflow_state='ACTIVE' AND rp.enabled=true) THEN RAISE EXCEPTION 'MARKETROUTE_PAID_REFILL_CAMPAIGN_NOT_ACTIVE'; END IF;
  SELECT lower(s.canonical_domain) INTO v_seller_domain FROM public.campaigns c JOIN public.seller_businesses s ON s.id=c.seller_business_id AND s.organisation_id=c.organisation_id WHERE c.id=v_job.campaign_id AND c.organisation_id=v_job.organisation_id;
  v_domain:=lower(regexp_replace(btrim(COALESCE(p_domain,'')),'^www[.]','','i'));
  IF v_domain !~ '^[a-z0-9][a-z0-9.-]*[.][a-z]{2,63}$' OR v_domain~'[.][.]' OR v_domain=v_seller_domain THEN RAISE EXCEPTION 'MARKETROUTE_PAID_REFILL_DOMAIN_INVALID'; END IF;
  SELECT count(DISTINCT s.company_id)::int INTO v_before FROM public.organisation_company_scopes s WHERE s.organisation_id=v_job.organisation_id AND s.campaign_id=v_job.campaign_id AND s.scope_kind='CAMPAIGN';
  IF v_before>=v_job.candidate_ceiling THEN RETURN; END IF;
  SELECT id INTO v_company FROM public.companies WHERE canonical_domain=v_domain LIMIT 1;
  IF v_company IS NULL THEN
    INSERT INTO public.companies(canonical_name,canonical_domain,website_url,country_code,lifecycle_state)
    VALUES(left(btrim(COALESCE(p_name,'')),240),v_domain,COALESCE(NULLIF(btrim(COALESCE(p_website_url,'')),''),'https://'||v_domain),CASE WHEN upper(COALESCE(p_country_code,''))~'^[A-Z]{2}$' THEN upper(p_country_code) ELSE NULL END,'ACTIVE') RETURNING id INTO v_company;
  END IF;
  INSERT INTO public.organisation_company_scopes(organisation_id,company_id,campaign_id,scope_kind) VALUES(v_job.organisation_id,v_company,v_job.campaign_id,'CAMPAIGN') ON CONFLICT DO NOTHING;
  SELECT count(DISTINCT s.company_id)::int INTO v_after FROM public.organisation_company_scopes s WHERE s.organisation_id=v_job.organisation_id AND s.campaign_id=v_job.campaign_id AND s.scope_kind='CAMPAIGN';
  IF v_after>v_job.candidate_ceiling THEN RAISE EXCEPTION 'MARKETROUTE_PAID_REFILL_CANDIDATE_CEILING_EXCEEDED'; END IF;
  RETURN QUERY SELECT v_company,v_after,v_job.target_count,(v_after>v_before);
END;$fn$;

CREATE OR REPLACE FUNCTION public.marketroute_complete_paid_campaign_refill_v1(p_job_id uuid,p_worker_id text,p_result_json jsonb,p_at timestamptz DEFAULT now())
RETURNS TABLE(status text,scoped_count integer,target_count integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_job public.paid_campaign_refill_jobs%ROWTYPE;v_count integer;v_ready integer;v_status text;v_capacity jsonb;
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT * INTO v_job FROM public.paid_campaign_refill_jobs WHERE id=p_job_id FOR UPDATE;
  IF NOT FOUND OR v_job.status<>'RUNNING' OR v_job.worker_id IS DISTINCT FROM left(btrim(COALESCE(p_worker_id,'')),200) THEN RAISE EXCEPTION 'MARKETROUTE_PAID_REFILL_LEASE_INVALID'; END IF;
  SELECT count(DISTINCT s.company_id)::int INTO v_count FROM public.organisation_company_scopes s WHERE s.organisation_id=v_job.organisation_id AND s.campaign_id=v_job.campaign_id AND s.scope_kind='CAMPAIGN';
  v_ready:=public.marketroute_campaign_authority_ready_count_v1(v_job.organisation_id,v_job.campaign_id,p_at);
  v_capacity:=public.marketroute_research_capacity_snapshot_v1(v_job.organisation_id,p_at);
  v_status:=CASE
    WHEN NOT public.marketroute_paid_entitlement_active_v1(v_job.organisation_id,p_at) THEN 'EXHAUSTED'
    WHEN v_ready>=v_job.target_count THEN 'SUCCEEDED'
    WHEN v_job.attempt_count>=6 OR v_count>=v_job.candidate_ceiling THEN 'EXHAUSTED'
    ELSE 'DEFERRED' END;
  UPDATE public.paid_campaign_refill_jobs SET status=v_status,worker_id=NULL,lease_expires_at=NULL,
    available_at=CASE WHEN v_status='DEFERRED' THEN CASE WHEN COALESCE((v_capacity->>'available')::boolean,false)=false THEN COALESCE(NULLIF(v_capacity->>'periodEnd','')::timestamptz,p_at+interval '1 day') ELSE p_at+interval '2 minutes' END ELSE available_at END,
    last_error_code=CASE WHEN v_status='EXHAUSTED' AND NOT public.marketroute_paid_entitlement_active_v1(v_job.organisation_id,p_at) THEN 'MARKETROUTE_PAID_REFILL_ENTITLEMENT_INACTIVE' WHEN v_status='EXHAUSTED' AND v_job.attempt_count>=6 THEN 'MARKETROUTE_PAID_REFILL_ATTEMPT_CEILING_REACHED' WHEN v_status='EXHAUSTED' AND v_count>=v_job.candidate_ceiling THEN 'MARKETROUTE_PAID_REFILL_CANDIDATE_CEILING_REACHED' ELSE NULL END,
    result_json=COALESCE(p_result_json,'{}'::jsonb)||jsonb_build_object('scopedCount',v_count,'readyCount',v_ready,'readyTarget',v_job.target_count,'candidateCeiling',v_job.candidate_ceiling,'completedAt',p_at,'completionMetric','AUTHORITY_READY_OPPORTUNITIES','paidDemandDrivenRefill',true),updated_at=p_at
  WHERE id=p_job_id;
  RETURN QUERY SELECT v_status,v_count,v_job.target_count;
END;$fn$;

CREATE OR REPLACE FUNCTION public.marketroute_fail_paid_campaign_refill_v1(p_job_id uuid,p_worker_id text,p_error_code text,p_retryable boolean,p_at timestamptz DEFAULT now())
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_job public.paid_campaign_refill_jobs%ROWTYPE;
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT * INTO v_job FROM public.paid_campaign_refill_jobs WHERE id=p_job_id FOR UPDATE;
  IF NOT FOUND OR v_job.status<>'RUNNING' OR v_job.worker_id IS DISTINCT FROM left(btrim(COALESCE(p_worker_id,'')),200) THEN RAISE EXCEPTION 'MARKETROUTE_PAID_REFILL_LEASE_INVALID'; END IF;
  UPDATE public.paid_campaign_refill_jobs SET status=CASE WHEN COALESCE(p_retryable,false) AND attempt_count<6 THEN 'DEFERRED' ELSE 'FAILED' END,worker_id=NULL,lease_expires_at=NULL,available_at=CASE WHEN COALESCE(p_retryable,false) AND attempt_count<6 THEN p_at+interval '2 minutes' ELSE available_at END,last_error_code=left(COALESCE(NULLIF(btrim(p_error_code),''),'MARKETROUTE_PAID_REFILL_FAILED'),240),updated_at=p_at WHERE id=p_job_id;
END;$fn$;

REVOKE ALL ON FUNCTION public.marketroute_claim_paid_campaign_refill_v1(text,timestamptz) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_link_paid_campaign_refill_company_v1(uuid,text,text,text,text,text,timestamptz) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_complete_paid_campaign_refill_v1(uuid,text,jsonb,timestamptz) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_fail_paid_campaign_refill_v1(uuid,text,text,boolean,timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_claim_paid_campaign_refill_v1(text,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_link_paid_campaign_refill_company_v1(uuid,text,text,text,text,text,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_complete_paid_campaign_refill_v1(uuid,text,jsonb,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_fail_paid_campaign_refill_v1(uuid,text,text,boolean,timestamptz) TO service_role;

-- Reconcile Stripe into entitlement + research policy atomically. Downgrades never
-- archive customer data: campaigns beyond the paid allowance remain readable while
-- their research policies are suspended until capacity is restored or campaigns are archived.
CREATE OR REPLACE FUNCTION public.marketroute_reconcile_stripe_subscription_v1(
  p_organisation_id uuid,p_plan_code text,p_external_customer_id text,p_external_subscription_id text,p_provider_status text,
  p_current_period_start timestamptz,p_current_period_end timestamptz,p_cancel_at_period_end boolean DEFAULT false,
  p_external_event_id text DEFAULT NULL,p_event_type text DEFAULT NULL,p_external_checkout_session_id text DEFAULT NULL
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE
  v_status text;v_provider text:=lower(btrim(COALESCE(p_provider_status,'')));v_existing_org uuid;
  v_limit integer:=0;v_live integer:=0;v_rank integer:=0;v_suspended jsonb:='[]'::jsonb;rec record;v_run public.anonymous_discovery_runs%ROWTYPE;v_original_campaign uuid;v_discovery_restored boolean:=false;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF p_plan_code NOT IN('STARTER','GROWTH','SCALE') OR NOT EXISTS(SELECT 1 FROM public.marketroute_plan_catalog p WHERE p.plan_code=p_plan_code AND p.public_visible=true) THEN RAISE EXCEPTION 'MARKETROUTE_BILLING_PLAN_INVALID'; END IF;
  IF p_external_customer_id IS NULL OR p_external_customer_id !~ '^cus_' THEN RAISE EXCEPTION 'MARKETROUTE_BILLING_CUSTOMER_ID_INVALID'; END IF;
  IF p_external_subscription_id IS NULL OR p_external_subscription_id !~ '^sub_' THEN RAISE EXCEPTION 'MARKETROUTE_BILLING_SUBSCRIPTION_ID_INVALID'; END IF;
  IF p_current_period_end IS NOT NULL AND p_current_period_start IS NOT NULL AND p_current_period_end<=p_current_period_start THEN RAISE EXCEPTION 'MARKETROUTE_BILLING_PERIOD_INVALID'; END IF;
  SELECT organisation_id INTO v_existing_org FROM public.organisation_commercial_entitlements WHERE external_subscription_id=p_external_subscription_id AND organisation_id<>p_organisation_id LIMIT 1;
  IF v_existing_org IS NOT NULL THEN RAISE EXCEPTION 'MARKETROUTE_BILLING_SUBSCRIPTION_ALREADY_OWNED'; END IF;
  v_status:=CASE WHEN v_provider IN('active','trialing') THEN 'ACTIVE' WHEN v_provider='incomplete_expired' THEN 'EXPIRED' WHEN v_provider IN('canceled','unpaid') THEN 'CANCELLED' ELSE 'PAST_DUE' END;
  SELECT p.active_market_limit INTO v_limit FROM public.marketroute_plan_catalog p WHERE p.plan_code=p_plan_code;
  SELECT count(*)::int INTO v_live FROM public.campaigns c WHERE c.organisation_id=p_organisation_id AND c.workflow_state<>'ARCHIVED';
  SELECT r.original_campaign_id INTO v_original_campaign FROM public.anonymous_discovery_runs r WHERE r.organisation_id=p_organisation_id AND r.original_campaign_id IS NOT NULL ORDER BY r.created_at LIMIT 1;

  INSERT INTO public.organisation_commercial_entitlements(organisation_id,plan_code,status,source,external_customer_id,external_subscription_id,current_period_start,current_period_end,activated_at,updated_at,metadata_json)
  VALUES(p_organisation_id,p_plan_code,v_status,'BILLING',p_external_customer_id,p_external_subscription_id,p_current_period_start,p_current_period_end,now(),now(),jsonb_build_object('provider','STRIPE','providerStatus',v_provider,'cancelAtPeriodEnd',COALESCE(p_cancel_at_period_end,false),'lastEventId',p_external_event_id,'lastEventType',p_event_type,'lastReconciledAt',now()))
  ON CONFLICT(organisation_id) DO UPDATE SET plan_code=EXCLUDED.plan_code,status=EXCLUDED.status,source='BILLING',external_customer_id=EXCLUDED.external_customer_id,external_subscription_id=EXCLUDED.external_subscription_id,current_period_start=EXCLUDED.current_period_start,current_period_end=EXCLUDED.current_period_end,activated_at=CASE WHEN organisation_commercial_entitlements.status<>'ACTIVE' AND EXCLUDED.status='ACTIVE' THEN now() ELSE organisation_commercial_entitlements.activated_at END,updated_at=now(),metadata_json=organisation_commercial_entitlements.metadata_json||EXCLUDED.metadata_json;

  IF v_status='ACTIVE' THEN
    FOR rec IN SELECT c.id,c.workflow_state FROM public.campaigns c WHERE c.organisation_id=p_organisation_id AND c.workflow_state<>'ARCHIVED' ORDER BY c.created_at,c.id LOOP
      v_rank:=v_rank+1;
      IF rec.id=v_original_campaign THEN
        INSERT INTO public.research_budget_policies(organisation_id,campaign_id,daily_budget_usd,max_job_cost_usd,max_concurrent_jobs,max_work_units_per_plan,refresh_horizon_hours,enabled,policy_version,updated_at)
        VALUES(p_organisation_id,rec.id,100.00000000,0.50000000,2,4,2,(rec.workflow_state='ACTIVE' AND v_rank<=v_limit),'MRV2-PAID-ENTITLEMENT-TRANSITION-1.0.0',now())
        ON CONFLICT(organisation_id,campaign_id) DO UPDATE SET daily_budget_usd=EXCLUDED.daily_budget_usd,max_job_cost_usd=EXCLUDED.max_job_cost_usd,max_concurrent_jobs=EXCLUDED.max_concurrent_jobs,max_work_units_per_plan=EXCLUDED.max_work_units_per_plan,refresh_horizon_hours=EXCLUDED.refresh_horizon_hours,enabled=EXCLUDED.enabled,policy_version=EXCLUDED.policy_version,updated_at=now();
      ELSE
        INSERT INTO public.research_budget_policies(organisation_id,campaign_id,daily_budget_usd,max_job_cost_usd,max_concurrent_jobs,max_work_units_per_plan,refresh_horizon_hours,enabled,policy_version,updated_at)
        VALUES(p_organisation_id,rec.id,100.00000000,0.50000000,2,4,2,(rec.workflow_state='ACTIVE' AND v_rank<=v_limit),'MRV2-RESEARCH-BUDGET-1.0.0',now())
        ON CONFLICT(organisation_id,campaign_id) DO UPDATE SET enabled=EXCLUDED.enabled,updated_at=now();
      END IF;
      IF v_rank>v_limit THEN v_suspended:=v_suspended||jsonb_build_array(rec.id); END IF;
    END LOOP;
    UPDATE public.organisation_commercial_entitlements SET metadata_json=metadata_json||jsonb_build_object('activeMarketCount',v_live,'activeMarketLimit',v_limit,'capacityOverage',v_live>v_limit,'researchSuspendedCampaignIds',v_suspended,'researchPolicyProfile','PAID'),updated_at=now() WHERE organisation_id=p_organisation_id;
  ELSE
    UPDATE public.research_budget_policies SET enabled=false,updated_at=now() WHERE organisation_id=p_organisation_id;
    SELECT * INTO v_run FROM public.anonymous_discovery_runs r WHERE r.organisation_id=p_organisation_id AND r.original_campaign_id IS NOT NULL AND r.status IN('ACTIVE','CLAIMED') AND r.research_expires_at>now() ORDER BY r.created_at LIMIT 1;
    IF FOUND AND NOT public.marketroute_anonymous_discovery_budget_terminal_v1(v_run.id,now()) THEN
      INSERT INTO public.research_budget_policies(organisation_id,campaign_id,daily_budget_usd,max_job_cost_usd,max_concurrent_jobs,max_work_units_per_plan,refresh_horizon_hours,enabled,policy_version,updated_at)
      SELECT p_organisation_id,v_run.original_campaign_id,LEAST(1.00000000,GREATEST(0.50000000,v_run.lifetime_budget_usd)),0.35000000,1,3,24,(c.workflow_state='ACTIVE'),'MRV2-DISCOVERY-RESTORED-1.0.0',now() FROM public.campaigns c WHERE c.id=v_run.original_campaign_id AND c.organisation_id=p_organisation_id
      ON CONFLICT(organisation_id,campaign_id) DO UPDATE SET daily_budget_usd=EXCLUDED.daily_budget_usd,max_job_cost_usd=EXCLUDED.max_job_cost_usd,max_concurrent_jobs=EXCLUDED.max_concurrent_jobs,max_work_units_per_plan=EXCLUDED.max_work_units_per_plan,refresh_horizon_hours=EXCLUDED.refresh_horizon_hours,enabled=EXCLUDED.enabled,policy_version=EXCLUDED.policy_version,updated_at=now();
      v_discovery_restored:=true;
    END IF;
    UPDATE public.organisation_commercial_entitlements SET metadata_json=metadata_json||jsonb_build_object('capacityOverage',false,'researchSuspendedCampaignIds','[]'::jsonb,'researchPolicyProfile',CASE WHEN v_discovery_restored THEN 'DISCOVERY_RESTORED' ELSE 'INACTIVE' END),updated_at=now() WHERE organisation_id=p_organisation_id;
  END IF;

  IF p_external_checkout_session_id IS NOT NULL THEN
    UPDATE public.marketroute_billing_checkout_attempts SET status=CASE WHEN v_status='ACTIVE' THEN 'COMPLETED' ELSE status END,updated_at=now(),metadata_json=metadata_json||jsonb_build_object('subscriptionId',p_external_subscription_id,'providerStatus',v_provider) WHERE external_checkout_session_id=p_external_checkout_session_id;
  END IF;
  RETURN true;
END;$fn$;

REVOKE ALL ON FUNCTION public.marketroute_reconcile_stripe_subscription_v1(uuid,text,text,text,text,timestamptz,timestamptz,boolean,text,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_reconcile_stripe_subscription_v1(uuid,text,text,text,text,timestamptz,timestamptz,boolean,text,text,text) TO service_role;

CREATE OR REPLACE FUNCTION public.marketroute_billing_reconciliation_due_v1(p_at timestamptz DEFAULT now(),p_limit integer DEFAULT 10)
RETURNS TABLE(organisation_id uuid,external_customer_id text,external_subscription_id text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
BEGIN
  PERFORM public.marketroute_require_service_role();
  RETURN QUERY
  SELECT e.organisation_id,e.external_customer_id,e.external_subscription_id
  FROM public.organisation_commercial_entitlements e
  WHERE e.source='BILLING' AND e.external_customer_id IS NOT NULL AND e.external_subscription_id IS NOT NULL
    AND e.status NOT IN('CANCELLED','EXPIRED')
    AND COALESCE(NULLIF(e.metadata_json->>'lastRecoveryAttemptAt','')::timestamptz,'epoch'::timestamptz)<=p_at-interval '15 minutes'
    AND (e.status='PAST_DUE' OR e.current_period_end IS NULL OR e.current_period_end<=p_at+interval '24 hours' OR COALESCE(NULLIF(e.metadata_json->>'lastReconciledAt','')::timestamptz,e.updated_at)<=p_at-interval '6 hours')
  ORDER BY CASE WHEN e.current_period_end IS NULL THEN p_at ELSE e.current_period_end END,e.updated_at,e.organisation_id
  LIMIT LEAST(50,GREATEST(1,COALESCE(p_limit,10)));
END;$fn$;
REVOKE ALL ON FUNCTION public.marketroute_billing_reconciliation_due_v1(timestamptz,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_billing_reconciliation_due_v1(timestamptz,integer) TO service_role;

CREATE OR REPLACE FUNCTION public.marketroute_mark_billing_recovery_attempt_v1(p_organisation_id uuid,p_at timestamptz DEFAULT now())
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
BEGIN
  PERFORM public.marketroute_require_service_role();
  UPDATE public.organisation_commercial_entitlements SET metadata_json=metadata_json||jsonb_build_object('lastRecoveryAttemptAt',p_at) WHERE organisation_id=p_organisation_id AND source='BILLING';
  RETURN FOUND;
END;$fn$;
REVOKE ALL ON FUNCTION public.marketroute_mark_billing_recovery_attempt_v1(uuid,timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_mark_billing_recovery_attempt_v1(uuid,timestamptz) TO service_role;

CREATE OR REPLACE FUNCTION public.marketroute_manage_campaign_v1(
  p_organisation_id uuid,
  p_campaign_id uuid,
  p_action text,
  p_confirmation_name text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_user uuid := auth.uid();
  v_campaign public.campaigns%ROWTYPE;
  v_action text := upper(btrim(COALESCE(p_action, '')));
  v_resulting_state text;
  v_policy_was_enabled boolean := true;
  v_deduplicated boolean := false;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'MARKETROUTE_AUTH_REQUIRED';
  END IF;
  IF NOT public.marketroute_is_org_admin(p_organisation_id) THEN
    RAISE EXCEPTION 'MARKETROUTE_CAMPAIGN_ADMIN_REQUIRED';
  END IF;
  IF v_action NOT IN ('PAUSE','RESUME','ARCHIVE') THEN
    RAISE EXCEPTION 'MARKETROUTE_CAMPAIGN_ACTION_INVALID';
  END IF;

  SELECT c.*
  INTO v_campaign
  FROM public.campaigns AS c
  WHERE c.id = p_campaign_id
    AND c.organisation_id = p_organisation_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'MARKETROUTE_CAMPAIGN_NOT_FOUND';
  END IF;

  IF v_action = 'ARCHIVE'
     AND p_confirmation_name IS DISTINCT FROM v_campaign.name THEN
    RAISE EXCEPTION 'MARKETROUTE_CAMPAIGN_NAME_CONFIRMATION_MISMATCH';
  END IF;

  IF v_action = 'RESUME' AND NOT public.marketroute_campaign_research_entitled_v1(p_organisation_id,p_campaign_id,now()) THEN
    RAISE EXCEPTION 'MARKETROUTE_CAMPAIGN_RESUME_RESEARCH_ENTITLEMENT_REQUIRED';
  END IF;

  IF v_action = 'PAUSE' THEN
    IF v_campaign.workflow_state = 'PAUSED' THEN
      v_deduplicated := true;
      v_resulting_state := 'PAUSED';
    ELSIF v_campaign.workflow_state <> 'ACTIVE' THEN
      RAISE EXCEPTION 'MARKETROUTE_CAMPAIGN_PAUSE_STATE_INVALID';
    ELSE
      v_resulting_state := 'PAUSED';
      SELECT COALESCE(p.enabled, true)
      INTO v_policy_was_enabled
      FROM public.research_budget_policies AS p
      WHERE p.organisation_id = p_organisation_id
        AND p.campaign_id = p_campaign_id;
      v_policy_was_enabled := COALESCE(v_policy_was_enabled, true);
    END IF;
  ELSIF v_action = 'RESUME' THEN
    IF v_campaign.workflow_state = 'ACTIVE' THEN
      v_deduplicated := true;
      v_resulting_state := 'ACTIVE';
    ELSIF v_campaign.workflow_state <> 'PAUSED' THEN
      RAISE EXCEPTION 'MARKETROUTE_CAMPAIGN_RESUME_STATE_INVALID';
    ELSE
      v_resulting_state := 'ACTIVE';
      SELECT COALESCE((e.metadata_json->>'researchPolicyWasEnabled')::boolean, true)
      INTO v_policy_was_enabled
      FROM public.campaign_workflow_events AS e
      WHERE e.organisation_id = p_organisation_id
        AND e.campaign_id = p_campaign_id
        AND e.action = 'PAUSE'
      ORDER BY e.occurred_at DESC, e.id DESC
      LIMIT 1;
      v_policy_was_enabled := COALESCE(v_policy_was_enabled, true);
    END IF;
  ELSE
    IF v_campaign.workflow_state = 'ARCHIVED' THEN
      v_deduplicated := true;
      v_resulting_state := 'ARCHIVED';
    ELSE
      v_resulting_state := 'ARCHIVED';
    END IF;
  END IF;

  IF v_deduplicated THEN
    RETURN jsonb_build_object(
      'campaignId', v_campaign.id,
      'action', v_action,
      'workflowState', v_resulting_state,
      'deduplicated', true
    );
  END IF;

  IF v_action IN ('PAUSE','ARCHIVE') AND EXISTS (
    SELECT 1
    FROM public.engagement_delivery_jobs AS j
    JOIN public.engagement_queue_items AS q ON q.id = j.queue_item_id
    WHERE q.organisation_id = p_organisation_id
      AND q.campaign_id = p_campaign_id
      AND j.status = 'RUNNING'
  ) THEN
    RAISE EXCEPTION 'MARKETROUTE_CAMPAIGN_CHANGE_BLOCKED_DURING_DELIVERY';
  END IF;

  UPDATE public.campaigns
  SET workflow_state = v_resulting_state,
      updated_at = now()
  WHERE id = p_campaign_id
    AND organisation_id = p_organisation_id;

  IF v_action IN ('PAUSE','ARCHIVE') THEN
    UPDATE public.research_budget_policies
    SET enabled = false,
        updated_at = now()
    WHERE organisation_id = p_organisation_id
      AND campaign_id = p_campaign_id;
  ELSIF v_action = 'RESUME' THEN
    UPDATE public.research_budget_policies
    SET enabled = v_policy_was_enabled,
        updated_at = now()
    WHERE organisation_id = p_organisation_id
      AND campaign_id = p_campaign_id;
  END IF;

  INSERT INTO public.campaign_workflow_events(
    organisation_id,
    campaign_id,
    actor_user_id,
    action,
    prior_workflow_state,
    resulting_workflow_state,
    metadata_json
  )
  VALUES(
    p_organisation_id,
    p_campaign_id,
    v_user,
    v_action,
    v_campaign.workflow_state,
    v_resulting_state,
    CASE
      WHEN v_action = 'PAUSE'
        THEN jsonb_build_object('researchPolicyWasEnabled', v_policy_was_enabled)
      WHEN v_action = 'ARCHIVE'
        THEN jsonb_build_object('typedNameConfirmed', true, 'lineageRetained', true)
      ELSE '{}'::jsonb
    END
  );

  RETURN jsonb_build_object(
    'campaignId', v_campaign.id,
    'action', v_action,
    'workflowState', v_resulting_state,
    'deduplicated', false
  );
END;
$fn$;


REVOKE ALL ON FUNCTION public.marketroute_manage_campaign_v1(uuid,uuid,text,text) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_manage_campaign_v1(uuid,uuid,text,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.marketroute_claim_research_work_v1(
  p_scheduler_run_id uuid,
  p_at timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_work public.research_work_units%ROWTYPE;
  v_job public.background_jobs%ROWTYPE;
  v_policy jsonb;
  v_budget jsonb;
  v_attempt integer;
  v_remaining numeric;
  v_anon_budget numeric;
  v_anon_expires timestamptz;
  v_anon_spent numeric := 0;
  v_anon_reserved numeric := 0;
  v_anon_remaining numeric;
  v_paid boolean := false;
  v_capacity jsonb;
  -- When every job in a campaign/organisation is temporarily blocked by the
  -- same scope-level gate, skip the rest of that scope for this claim call.
  -- Unit-specific budget checks still continue row-by-row so a zero-cost
  -- deterministic revalidation can run behind a paid AI work unit.
  v_skip_campaigns uuid[] := ARRAY[]::uuid[];
  v_skip_organisations uuid[] := ARRAY[]::uuid[];
  v_skip_work_units uuid[] := ARRAY[]::uuid[];
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.scheduler_runs AS r
    JOIN public.scheduler_leases AS l
      ON l.owner_run_id = r.id
     AND l.lease_key = 'GENESIS_RESEARCH_V1'
    WHERE r.id = p_scheduler_run_id
      AND r.status = 'RUNNING'
      AND r.runner_key = 'GENESIS_RESEARCH_V1'
      AND l.expires_at > p_at
  ) THEN
    RAISE EXCEPTION 'MARKETROUTE_RESEARCH_SCHEDULER_RUN_REQUIRED';
  END IF;

  -- Archived campaigns retain immutable research lineage, but their queued
  -- orchestration jobs are terminal. Clean them out so historical work cannot
  -- remain visible as live queue backlog forever. PAUSED work is deliberately
  -- retained for a later resume.
  UPDATE public.background_jobs AS j
  SET status = 'CANCELLED',
      reserved_by_run_id = NULL,
      reserved_at = NULL,
      last_error_code = COALESCE(j.last_error_code, 'MARKETROUTE_CAMPAIGN_ARCHIVED'),
      updated_at = p_at
  FROM public.research_work_units AS w
  JOIN public.campaigns AS c
    ON c.id = w.campaign_id
   AND c.organisation_id = w.organisation_id
  WHERE j.id = w.background_job_id
    AND j.job_type = 'GENESIS_RESEARCH_V1'
    AND j.status IN ('PENDING','DEFERRED')
    AND c.workflow_state = 'ARCHIVED';

  LOOP
    -- Select only work that belongs to an ACTIVE campaign. Explicitly disabled
    -- research policies are excluded before queue ordering so they cannot sit
    -- at the head of the global queue and be repeatedly deferred.
    SELECT w.*
    INTO v_work
    FROM public.research_work_units AS w
    JOIN public.background_jobs AS j
      ON j.id = w.background_job_id
    JOIN public.campaigns AS c
      ON c.id = w.campaign_id
     AND c.organisation_id = w.organisation_id
    WHERE j.job_type = 'GENESIS_RESEARCH_V1'
      AND j.status IN ('PENDING','DEFERRED')
      AND j.available_at <= p_at
      AND c.workflow_state = 'ACTIVE'
      AND public.marketroute_campaign_research_entitled_v1(w.organisation_id,w.campaign_id,p_at)
      AND COALESCE((
        SELECT p.enabled
        FROM public.research_budget_policies AS p
        WHERE p.organisation_id = w.organisation_id
          AND p.campaign_id = w.campaign_id
      ), true)
      AND NOT (w.campaign_id = ANY(v_skip_campaigns))
      AND NOT (w.organisation_id = ANY(v_skip_organisations))
      AND NOT (w.id = ANY(v_skip_work_units))
      AND NOT EXISTS (
        SELECT 1
        FROM public.anonymous_discovery_runs AS a
        WHERE a.organisation_id = w.organisation_id
          AND a.original_campaign_id = w.campaign_id
          AND NOT public.marketroute_paid_entitlement_active_v1(w.organisation_id, p_at)
          AND (
            a.status NOT IN ('ACTIVE','CLAIMED')
            OR a.research_expires_at <= p_at
          )
      )
    ORDER BY j.priority, j.created_at, j.id
    FOR UPDATE OF j SKIP LOCKED
    LIMIT 1;

    -- NULL now means there is genuinely no eligible candidate left after all
    -- blocked scopes/units examined by this claim call have been skipped.
    IF NOT FOUND THEN
      RETURN NULL;
    END IF;

    SELECT *
    INTO v_job
    FROM public.background_jobs
    WHERE id = v_work.background_job_id
    FOR UPDATE;

    v_policy := public.marketroute_research_policy_v1(
      v_work.organisation_id,
      v_work.campaign_id
    );
    v_budget := public.marketroute_research_budget_snapshot_v1(
      v_work.organisation_id,
      v_work.campaign_id,
      p_at
    );

    -- Scope-level block: defer one representative job, skip the rest of the
    -- campaign in this call, and continue scanning other campaigns.
    IF COALESCE((v_policy->>'enabled')::boolean, true) = false
       OR (v_budget->>'activeJobs')::integer >=
          (v_policy->>'maxConcurrentJobs')::integer THEN
      UPDATE public.background_jobs
      SET status = 'DEFERRED',
          available_at = p_at + interval '5 minutes',
          last_error_code = 'MARKETROUTE_RESEARCH_CONCURRENCY_BLOCKED',
          updated_at = p_at
      WHERE id = v_job.id;

      IF NOT (v_work.campaign_id = ANY(v_skip_campaigns)) THEN
        v_skip_campaigns := array_append(v_skip_campaigns, v_work.campaign_id);
      END IF;
      CONTINUE;
    END IF;

    v_remaining :=
      (v_policy->>'dailyBudgetUsd')::numeric
      - (v_budget->>'spentTodayUsd')::numeric
      - (v_budget->>'reservedTodayUsd')::numeric;

    v_paid := public.marketroute_paid_entitlement_active_v1(
      v_work.organisation_id,
      p_at
    );

    -- Paid research capacity is organisation-scoped. If exhausted, defer one
    -- representative unit until the next period, skip the organisation for
    -- this call, and continue to a different runnable customer if one exists.
    IF v_paid AND v_work.cost_ceiling_usd > 0 THEN
      v_capacity := public.marketroute_research_capacity_snapshot_v1(
        v_work.organisation_id,
        p_at
      );
      IF COALESCE((v_capacity->>'available')::boolean, false) = false THEN
        UPDATE public.background_jobs
        SET status = 'DEFERRED',
            available_at = COALESCE(
              NULLIF(v_capacity->>'periodEnd','')::timestamptz,
              p_at + interval '1 day'
            ),
            last_error_code = 'MARKETROUTE_PLAN_RESEARCH_CAPACITY_EXHAUSTED',
            updated_at = p_at
        WHERE id = v_job.id;

        IF NOT (v_work.organisation_id = ANY(v_skip_organisations)) THEN
          v_skip_organisations := array_append(
            v_skip_organisations,
            v_work.organisation_id
          );
        END IF;
        CONTINUE;
      END IF;
    END IF;

    v_anon_budget := NULL;
    v_anon_expires := NULL;
    v_anon_spent := 0;
    v_anon_reserved := 0;
    v_anon_remaining := NULL;

    IF NOT v_paid THEN
      SELECT lifetime_budget_usd, research_expires_at
      INTO v_anon_budget, v_anon_expires
      FROM public.anonymous_discovery_runs
      WHERE organisation_id = v_work.organisation_id
        AND original_campaign_id = v_work.campaign_id
        AND status IN ('ACTIVE','CLAIMED')
      ORDER BY created_at
      LIMIT 1;
    END IF;

    IF v_anon_budget IS NOT NULL THEN
      IF v_anon_expires <= p_at THEN
        UPDATE public.background_jobs
        SET status = 'CANCELLED',
            last_error_code = 'MARKETROUTE_ANONYMOUS_RESEARCH_WINDOW_CLOSED',
            updated_at = p_at
        WHERE id = v_job.id;
        CONTINUE;
      END IF;

      SELECT COALESCE(sum(amount_usd), 0)
      INTO v_anon_spent
      FROM public.research_budget_events
      WHERE organisation_id = v_work.organisation_id
        AND campaign_id = v_work.campaign_id
        AND event_type = 'COMMIT';

      SELECT COALESCE(sum(r.amount_usd), 0)
      INTO v_anon_reserved
      FROM public.research_budget_events AS r
      WHERE r.organisation_id = v_work.organisation_id
        AND r.campaign_id = v_work.campaign_id
        AND r.event_type = 'RESERVE'
        AND NOT EXISTS (
          SELECT 1
          FROM public.research_budget_events AS x
          WHERE x.work_unit_id = r.work_unit_id
            AND x.attempt_number = r.attempt_number
            AND x.event_type IN ('COMMIT','RELEASE')
        );

      v_anon_remaining := greatest(
        0,
        v_anon_budget - v_anon_spent - v_anon_reserved
      );
      v_remaining := least(v_remaining, v_anon_remaining);
    END IF;

    -- This remains deliberately unit-specific. Do not skip the whole campaign:
    -- a zero-cost REVALIDATE_R4/R5/R6 unit may be runnable immediately behind
    -- an AI work unit that no longer fits today's remaining budget.
    IF v_work.cost_ceiling_usd > greatest(0, v_remaining)
       OR v_work.cost_ceiling_usd >
          (v_policy->>'maxJobCostUsd')::numeric THEN
      UPDATE public.background_jobs
      SET status = CASE
            WHEN v_anon_budget IS NOT NULL
             AND greatest(0, v_remaining) <= 0
              THEN 'CANCELLED'
            ELSE 'DEFERRED'
          END,
          available_at = CASE
            WHEN v_anon_budget IS NOT NULL
              THEN available_at
            ELSE
              (date_trunc('day', p_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC')
              + interval '1 day'
          END,
          last_error_code = CASE
            WHEN v_anon_budget IS NOT NULL
             AND greatest(0, v_remaining) <= 0
              THEN 'MARKETROUTE_ANONYMOUS_RESEARCH_BUDGET_EXHAUSTED'
            WHEN v_work.cost_ceiling_usd > (v_policy->>'maxJobCostUsd')::numeric
              THEN 'MARKETROUTE_RESEARCH_JOB_COST_LIMIT'
            ELSE 'MARKETROUTE_RESEARCH_DAILY_BUDGET_DEFERRED'
          END,
          updated_at = p_at
      WHERE id = v_job.id;
      IF NOT (v_work.id = ANY(v_skip_work_units)) THEN
        v_skip_work_units := array_append(v_skip_work_units, v_work.id);
      END IF;
      CONTINUE;
    END IF;

    v_attempt := v_job.attempt_count + 1;

    IF EXISTS (
      SELECT 1
      FROM public.research_budget_events
      WHERE work_unit_id = v_work.id
        AND attempt_number = v_attempt
        AND event_type = 'RESERVE'
    ) THEN
      RAISE EXCEPTION 'MARKETROUTE_RESEARCH_BUDGET_ALREADY_RESERVED';
    END IF;

    INSERT INTO public.research_budget_events(
      organisation_id,
      campaign_id,
      work_unit_id,
      scheduler_run_id,
      attempt_number,
      event_type,
      amount_usd,
      occurred_at
    ) VALUES (
      v_work.organisation_id,
      v_work.campaign_id,
      v_work.id,
      p_scheduler_run_id,
      v_attempt,
      'RESERVE',
      v_work.cost_ceiling_usd,
      p_at
    );

    UPDATE public.background_jobs
    SET status = 'RUNNING',
        reserved_by_run_id = p_scheduler_run_id,
        reserved_at = p_at,
        attempt_count = v_attempt,
        updated_at = p_at
    WHERE id = v_job.id;

    INSERT INTO public.background_job_attempts(
      job_id,
      scheduler_run_id,
      attempt_number,
      status,
      started_at
    ) VALUES (
      v_job.id,
      p_scheduler_run_id,
      v_attempt,
      'RUNNING',
      p_at
    );

    RETURN jsonb_build_object(
      'workUnitId', v_work.id,
      'jobId', v_job.id,
      'planId', v_work.plan_id,
      'organisationId', v_work.organisation_id,
      'campaignId', v_work.campaign_id,
      'companyId', v_work.company_id,
      'gapKey', v_work.gap_key,
      'layer', v_work.layer,
      'tier', v_work.tier,
      'action', v_work.action,
      'subjectType', v_work.subject_type,
      'subjectId', v_work.subject_id,
      'claimKey', v_work.claim_key,
      'reasonCode', v_work.reason_code,
      'queryHints', v_work.query_hints_json,
      'payload', v_work.payload_json || jsonb_build_object(
        'dedupeKey', v_work.dedupe_key,
        'researchOrigin', CASE
          WHEN v_paid THEN 'CUSTOMER_CAMPAIGN'
          WHEN v_anon_budget IS NULL THEN
            COALESCE(v_work.payload_json->>'researchOrigin','CUSTOMER_CAMPAIGN')
          ELSE 'ANONYMOUS_DISCOVERY'
        END
      ),
      'costCeilingUsd', v_work.cost_ceiling_usd,
      'attemptNumber', v_attempt
    );
  END LOOP;
END;
$fn$;



REVOKE ALL ON FUNCTION public.marketroute_claim_research_work_v1(uuid,timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_claim_research_work_v1(uuid,timestamptz) TO service_role;

INSERT INTO public.marketroute_schema_releases(release_key,build_number,constitution_version,metadata_json)
VALUES('MARKETROUTE_V2_RC_PAID_ENTITLEMENT_TRANSITION_COMMERCIAL_LIFECYCLE_HARDENING',62,'MRV2-CONSTITUTION-1.0.0',jsonb_build_object(
  'migration','0062_paid_entitlement_transition_commercial_lifecycle_hardening.sql','new_authority_writer',false,'authority_semantics_unchanged',true,
  'discovery_to_paid_policy_promotion',true,'paid_campaign_ready_refill',true,'paid_ready_target',10,'paid_refill_candidate_ceiling',60,'paid_refill_attempt_ceiling',6,
  'downgrade_research_capacity_enforced',true,'downgrade_archives_campaigns',false,'anonymous_budget_bound_to_original_campaign',true,'resume_entitlement_rechecked',true,
  'paid_refill_waits_for_campaign_specific_research',true,'paid_refill_fresh_episode_attempt_reset',true,'discovery_restore_state_explicit',true,
  'billing_reconciliation_recovery',true,'campaign_scoped_free_reads_required',true,'autonomous_delivery_enabled',false
)) ON CONFLICT(release_key) DO NOTHING;

NOTIFY pgrst,'reload schema';
COMMIT;
