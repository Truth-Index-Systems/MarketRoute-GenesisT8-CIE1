BEGIN;

-- MarketRoute V2 RC — campaign activation lineage modernisation.
--
-- Removes the last single-campaign activation assumption from the production
-- bootstrap path. Activation jobs become immutable per request, additional
-- campaigns are explicitly CUSTOMER_CAMPAIGN work, and anonymous policy can
-- only apply to the exact original anonymous activation job.
--
-- This is orchestration / commercial-product state only. It creates no Truth,
-- R4, R5, R6, opportunity, engagement, or execution authority writer.

ALTER TABLE public.workspace_activation_jobs
  ADD COLUMN IF NOT EXISTS activation_kind text;

ALTER TABLE public.campaigns
  ADD COLUMN IF NOT EXISTS activation_job_id uuid;

-- The original table was one row per organisation. Multi-campaign activation
-- must retain a job per request instead of mutating the previous job in place.
ALTER TABLE public.workspace_activation_jobs
  DROP CONSTRAINT IF EXISTS workspace_activation_jobs_organisation_id_key;

-- Repair any claimed anonymous workspace whose original activation row was
-- already overwritten by an additional-campaign submission. The anonymous run
-- receives a historical immutable job; the currently queued/recent job remains
-- available as CUSTOMER_CAMPAIGN work.
DO $do$
DECLARE
  rec record;
  v_job public.workspace_activation_jobs%ROWTYPE;
  v_new_job uuid;
  v_result_campaign uuid;
  v_stage_campaign uuid;
  v_reused boolean;
BEGIN
  FOR rec IN
    SELECT r.*
    FROM public.anonymous_discovery_runs r
    ORDER BY r.created_at,r.id
  LOOP
    SELECT * INTO v_job
    FROM public.workspace_activation_jobs j
    WHERE j.id=rec.activation_job_id;

    IF NOT FOUND THEN
      CONTINUE;
    END IF;

    v_result_campaign:=NULL;
    v_stage_campaign:=NULL;
    BEGIN
      IF nullif(v_job.result_json->>'campaignId','') IS NOT NULL THEN
        v_result_campaign:=(v_job.result_json->>'campaignId')::uuid;
      END IF;
    EXCEPTION WHEN invalid_text_representation THEN
      v_result_campaign:=NULL;
    END;
    BEGIN
      IF nullif(v_job.activation_stage_detail_json->>'campaignId','') IS NOT NULL THEN
        v_stage_campaign:=(v_job.activation_stage_detail_json->>'campaignId')::uuid;
      END IF;
    EXCEPTION WHEN invalid_text_representation THEN
      v_stage_campaign:=NULL;
    END;

    v_reused := rec.original_campaign_id IS NOT NULL AND (
      COALESCE(nullif(btrim(v_job.campaign_name),''),'MarketRoute discovery') IS DISTINCT FROM 'MarketRoute discovery'
      OR btrim(v_job.objective_text) IS DISTINCT FROM btrim(COALESCE(rec.objective_text,v_job.objective_text))
      OR btrim(v_job.target_market_text) IS DISTINCT FROM btrim(COALESCE(rec.target_market_text,v_job.target_market_text))
      OR (v_result_campaign IS NOT NULL AND v_result_campaign IS DISTINCT FROM rec.original_campaign_id)
      OR (v_stage_campaign IS NOT NULL AND v_stage_campaign IS DISTINCT FROM rec.original_campaign_id)
    );

    IF v_reused THEN
      INSERT INTO public.workspace_activation_jobs(
        organisation_id,seller_business_id,campaign_name,seller_offering_text,
        objective_text,target_market_text,hard_constraints_text,no_hard_constraints,
        status,attempt_count,available_at,worker_id,lease_expires_at,last_error_code,
        result_json,activation_stage,activation_progress,activation_stage_detail_json,
        activation_kind,created_at,updated_at
      ) VALUES(
        rec.organisation_id,rec.seller_business_id,'MarketRoute discovery',v_job.seller_offering_text,
        COALESCE(rec.objective_text,v_job.objective_text),COALESCE(rec.target_market_text,v_job.target_market_text),
        NULL,true,'SUCCEEDED',GREATEST(1,v_job.attempt_count),rec.created_at,NULL,NULL,NULL,
        CASE WHEN rec.original_campaign_id IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('campaignId',rec.original_campaign_id) END,
        'READY',100,
        CASE WHEN rec.original_campaign_id IS NULL THEN jsonb_build_object('recoveredAt',now()) ELSE jsonb_build_object('campaignId',rec.original_campaign_id,'recoveredAt',now()) END,
        'ANONYMOUS_DISCOVERY',rec.created_at,now()
      ) RETURNING id INTO v_new_job;

      UPDATE public.anonymous_discovery_runs
      SET activation_job_id=v_new_job,updated_at=now()
      WHERE id=rec.id;

      UPDATE public.workspace_activation_jobs
      SET activation_kind='CUSTOMER_CAMPAIGN'
      WHERE id=v_job.id;
    ELSE
      UPDATE public.workspace_activation_jobs
      SET activation_kind='ANONYMOUS_DISCOVERY'
      WHERE id=v_job.id;
    END IF;
  END LOOP;
END;
$do$;

-- Classify all remaining historical jobs. Named non-anonymous jobs represent
-- configured campaign activation; unnamed rows are original workspace setup.
UPDATE public.workspace_activation_jobs j
SET activation_kind=CASE
  WHEN EXISTS(SELECT 1 FROM public.anonymous_discovery_runs r WHERE r.activation_job_id=j.id) THEN 'ANONYMOUS_DISCOVERY'
  WHEN nullif(btrim(j.campaign_name),'') IS NOT NULL THEN 'CUSTOMER_CAMPAIGN'
  ELSE 'WORKSPACE_INITIAL'
END
WHERE j.activation_kind IS NULL;

