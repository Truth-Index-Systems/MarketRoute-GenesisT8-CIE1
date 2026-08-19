BEGIN;

-- MarketRoute RC 0.67: paid campaign refill claim ambiguity hotfix.
-- The paid refill claimant introduced in 0062 returns TABLE columns named
-- organisation_id, campaign_id and attempt_count. PL/pgSQL exposes those output
-- names as variables, so unqualified conflict-target and attempt-counter references
-- can become ambiguous at runtime.
-- This migration removes that ambiguity without changing refill economics,
-- Truth/R4/R5/R6 authority semantics, entitlement or candidate ceilings.

CREATE OR REPLACE FUNCTION public.marketroute_claim_paid_campaign_refill_v1(
  p_worker_id text,
  p_at timestamptz DEFAULT now()
)
RETURNS TABLE(
  job_id uuid,
  organisation_id uuid,
  campaign_id uuid,
  seller_business_id uuid,
  seller_name text,
  canonical_domain text,
  website_url text,
  objective_text text,
  target_market_text text,
  target_count integer,
  scoped_count integer,
  remaining_count integer,
  attempt_count integer,
  existing_domains text[]
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
DECLARE
  v_job uuid;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF length(btrim(COALESCE(p_worker_id,'')))<3 THEN
    RAISE EXCEPTION 'MARKETROUTE_PAID_REFILL_WORKER_REQUIRED';
  END IF;

  INSERT INTO public.paid_campaign_refill_jobs(
    organisation_id,campaign_id,target_count,candidate_ceiling,status,available_at
  )
  SELECT c.organisation_id,c.id,10,60,'PENDING',p_at
  FROM public.campaigns c
  JOIN public.research_budget_policies rp
    ON rp.organisation_id=c.organisation_id
   AND rp.campaign_id=c.id
   AND rp.enabled=true
  WHERE c.workflow_state='ACTIVE'
    AND public.marketroute_paid_entitlement_active_v1(c.organisation_id,p_at)
    AND public.marketroute_campaign_research_entitled_v1(c.organisation_id,c.id,p_at)
    AND public.marketroute_campaign_authority_ready_count_v1(c.organisation_id,c.id,p_at)<10
    AND (
      SELECT count(DISTINCT s.company_id)
      FROM public.organisation_company_scopes s
      WHERE s.organisation_id=c.organisation_id
        AND s.campaign_id=c.id
        AND s.scope_kind='CAMPAIGN'
    )<60
  ON CONFLICT ON CONSTRAINT paid_campaign_refill_jobs_organisation_id_campaign_id_key
  DO UPDATE SET
    status=CASE
      WHEN paid_campaign_refill_jobs.status='SUCCEEDED' THEN 'DEFERRED'
      WHEN paid_campaign_refill_jobs.status='EXHAUSTED'
        AND paid_campaign_refill_jobs.last_error_code='MARKETROUTE_PAID_REFILL_ENTITLEMENT_INACTIVE'
      THEN 'DEFERRED'
      ELSE paid_campaign_refill_jobs.status
    END,
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
  SET status='EXHAUSTED',
      worker_id=NULL,
      lease_expires_at=NULL,
      last_error_code='MARKETROUTE_PAID_REFILL_ENTITLEMENT_INACTIVE',
      updated_at=p_at
  WHERE j.status IN('PENDING','DEFERRED','RUNNING')
    AND NOT public.marketroute_paid_entitlement_active_v1(j.organisation_id,p_at);

  UPDATE public.paid_campaign_refill_jobs j
  SET status='DEFERRED',
      worker_id=NULL,
      lease_expires_at=NULL,
      available_at=p_at,
      last_error_code='MARKETROUTE_PAID_REFILL_LEASE_RECOVERED',
      updated_at=p_at
  WHERE j.status='RUNNING'
    AND j.lease_expires_at<p_at;

  SELECT j.id
  INTO v_job
  FROM public.paid_campaign_refill_jobs j
  JOIN public.campaigns c
    ON c.id=j.campaign_id
   AND c.organisation_id=j.organisation_id
  JOIN public.research_budget_policies rp
    ON rp.organisation_id=j.organisation_id
   AND rp.campaign_id=j.campaign_id
  WHERE j.status IN('PENDING','DEFERRED')
    AND j.available_at<=p_at
    AND j.attempt_count<6
    AND c.workflow_state='ACTIVE'
    AND rp.enabled=true
    AND public.marketroute_paid_entitlement_active_v1(j.organisation_id,p_at)
    AND public.marketroute_campaign_research_entitled_v1(j.organisation_id,j.campaign_id,p_at)
    AND public.marketroute_campaign_research_cycle_ready_v1(j.organisation_id,j.campaign_id)
    AND public.marketroute_campaign_authority_ready_count_v1(j.organisation_id,j.campaign_id,p_at)<j.target_count
    AND COALESCE((public.marketroute_research_capacity_snapshot_v1(j.organisation_id,p_at)->>'available')::boolean,false)=true
    AND (
      SELECT count(DISTINCT s.company_id)
      FROM public.organisation_company_scopes s
      WHERE s.organisation_id=j.organisation_id
        AND s.campaign_id=j.campaign_id
        AND s.scope_kind='CAMPAIGN'
    )<j.candidate_ceiling
  ORDER BY j.available_at,j.created_at,j.id
  FOR UPDATE OF j SKIP LOCKED
  LIMIT 1;

  IF v_job IS NULL THEN RETURN; END IF;

  UPDATE public.paid_campaign_refill_jobs AS prj
  SET status='RUNNING',
      attempt_count=prj.attempt_count+1,
      worker_id=left(btrim(p_worker_id),200),
      lease_expires_at=p_at+interval '5 minutes',
      last_error_code=NULL,
      updated_at=p_at
  WHERE prj.id=v_job;

  RETURN QUERY
  SELECT
    j.id,
    j.organisation_id,
    j.campaign_id,
    c.seller_business_id,
    s.name,
    s.canonical_domain,
    s.website_url,
    COALESCE(c.objective_text,'Win new B2B contracts'),
    COALESCE(a.target_market_text,ad.target_market_text,'Target market'),
    j.target_count,
    (
      SELECT count(DISTINCT sc.company_id)::int
      FROM public.organisation_company_scopes sc
      WHERE sc.organisation_id=j.organisation_id
        AND sc.campaign_id=j.campaign_id
        AND sc.scope_kind='CAMPAIGN'
    ),
    greatest(
      0,
      j.target_count-public.marketroute_campaign_authority_ready_count_v1(
        j.organisation_id,j.campaign_id,p_at
      )
    ),
    j.attempt_count,
    COALESCE((
      SELECT array_agg(
        DISTINCT lower(cmp.canonical_domain)
        ORDER BY lower(cmp.canonical_domain)
      )
      FROM public.organisation_company_scopes sc
      JOIN public.companies cmp ON cmp.id=sc.company_id
      WHERE sc.organisation_id=j.organisation_id
        AND sc.campaign_id=j.campaign_id
        AND sc.scope_kind='CAMPAIGN'
        AND cmp.canonical_domain IS NOT NULL
    ),'{}'::text[])
  FROM public.paid_campaign_refill_jobs j
  JOIN public.campaigns c
    ON c.id=j.campaign_id
   AND c.organisation_id=j.organisation_id
  JOIN public.seller_businesses s
    ON s.id=c.seller_business_id
   AND s.organisation_id=c.organisation_id
  LEFT JOIN public.workspace_activation_jobs a
    ON a.id=c.activation_job_id
   AND a.organisation_id=c.organisation_id
  LEFT JOIN public.anonymous_discovery_runs ad
    ON ad.original_campaign_id=c.id
   AND ad.organisation_id=c.organisation_id
  WHERE j.id=v_job;
END;
$fn$;

REVOKE ALL ON FUNCTION public.marketroute_claim_paid_campaign_refill_v1(text,timestamptz)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_claim_paid_campaign_refill_v1(text,timestamptz)
TO service_role;

INSERT INTO public.marketroute_schema_releases(
  release_key,build_number,constitution_version,metadata_json
)
VALUES(
  'MARKETROUTE_RC_067_PAID_REFILL_CLAIM_AMBIGUITY_HOTFIX',
  64,
  'MRV2-CONSTITUTION-1.0.0',
  jsonb_build_object(
    'migration','0064_paid_campaign_refill_claim_ambiguity_hotfix.sql',
    'new_authority_writer',false,
    'authority_semantics_unchanged',true,
    'paid_refill_claim_ambiguity_fixed',true,
    'named_conflict_constraint',true,
    'qualified_attempt_increment',true,
    'target_ready_opportunities',10,
    'candidate_ceiling',60,
    'attempt_ceiling',6,
    'autonomous_delivery_enabled',false
  )
)
ON CONFLICT(release_key) DO UPDATE SET metadata_json=EXCLUDED.metadata_json;

NOTIFY pgrst,'reload schema';
COMMIT;
