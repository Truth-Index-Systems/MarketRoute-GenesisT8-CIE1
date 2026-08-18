BEGIN;

-- MarketRoute RC hotfix: remove PL/pgSQL output-parameter ambiguity from
-- anonymous Discovery continuation claiming. This is orchestration only.
-- release_contract: new_authority_writer=false; authority_semantics_unchanged=true; claim_ambiguity_fixed=true.
CREATE OR REPLACE FUNCTION public.marketroute_claim_anonymous_discovery_extension_v1(p_worker_id text,p_at timestamptz DEFAULT now())
RETURNS TABLE(job_id uuid,run_id uuid,organisation_id uuid,campaign_id uuid,seller_business_id uuid,seller_name text,canonical_domain text,website_url text,objective_text text,target_market_text text,target_count integer,scoped_count integer,remaining_count integer,attempt_count integer,existing_domains text[])
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_job uuid;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF length(btrim(COALESCE(p_worker_id,'')))<3 THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_EXTENSION_WORKER_REQUIRED'; END IF;

  INSERT INTO public.anonymous_discovery_extension_jobs(run_id,organisation_id,campaign_id,status,available_at)
  SELECT r.id,r.organisation_id,c.id,'PENDING',p_at
  FROM public.anonymous_discovery_runs r
  JOIN LATERAL (SELECT c1.id FROM public.campaigns c1 WHERE c1.organisation_id=r.organisation_id AND c1.workflow_state='ACTIVE' ORDER BY c1.created_at LIMIT 1) c ON true
  WHERE r.status IN('ACTIVE','CLAIMED')
    AND r.research_expires_at>p_at
    AND NOT public.marketroute_paid_entitlement_active_v1(r.organisation_id,p_at)
    AND (SELECT count(DISTINCT s.company_id) FROM public.organisation_company_scopes s WHERE s.organisation_id=r.organisation_id AND s.campaign_id=c.id AND s.scope_kind='CAMPAIGN') < r.target_count
  ON CONFLICT ON CONSTRAINT anonymous_discovery_extension_jobs_run_id_key DO UPDATE SET
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

  UPDATE public.anonymous_discovery_extension_jobs
  SET status='RUNNING',attempt_count=anonymous_discovery_extension_jobs.attempt_count+1,worker_id=left(btrim(p_worker_id),200),lease_expires_at=p_at+interval '5 minutes',last_error_code=NULL
  WHERE id=v_job;

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

REVOKE ALL ON FUNCTION public.marketroute_claim_anonymous_discovery_extension_v1(text,timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_claim_anonymous_discovery_extension_v1(text,timestamptz) TO service_role;

COMMIT;