ALTER TABLE public.workspace_activation_jobs
  ALTER COLUMN activation_kind SET DEFAULT 'WORKSPACE_INITIAL',
  ALTER COLUMN activation_kind SET NOT NULL;

DO $do$
BEGIN
  IF NOT EXISTS(
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.workspace_activation_jobs'::regclass
      AND conname='workspace_activation_kind_valid'
  ) THEN
    ALTER TABLE public.workspace_activation_jobs
      ADD CONSTRAINT workspace_activation_kind_valid
      CHECK (activation_kind IN('WORKSPACE_INITIAL','ANONYMOUS_DISCOVERY','CUSTOMER_CAMPAIGN'));
  END IF;
END;
$do$;

CREATE INDEX IF NOT EXISTS workspace_activation_org_history_idx
  ON public.workspace_activation_jobs(organisation_id,created_at DESC,id DESC);
CREATE INDEX IF NOT EXISTS workspace_activation_kind_claim_idx
  ON public.workspace_activation_jobs(activation_kind,status,available_at,created_at);
CREATE UNIQUE INDEX IF NOT EXISTS workspace_activation_one_processing_per_org_idx
  ON public.workspace_activation_jobs(organisation_id)
  WHERE status IN('PENDING','RUNNING');

DO $do$
BEGIN
  IF NOT EXISTS(
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.campaigns'::regclass
      AND conname='campaigns_activation_job_fk'
  ) THEN
    ALTER TABLE public.campaigns
      ADD CONSTRAINT campaigns_activation_job_fk
      FOREIGN KEY(activation_job_id) REFERENCES public.workspace_activation_jobs(id) ON DELETE SET NULL;
  END IF;
END;
$do$;
CREATE UNIQUE INDEX IF NOT EXISTS campaigns_activation_job_unique_idx
  ON public.campaigns(activation_job_id)
  WHERE activation_job_id IS NOT NULL;

-- First restore explicit anonymous lineage, then backfill any other campaign for
-- which a historical activation job still has an exact campaign result.
UPDATE public.campaigns c
SET activation_job_id=r.activation_job_id
FROM public.anonymous_discovery_runs r
WHERE r.original_campaign_id=c.id
  AND c.activation_job_id IS NULL;

UPDATE public.campaigns c
SET activation_job_id=j.id
FROM public.workspace_activation_jobs j
WHERE c.activation_job_id IS NULL
  AND j.activation_kind<>'ANONYMOUS_DISCOVERY'
  AND (
    nullif(j.result_json->>'campaignId','')=c.id::text
    OR nullif(j.activation_stage_detail_json->>'campaignId','')=c.id::text
  )
  AND c.organisation_id=j.organisation_id;

-- If the legacy organisation-global policy already misclassified an additional
-- campaign before this migration landed, repair only the unmistakable launch-
-- anonymous policy signature. Deliberately low custom customer policies are not
-- touched unless the workspace also has anonymous Discovery lineage and the
-- campaign is bound to a CUSTOMER_CAMPAIGN activation job.
UPDATE public.research_budget_policies rp
SET daily_budget_usd=100.00000000,
    max_job_cost_usd=0.50000000,
    max_concurrent_jobs=2,
    max_work_units_per_plan=4,
    refresh_horizon_hours=2,
    enabled=true,
    updated_at=now()
FROM public.campaigns c
JOIN public.workspace_activation_jobs j ON j.id=c.activation_job_id
WHERE rp.organisation_id=c.organisation_id
  AND rp.campaign_id=c.id
  AND j.activation_kind='CUSTOMER_CAMPAIGN'
  AND EXISTS(SELECT 1 FROM public.anonymous_discovery_runs r WHERE r.organisation_id=c.organisation_id)
  AND rp.daily_budget_usd<=1.00000000
  AND rp.max_job_cost_usd<=0.35000000
  AND rp.max_concurrent_jobs=1
  AND rp.max_work_units_per_plan<=3
  AND rp.refresh_horizon_hours>=12;

-- A configured additional campaign always creates a fresh immutable activation
-- job. Capacity is checked transactionally immediately before insertion.
CREATE OR REPLACE FUNCTION public.marketroute_submit_campaign_v3(
  p_organisation_id uuid,
  p_campaign_name text,
  p_seller_offering_text text,
  p_objective_text text,
  p_target_market_text text,
  p_hard_constraints_text text,
  p_no_hard_constraints boolean
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE
  v_user uuid:=auth.uid();
  v_seller uuid;
  v_job uuid;
  v_name text:=nullif(btrim(COALESCE(p_campaign_name,'')),'');
  v_offering text:=nullif(btrim(COALESCE(p_seller_offering_text,'')),'');
  v_no_hard boolean:=COALESCE(p_no_hard_constraints,false);
  v_hard text:=nullif(btrim(COALESCE(p_hard_constraints_text,'')),'');
  v_plan_code text;
  v_limit integer;
  v_live integer;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_AUTH_REQUIRED'; END IF;
  IF NOT public.marketroute_is_org_admin(p_organisation_id) THEN RAISE EXCEPTION 'MARKETROUTE_CAMPAIGN_ADMIN_REQUIRED'; END IF;
  IF v_name IS NULL OR length(v_name) NOT BETWEEN 3 AND 120 THEN RAISE EXCEPTION 'MARKETROUTE_CAMPAIGN_NAME_REQUIRED'; END IF;
  IF v_offering IS NULL OR length(v_offering)<8 THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_OFFERING_REQUIRED'; END IF;
  IF length(btrim(COALESCE(p_objective_text,'')))<8 THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_OBJECTIVE_REQUIRED'; END IF;
  IF length(btrim(COALESCE(p_target_market_text,'')))<3 THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_TARGET_REQUIRED'; END IF;
  IF v_no_hard AND v_hard IS NOT NULL THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_CONSTRAINT_CONFLICT'; END IF;
  IF NOT v_no_hard AND v_hard IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_CONSTRAINT_DECLARATION_REQUIRED'; END IF;

  PERFORM 1 FROM public.organisations o
  WHERE o.id=p_organisation_id AND o.status='ACTIVE'
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_WORKSPACE_NOT_ACTIVE'; END IF;

  SELECT e.plan_code,p.active_market_limit
  INTO v_plan_code,v_limit
  FROM public.organisation_commercial_entitlements e
  JOIN public.marketroute_plan_catalog p ON p.plan_code=e.plan_code
  WHERE e.organisation_id=p_organisation_id
    AND e.status='ACTIVE'
    AND e.plan_code IN('STARTER','GROWTH','SCALE','LEGACY_FULL')
    AND (e.current_period_start IS NULL OR e.current_period_start<=now())
    AND (e.current_period_end IS NULL OR e.current_period_end>now())
  ORDER BY e.updated_at DESC LIMIT 1;
  IF v_plan_code IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_CAMPAIGN_PLAN_REQUIRED'; END IF;

  SELECT count(*)::int INTO v_live
  FROM public.campaigns c
  WHERE c.organisation_id=p_organisation_id AND c.workflow_state<>'ARCHIVED';
  IF v_live>=v_limit THEN RAISE EXCEPTION 'MARKETROUTE_CAMPAIGN_LIMIT_REACHED'; END IF;

  IF EXISTS(
    SELECT 1 FROM public.workspace_activation_jobs j
    WHERE j.organisation_id=p_organisation_id
      AND (j.status='PENDING' OR (j.status='RUNNING' AND COALESCE(j.lease_expires_at,now()+interval '1 minute')>=now()))
  ) THEN
    RAISE EXCEPTION 'MARKETROUTE_CAMPAIGN_CREATION_ALREADY_PROCESSING';
  END IF;

  SELECT s.id INTO v_seller
  FROM public.seller_businesses s
  WHERE s.organisation_id=p_organisation_id AND s.lifecycle_state='ACTIVE'
  ORDER BY s.created_at,s.id LIMIT 1;
  IF v_seller IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_SELLER_NOT_FOUND'; END IF;

  INSERT INTO public.workspace_activation_jobs(
    organisation_id,seller_business_id,campaign_name,seller_offering_text,objective_text,target_market_text,
    hard_constraints_text,no_hard_constraints,status,attempt_count,available_at,worker_id,lease_expires_at,
    last_error_code,result_json,activation_stage,activation_progress,activation_stage_detail_json,activation_kind
  ) VALUES(
    p_organisation_id,v_seller,v_name,v_offering,btrim(p_objective_text),btrim(p_target_market_text),
    CASE WHEN v_no_hard THEN NULL ELSE v_hard END,v_no_hard,'PENDING',0,now(),NULL,NULL,NULL,'{}'::jsonb,
    'QUEUED',0,'{}'::jsonb,'CUSTOMER_CAMPAIGN'
  ) RETURNING id INTO v_job;

  RETURN v_job;
END;
$fn$;
REVOKE ALL ON FUNCTION public.marketroute_submit_campaign_v3(uuid,text,text,text,text,text,boolean) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_submit_campaign_v3(uuid,text,text,text,text,text,boolean) TO authenticated;

-- Compatibility endpoints are wrappers only. They can no longer execute the
-- old single-row ON CONFLICT path.
CREATE OR REPLACE FUNCTION public.marketroute_submit_campaign_v2(
  p_organisation_id uuid,p_campaign_name text,p_seller_offering_text text,p_objective_text text,
  p_target_market_text text,p_hard_constraints_text text,p_no_hard_constraints boolean
) RETURNS uuid
LANGUAGE sql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
  SELECT public.marketroute_submit_campaign_v3($1,$2,$3,$4,$5,$6,$7);
$fn$;
REVOKE ALL ON FUNCTION public.marketroute_submit_campaign_v2(uuid,text,text,text,text,text,boolean) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_submit_campaign_v2(uuid,text,text,text,text,text,boolean) TO authenticated;

CREATE OR REPLACE FUNCTION public.marketroute_submit_replacement_campaign_v1(
  p_organisation_id uuid,p_campaign_name text,p_seller_offering_text text,p_objective_text text,
  p_target_market_text text,p_hard_constraints_text text,p_no_hard_constraints boolean
) RETURNS uuid
LANGUAGE sql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
  SELECT public.marketroute_submit_campaign_v3($1,$2,$3,$4,$5,$6,$7);
$fn$;
REVOKE ALL ON FUNCTION public.marketroute_submit_replacement_campaign_v1(uuid,text,text,text,text,text,boolean) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_submit_replacement_campaign_v1(uuid,text,text,text,text,text,boolean) TO authenticated;

-- Initial setup remains available for genuinely new workspaces, but cannot be
-- used as a back door for adding campaigns to an established workspace.
CREATE OR REPLACE FUNCTION public.marketroute_submit_workspace_activation_v2(
  p_organisation_id uuid,
  p_seller_offering_text text,
  p_objective_text text,
  p_target_market_text text,
  p_hard_constraints_text text,
  p_no_hard_constraints boolean
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE
  v_user uuid:=auth.uid();v_seller uuid;v_job uuid;
  v_offering text:=nullif(btrim(COALESCE(p_seller_offering_text,'')),'');
  v_no_hard boolean:=COALESCE(p_no_hard_constraints,false);
  v_hard text:=nullif(btrim(COALESCE(p_hard_constraints_text,'')),'');
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_AUTH_REQUIRED'; END IF;
  IF NOT public.marketroute_is_org_admin(p_organisation_id) THEN RAISE EXCEPTION 'MARKETROUTE_WORKSPACE_ADMIN_REQUIRED'; END IF;
  IF v_offering IS NULL OR length(v_offering)<8 THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_OFFERING_REQUIRED'; END IF;
  IF length(btrim(COALESCE(p_objective_text,'')))<8 THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_OBJECTIVE_REQUIRED'; END IF;
  IF length(btrim(COALESCE(p_target_market_text,'')))<3 THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_TARGET_REQUIRED'; END IF;
  IF v_no_hard AND v_hard IS NOT NULL THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_CONSTRAINT_CONFLICT'; END IF;
  IF NOT v_no_hard AND v_hard IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_CONSTRAINT_DECLARATION_REQUIRED'; END IF;

  PERFORM 1 FROM public.organisations o WHERE o.id=p_organisation_id AND o.status='ACTIVE' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_WORKSPACE_NOT_ACTIVE'; END IF;
  IF EXISTS(SELECT 1 FROM public.campaigns c WHERE c.organisation_id=p_organisation_id) THEN
    RAISE EXCEPTION 'MARKETROUTE_SETUP_ALREADY_COMPLETE';
  END IF;
  IF EXISTS(SELECT 1 FROM public.workspace_activation_jobs j WHERE j.organisation_id=p_organisation_id AND j.status IN('PENDING','RUNNING')) THEN
    RAISE EXCEPTION 'MARKETROUTE_CAMPAIGN_CREATION_ALREADY_PROCESSING';
  END IF;

  SELECT id INTO v_seller FROM public.seller_businesses
  WHERE organisation_id=p_organisation_id AND lifecycle_state='ACTIVE'
  ORDER BY created_at,id LIMIT 1;
  IF v_seller IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_SELLER_NOT_FOUND'; END IF;

  INSERT INTO public.workspace_activation_jobs(
    organisation_id,seller_business_id,campaign_name,seller_offering_text,objective_text,target_market_text,
    hard_constraints_text,no_hard_constraints,status,attempt_count,available_at,worker_id,lease_expires_at,
    last_error_code,result_json,activation_stage,activation_progress,activation_stage_detail_json,activation_kind
  ) VALUES(
    p_organisation_id,v_seller,NULL,v_offering,btrim(p_objective_text),btrim(p_target_market_text),
    CASE WHEN v_no_hard THEN NULL ELSE v_hard END,v_no_hard,'PENDING',0,now(),NULL,NULL,NULL,'{}'::jsonb,
    'QUEUED',0,'{}'::jsonb,'WORKSPACE_INITIAL'
  ) RETURNING id INTO v_job;
  RETURN v_job;
END;
$fn$;
REVOKE ALL ON FUNCTION public.marketroute_submit_workspace_activation_v2(uuid,text,text,text,text,boolean) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_submit_workspace_activation_v2(uuid,text,text,text,text,boolean) TO authenticated;

-- V1 remains callable only for deployment compatibility; it can reuse a known
-- seller offering but cannot create an ambiguous legacy activation.
CREATE OR REPLACE FUNCTION public.marketroute_submit_workspace_activation_v1(
  p_organisation_id uuid,p_objective_text text,p_target_market_text text,p_hard_constraints_text text,p_no_hard_constraints boolean
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_offering text;
BEGIN
  SELECT j.seller_offering_text INTO v_offering
  FROM public.workspace_activation_jobs j
  WHERE j.organisation_id=p_organisation_id AND j.seller_offering_text IS NOT NULL
  ORDER BY j.created_at DESC,j.id DESC LIMIT 1;
  IF v_offering IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_CLIENT_UPGRADE_REQUIRED'; END IF;
  RETURN public.marketroute_submit_workspace_activation_v2(
    p_organisation_id,v_offering,p_objective_text,p_target_market_text,p_hard_constraints_text,p_no_hard_constraints
  );
END;
$fn$;
REVOKE ALL ON FUNCTION public.marketroute_submit_workspace_activation_v1(uuid,text,text,text,boolean) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_submit_workspace_activation_v1(uuid,text,text,text,boolean) TO authenticated;

-- Bootstrap claims an immutable activation request and exposes its origin.
CREATE OR REPLACE FUNCTION public.marketroute_claim_workspace_activation_v4(
  p_worker_id text,p_at timestamptz DEFAULT now()
) RETURNS TABLE(
  job_id uuid,organisation_id uuid,seller_business_id uuid,seller_name text,canonical_domain text,website_url text,
  created_by_user_id uuid,campaign_name text,seller_offering_text text,objective_text text,target_market_text text,
  hard_constraints_text text,no_hard_constraints boolean,attempt_count integer,activation_kind text
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_id uuid;
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT j.id INTO v_id
  FROM public.workspace_activation_jobs j
  WHERE ((j.status IN('PENDING','FAILED') AND j.available_at<=p_at) OR (j.status='RUNNING' AND j.lease_expires_at<p_at))
    AND j.attempt_count<5
    AND j.seller_offering_text IS NOT NULL
  ORDER BY j.available_at,j.created_at,j.id
  FOR UPDATE SKIP LOCKED LIMIT 1;
  IF v_id IS NULL THEN RETURN; END IF;

  UPDATE public.workspace_activation_jobs j
  SET status='RUNNING',attempt_count=j.attempt_count+1,worker_id=left(btrim(p_worker_id),200),
      lease_expires_at=p_at+interval '10 minutes',last_error_code=NULL
  WHERE j.id=v_id;

  RETURN QUERY
  SELECT j.id,j.organisation_id,j.seller_business_id,s.name,s.canonical_domain,s.website_url,o.created_by,
         j.campaign_name,j.seller_offering_text,j.objective_text,j.target_market_text,j.hard_constraints_text,
         j.no_hard_constraints,j.attempt_count,j.activation_kind
  FROM public.workspace_activation_jobs j
  JOIN public.seller_businesses s ON s.id=j.seller_business_id AND s.organisation_id=j.organisation_id
  JOIN public.organisations o ON o.id=j.organisation_id
  WHERE j.id=v_id;
END;
$fn$;
REVOKE ALL ON FUNCTION public.marketroute_claim_workspace_activation_v4(text,timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_claim_workspace_activation_v4(text,timestamptz) TO service_role;

-- Rollout compatibility: older bootstrap instances still call the organisation-
-- level policy. Once they have claimed a CUSTOMER_CAMPAIGN job, fail closed and
-- return no anonymous policy. This makes SQL-first deployment safe.
CREATE OR REPLACE FUNCTION public.marketroute_anonymous_discovery_policy_v1(p_organisation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_run public.anonymous_discovery_runs%ROWTYPE;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF public.marketroute_paid_entitlement_active_v1(p_organisation_id,now()) THEN RETURN NULL; END IF;
  IF EXISTS(
    SELECT 1 FROM public.workspace_activation_jobs j
    WHERE j.organisation_id=p_organisation_id
      AND j.status='RUNNING'
      AND j.activation_kind<>'ANONYMOUS_DISCOVERY'
  ) THEN RETURN NULL; END IF;
  SELECT * INTO v_run
  FROM public.anonymous_discovery_runs r
  JOIN public.workspace_activation_jobs j ON j.id=r.activation_job_id
  WHERE r.organisation_id=p_organisation_id
    AND j.activation_kind='ANONYMOUS_DISCOVERY'
    AND r.status IN('ACTIVE','CLAIMED')
    AND r.research_expires_at>now();
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN jsonb_build_object(
    'runId',v_run.id,'lifetimeBudgetUsd',v_run.lifetime_budget_usd,
    'researchExpiresAt',v_run.research_expires_at,'targetCount',v_run.target_count,
    'originalCampaignId',v_run.original_campaign_id
  );
END;
$fn$;
REVOKE ALL ON FUNCTION public.marketroute_anonymous_discovery_policy_v1(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_anonymous_discovery_policy_v1(uuid) TO service_role;

-- Anonymous launch policy is no longer organisation-global in the modern worker.
-- It is available only to the immutable activation job that created Discovery.
CREATE OR REPLACE FUNCTION public.marketroute_anonymous_discovery_policy_for_activation_v1(
  p_organisation_id uuid,p_activation_job_id uuid
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_run public.anonymous_discovery_runs%ROWTYPE;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF NOT EXISTS(
    SELECT 1 FROM public.workspace_activation_jobs j
    WHERE j.id=p_activation_job_id AND j.organisation_id=p_organisation_id AND j.activation_kind='ANONYMOUS_DISCOVERY'
  ) THEN RETURN NULL; END IF;
  IF public.marketroute_paid_entitlement_active_v1(p_organisation_id,now()) THEN RETURN NULL; END IF;
  SELECT * INTO v_run
  FROM public.anonymous_discovery_runs r
  WHERE r.organisation_id=p_organisation_id
    AND r.activation_job_id=p_activation_job_id
    AND r.status IN('ACTIVE','CLAIMED')
    AND r.research_expires_at>now();
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN jsonb_build_object(
    'runId',v_run.id,'lifetimeBudgetUsd',v_run.lifetime_budget_usd,
    'researchExpiresAt',v_run.research_expires_at,'targetCount',v_run.target_count,
    'originalCampaignId',v_run.original_campaign_id
  );
END;
$fn$;
REVOKE ALL ON FUNCTION public.marketroute_anonymous_discovery_policy_for_activation_v1(uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_anonymous_discovery_policy_for_activation_v1(uuid,uuid) TO service_role;

-- Campaign creation is bound to the exact activation job. Name/objective matching
-- is no longer used as an idempotency heuristic.
CREATE OR REPLACE FUNCTION public.marketroute_create_activation_campaign_v4(
  p_job_id uuid,p_organisation_id uuid,p_seller_business_id uuid,p_campaign_name text,p_objective_text text
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE
  v_job public.workspace_activation_jobs%ROWTYPE;
  v_id uuid;v_user uuid;
  v_name text:=COALESCE(nullif(btrim(p_campaign_name),''),'Initial market research');
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF length(v_name) NOT BETWEEN 3 AND 120 THEN RAISE EXCEPTION 'MARKETROUTE_CAMPAIGN_NAME_REQUIRED'; END IF;

  SELECT * INTO v_job FROM public.workspace_activation_jobs j
  WHERE j.id=p_job_id AND j.organisation_id=p_organisation_id AND j.seller_business_id=p_seller_business_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_ACTIVATION_JOB_SCOPE_INVALID'; END IF;

  SELECT c.id INTO v_id
  FROM public.campaigns c
  WHERE c.activation_job_id=p_job_id AND c.organisation_id=p_organisation_id;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;

  IF nullif(v_job.result_json->>'campaignId','') IS NOT NULL THEN
    BEGIN v_id:=(v_job.result_json->>'campaignId')::uuid; EXCEPTION WHEN invalid_text_representation THEN v_id:=NULL; END;
    IF v_id IS NOT NULL AND EXISTS(SELECT 1 FROM public.campaigns c WHERE c.id=v_id AND c.organisation_id=p_organisation_id) THEN
      UPDATE public.campaigns c SET activation_job_id=p_job_id WHERE c.id=v_id AND c.activation_job_id IS NULL;
      IF EXISTS(SELECT 1 FROM public.campaigns c WHERE c.id=v_id AND c.activation_job_id=p_job_id) THEN RETURN v_id; END IF;
      RAISE EXCEPTION 'MARKETROUTE_ACTIVATION_CAMPAIGN_LINEAGE_CONFLICT';
    END IF;
  END IF;

  SELECT o.created_by INTO v_user FROM public.organisations o
  WHERE o.id=p_organisation_id AND o.status='ACTIVE' FOR UPDATE;
  IF NOT FOUND OR NOT EXISTS(
    SELECT 1 FROM public.seller_businesses s
    WHERE s.id=p_seller_business_id AND s.organisation_id=p_organisation_id AND s.lifecycle_state='ACTIVE'
  ) THEN RAISE EXCEPTION 'MARKETROUTE_ACTIVATION_SCOPE_INVALID'; END IF;

  INSERT INTO public.campaigns(
    organisation_id,seller_business_id,name,workflow_state,objective_text,created_by,activation_job_id
  ) VALUES(
    p_organisation_id,p_seller_business_id,v_name,'ACTIVE',btrim(p_objective_text),v_user,p_job_id
  ) RETURNING id INTO v_id;

  UPDATE public.workspace_activation_jobs
  SET result_json=COALESCE(result_json,'{}'::jsonb)||jsonb_build_object('campaignId',v_id),updated_at=now()
  WHERE id=p_job_id;

  IF v_job.activation_kind='ANONYMOUS_DISCOVERY' THEN
    UPDATE public.anonymous_discovery_runs r
    SET original_campaign_id=COALESCE(r.original_campaign_id,v_id),updated_at=now()
    WHERE r.activation_job_id=p_job_id AND r.organisation_id=p_organisation_id;
  END IF;
  RETURN v_id;
END;
$fn$;
REVOKE ALL ON FUNCTION public.marketroute_create_activation_campaign_v4(uuid,uuid,uuid,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_create_activation_campaign_v4(uuid,uuid,uuid,text,text) TO service_role;

CREATE OR REPLACE FUNCTION public.marketroute_create_activation_campaign_v3(
  p_job_id uuid,p_organisation_id uuid,p_seller_business_id uuid,p_campaign_name text,p_objective_text text
) RETURNS uuid
LANGUAGE sql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
  SELECT public.marketroute_create_activation_campaign_v4($1,$2,$3,$4,$5);
$fn$;
REVOKE ALL ON FUNCTION public.marketroute_create_activation_campaign_v3(uuid,uuid,uuid,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_create_activation_campaign_v3(uuid,uuid,uuid,text,text) TO service_role;

-- Status reads the most recent immutable activation request rather than relying on
-- there being exactly one row for the workspace.
CREATE OR REPLACE FUNCTION public.marketroute_workspace_activation_status_v2(p_organisation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_job public.workspace_activation_jobs%ROWTYPE;v_campaign_id uuid;v_campaign_name text;
BEGIN
  IF auth.uid() IS NULL OR NOT public.marketroute_is_org_member(p_organisation_id) THEN
    RAISE EXCEPTION 'MARKETROUTE_WORKSPACE_ACCESS_DENIED';
  END IF;
  SELECT * INTO v_job
  FROM public.workspace_activation_jobs j
  WHERE j.organisation_id=p_organisation_id
  ORDER BY j.created_at DESC,j.id DESC LIMIT 1;
  IF NOT FOUND THEN
    SELECT id,name INTO v_campaign_id,v_campaign_name FROM public.campaigns
    WHERE organisation_id=p_organisation_id AND workflow_state<>'ARCHIVED'
    ORDER BY updated_at DESC,id LIMIT 1;
    IF v_campaign_id IS NOT NULL THEN
      RETURN jsonb_build_object('status','NOT_REQUIRED','lastErrorCode',NULL,'campaignId',v_campaign_id,'campaignName',v_campaign_name,'stage','READY','progress',100,'stageDetail','{}'::jsonb,'activationKind',NULL,'updatedAt',NULL);
    END IF;
    RETURN jsonb_build_object('status','NOT_SUBMITTED','lastErrorCode',NULL,'campaignId',NULL,'campaignName',NULL,'stage','QUEUED','progress',0,'stageDetail','{}'::jsonb,'activationKind',NULL,'updatedAt',NULL);
  END IF;
  IF nullif(v_job.result_json->>'campaignId','') IS NOT NULL THEN
    BEGIN v_campaign_id:=(v_job.result_json->>'campaignId')::uuid; EXCEPTION WHEN invalid_text_representation THEN v_campaign_id:=NULL; END;
  END IF;
  v_campaign_name:=nullif(btrim(v_job.campaign_name),'');
  IF v_campaign_id IS NOT NULL AND v_campaign_name IS NULL THEN
    SELECT name INTO v_campaign_name FROM public.campaigns WHERE id=v_campaign_id AND organisation_id=p_organisation_id;
  END IF;
  RETURN jsonb_build_object(
    'status',v_job.status,'lastErrorCode',v_job.last_error_code,'campaignId',v_campaign_id,
    'campaignName',v_campaign_name,'stage',v_job.activation_stage,'progress',v_job.activation_progress,
    'stageDetail',v_job.activation_stage_detail_json,'activationKind',v_job.activation_kind,'updatedAt',v_job.updated_at
  );
END;
$fn$;
REVOKE ALL ON FUNCTION public.marketroute_workspace_activation_status_v2(uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_workspace_activation_status_v2(uuid) TO authenticated;

-- Anonymous Discovery status/unlocks use the immutable original campaign. There
-- is no fallback to a later active customer campaign.
CREATE OR REPLACE FUNCTION public.marketroute_anonymous_discovery_refresh_unlocks_v1(p_browser_key_hash text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE
  v_run public.anonymous_discovery_runs%ROWTYPE;v_campaign uuid;v_count integer:=0;v_candidate record;v_result jsonb:='[]'::jsonb;
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT * INTO v_run FROM public.anonymous_discovery_runs WHERE browser_key_hash=p_browser_key_hash FOR UPDATE;
  IF NOT FOUND OR v_run.status='BLOCKED' THEN RETURN '[]'::jsonb; END IF;
  v_campaign:=v_run.original_campaign_id;
  IF v_campaign IS NULL OR NOT EXISTS(SELECT 1 FROM public.campaigns c WHERE c.id=v_campaign AND c.organisation_id=v_run.organisation_id) THEN RETURN '[]'::jsonb; END IF;
  SELECT count(*)::int INTO v_count FROM public.anonymous_discovery_opportunity_unlocks WHERE run_id=v_run.id;
  IF v_count<8 THEN
    FOR v_candidate IN
      SELECT o.id AS opportunity_id,o.company_id
      FROM public.opportunities o
      WHERE o.organisation_id=v_run.organisation_id AND o.campaign_id=v_campaign
        AND o.workflow_state IN('REVIEWABLE','APPROVED','ENGAGED')
        AND public.marketroute_authority_ready_v1(o.organisation_id,o.campaign_id,o.company_id,now())
        AND NOT EXISTS(SELECT 1 FROM public.anonymous_discovery_opportunity_unlocks u WHERE u.run_id=v_run.id AND u.opportunity_id=o.id)
      ORDER BY o.created_at,o.id LIMIT greatest(0,8-v_count)
    LOOP
      v_count:=v_count+1;
      INSERT INTO public.anonymous_discovery_opportunity_unlocks(run_id,opportunity_id,company_id,ordinal)
      VALUES(v_run.id,v_candidate.opportunity_id,v_candidate.company_id,v_count) ON CONFLICT DO NOTHING;
    END LOOP;
  END IF;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'ordinal',u.ordinal,'opportunityId',u.opportunity_id,'companyId',u.company_id,'unlockedAt',u.unlocked_at,
    'company',public.marketroute_application_company_read_v1(v_run.organisation_id,v_campaign,u.company_id,now()),
    'routes',public.marketroute_application_route_display_read_v1(v_run.organisation_id,v_campaign,u.company_id,now())
  ) ORDER BY u.ordinal),'[]'::jsonb)
  INTO v_result FROM public.anonymous_discovery_opportunity_unlocks u WHERE u.run_id=v_run.id;
  RETURN v_result;
END;
$fn$;
REVOKE ALL ON FUNCTION public.marketroute_anonymous_discovery_refresh_unlocks_v1(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_anonymous_discovery_refresh_unlocks_v1(text) TO service_role;

CREATE OR REPLACE FUNCTION public.marketroute_anonymous_discovery_status_v1(p_browser_key_hash text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE
  v_run public.anonymous_discovery_runs%ROWTYPE;v_job public.workspace_activation_jobs%ROWTYPE;v_campaign uuid;
  v_scoped int:=0;v_researched int:=0;v_work_total int:=0;v_work_done int:=0;v_opps int:=0;v_r5 int:=0;v_r6 int:=0;v_free int:=0;
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT * INTO v_run FROM public.anonymous_discovery_runs WHERE browser_key_hash=p_browser_key_hash; IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT * INTO v_job FROM public.workspace_activation_jobs WHERE id=v_run.activation_job_id;
  v_campaign:=v_run.original_campaign_id;
  IF v_campaign IS NOT NULL THEN
    SELECT count(*)::int INTO v_scoped FROM public.organisation_company_scopes WHERE organisation_id=v_run.organisation_id AND campaign_id=v_campaign AND scope_kind='CAMPAIGN';
    SELECT count(DISTINCT s.company_id)::int INTO v_researched FROM public.organisation_company_scopes s WHERE s.organisation_id=v_run.organisation_id AND s.campaign_id=v_campaign AND s.scope_kind='CAMPAIGN' AND EXISTS(SELECT 1 FROM public.truth_entity_snapshots t WHERE t.subject_type='COMPANY' AND t.subject_id=s.company_id AND t.profile_key='COMPANY_CORE_V1' AND (t.tenant_scope_organisation_id IS NULL OR t.tenant_scope_organisation_id=v_run.organisation_id));
    SELECT count(*)::int,count(*) FILTER(WHERE j.status='SUCCEEDED')::int INTO v_work_total,v_work_done FROM public.research_work_units w JOIN public.background_jobs j ON j.id=w.background_job_id WHERE w.organisation_id=v_run.organisation_id AND w.campaign_id=v_campaign;
    SELECT count(*)::int INTO v_opps FROM public.opportunities WHERE organisation_id=v_run.organisation_id AND campaign_id=v_campaign;
    SELECT count(DISTINCT company_id)::int INTO v_r5 FROM public.route_authority_r5_records r WHERE r.organisation_id=v_run.organisation_id AND r.campaign_id=v_campaign AND r.decision_code='ROUTE_STRUCTURALLY_OPEN' AND public.marketroute_r5_authority_current_v1(r.authority_record_id,now());
    SELECT count(DISTINCT company_id)::int INTO v_r6 FROM public.contact_authority_r6_records r WHERE r.organisation_id=v_run.organisation_id AND r.campaign_id=v_campaign AND r.decision_code='CONTACT_AUTHORISED' AND public.marketroute_r6_authority_current_v1(r.authority_record_id,now());
  END IF;
  SELECT count(*)::int INTO v_free FROM public.anonymous_discovery_opportunity_unlocks WHERE run_id=v_run.id;
  RETURN jsonb_build_object(
    'runId',v_run.id,'companyName',v_run.company_name,'websiteUrl',v_run.website_url,
    'runStatus',CASE WHEN v_run.status='ACTIVE' AND v_run.research_expires_at<=now() THEN 'EXPIRED' ELSE v_run.status END,
    'activation',jsonb_build_object('status',COALESCE(v_job.status,'PENDING'),'stage',COALESCE(v_job.activation_stage,'QUEUED'),'progress',COALESCE(v_job.activation_progress,0),'lastErrorCode',v_job.last_error_code,'updatedAt',v_job.updated_at,'stageDetail',COALESCE(v_job.activation_stage_detail_json,'{}'::jsonb)),
    'metrics',jsonb_build_object('scopedCompanies',v_scoped,'researchedCompanies',v_researched,'researchWorkTotal',v_work_total,'researchWorkCompleted',v_work_done,'opportunities',v_opps,'structuralRoutes',v_r5,'authorisedRoutes',v_r6,'freeUnlocked',v_free)
  );
END;
$fn$;
REVOKE ALL ON FUNCTION public.marketroute_anonymous_discovery_status_v1(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_anonymous_discovery_status_v1(text) TO service_role;

-- New anonymous runs explicitly create anonymous activation work. The launch
-- limits remain frozen at 10 companies / USD 1 / 12 hours.
CREATE OR REPLACE FUNCTION public.marketroute_create_anonymous_discovery_v1(
  p_browser_key_hash text,p_ip_hash text,p_company_name text,p_website_url text,
  p_seller_offering_text text,p_target_market_text text,p_objective_text text,
  p_lifetime_budget_usd numeric,p_research_window_hours integer,p_target_count integer
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp,extensions AS $fn$
DECLARE
  v_existing public.anonymous_discovery_runs%ROWTYPE;
  v_org uuid:=gen_random_uuid();v_seller uuid:=gen_random_uuid();v_job uuid:=gen_random_uuid();v_slug text;
  v_name text:=btrim(COALESCE(p_company_name,''));v_url text:=btrim(COALESCE(p_website_url,''));v_host text;
  v_offering text:=btrim(COALESCE(p_seller_offering_text,''));v_target text:=btrim(COALESCE(p_target_market_text,''));v_objective text:=btrim(COALESCE(p_objective_text,''));
  v_budget numeric:=LEAST(1.00::numeric,GREATEST(0.50::numeric,round(COALESCE(p_lifetime_budget_usd,1.00)::numeric,8)));
  v_hours integer:=LEAST(12,GREATEST(1,COALESCE(p_research_window_hours,12)));
  v_target_count integer:=LEAST(10,GREATEST(8,COALESCE(p_target_count,10)));v_run uuid;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF COALESCE(p_browser_key_hash,'') !~ '^[a-f0-9]{64}$' OR COALESCE(p_ip_hash,'') !~ '^[a-f0-9]{64}$' THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_HASH_INVALID'; END IF;
  SELECT * INTO v_existing FROM public.anonymous_discovery_runs WHERE browser_key_hash=p_browser_key_hash;
  IF FOUND THEN RETURN jsonb_build_object('runId',v_existing.id,'existing',true); END IF;
  IF (SELECT count(*) FROM public.anonymous_discovery_runs WHERE ip_hash=p_ip_hash AND created_at>=now()-interval '24 hours')>=5 THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_IP_LIMIT'; END IF;
  IF length(v_name) NOT BETWEEN 2 AND 160 THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_COMPANY_NAME_REQUIRED'; END IF;
  IF v_url !~ '^https?://[^/]+\.[^/]+' THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_WEBSITE_INVALID'; END IF;
  v_host:=lower(regexp_replace(split_part(regexp_replace(v_url,'^https?://','','i'),'/',1),'^www\.','','i'));
  IF v_host !~ '^[a-z0-9][a-z0-9.-]*\.[a-z]{2,63}$' THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_WEBSITE_INVALID'; END IF;
  IF length(v_offering) NOT BETWEEN 8 AND 2000 THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_OFFERING_REQUIRED'; END IF;
  IF length(v_target) NOT BETWEEN 3 AND 2000 OR length(v_objective) NOT BETWEEN 8 AND 2000 THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_BRIEF_INVALID'; END IF;
  IF v_budget<0.50 OR v_budget>1.00 OR v_hours<1 OR v_hours>12 OR v_target_count<8 OR v_target_count>10 THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_POLICY_INVALID'; END IF;
  v_slug:='anon-'||left(replace(v_org::text,'-',''),20);
  INSERT INTO public.organisations(id,name,slug,status,workspace_kind,created_by) VALUES(v_org,v_name,v_slug,'ACTIVE','ANONYMOUS_DISCOVERY',NULL);
  INSERT INTO public.seller_businesses(id,organisation_id,name,canonical_domain,website_url,lifecycle_state,created_by) VALUES(v_seller,v_org,v_name,v_host,v_url,'ACTIVE',NULL);
  INSERT INTO public.workspace_activation_jobs(
    id,organisation_id,seller_business_id,campaign_name,seller_offering_text,objective_text,target_market_text,
    hard_constraints_text,no_hard_constraints,status,attempt_count,available_at,worker_id,lease_expires_at,last_error_code,result_json,
    activation_stage,activation_progress,activation_stage_detail_json,activation_kind
  ) VALUES(
    v_job,v_org,v_seller,'MarketRoute discovery',v_offering,v_objective,v_target,NULL,true,'PENDING',0,now(),NULL,NULL,NULL,'{}'::jsonb,
    'QUEUED',0,'{}'::jsonb,'ANONYMOUS_DISCOVERY'
  );
  INSERT INTO public.anonymous_discovery_runs(browser_key_hash,ip_hash,organisation_id,seller_business_id,activation_job_id,company_name,website_url,lifetime_budget_usd,target_count,research_expires_at,status,objective_text,target_market_text)
  VALUES(p_browser_key_hash,p_ip_hash,v_org,v_seller,v_job,v_name,v_url,v_budget,v_target_count,now()+make_interval(hours=>v_hours),'ACTIVE',v_objective,v_target)
  RETURNING id INTO v_run;
  RETURN jsonb_build_object('runId',v_run,'existing',false);
END;
$fn$;
REVOKE ALL ON FUNCTION public.marketroute_create_anonymous_discovery_v1(text,text,text,text,text,text,text,numeric,integer,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_create_anonymous_discovery_v1(text,text,text,text,text,text,text,numeric,integer,integer) TO service_role;

INSERT INTO public.marketroute_schema_releases(release_key,build_number,constitution_version,metadata_json)
VALUES('MARKETROUTE_V2_RC_CAMPAIGN_ACTIVATION_LINEAGE_MODERNISATION',56,'MRV2-CONSTITUTION-1.0.0',jsonb_build_object(
  'migration','0056_campaign_activation_lineage_modernisation.sql',
  'new_authority_writer',false,'authority_semantics_unchanged',true,
  'single_row_activation_removed',true,'activation_jobs_immutable_per_request',true,
  'campaign_bound_activation_lineage',true,'anonymous_policy_job_bound',true,
  'customer_campaign_cannot_inherit_anonymous_policy',true,'legacy_campaign_submit_wrapped',true,
  'anonymous_original_campaign_fallback_removed',true,'misclassified_customer_policy_repaired',true,'autonomous_delivery_enabled',false
)) ON CONFLICT(release_key) DO NOTHING;

NOTIFY pgrst,'reload schema';
COMMIT;
