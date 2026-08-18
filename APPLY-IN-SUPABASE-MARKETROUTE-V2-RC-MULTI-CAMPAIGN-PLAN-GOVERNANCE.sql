BEGIN;

-- MarketRoute V2 RC: explicit multi-campaign governance + immutable Discovery lineage.
-- Product/commercial orchestration only. No Truth, R4, R5, R6, CIE or opportunity
-- authority semantics are created or modified here.
--
-- Launch active-market allowances:
--   Discovery: 1 original run only (no additional campaign creation)
--   Starter:   1 live campaign
--   Growth:    3 live campaigns
--   Scale:    10 live campaigns
-- Paused campaigns consume a slot; ARCHIVED campaigns do not.

UPDATE public.marketroute_plan_catalog
SET active_market_limit = CASE plan_code
    WHEN 'DISCOVERY' THEN 1
    WHEN 'STARTER' THEN 1
    WHEN 'GROWTH' THEN 3
    WHEN 'SCALE' THEN 10
    WHEN 'LEGACY_FULL' THEN 100
    ELSE active_market_limit
  END,
  metadata_json = metadata_json || jsonb_build_object(
    'activeMarketLabel', CASE plan_code
      WHEN 'DISCOVERY' THEN 'One Discovery market'
      WHEN 'STARTER' THEN '1 active market'
      WHEN 'GROWTH' THEN 'Up to 3 active markets'
      WHEN 'SCALE' THEN 'Up to 10 active markets'
      WHEN 'LEGACY_FULL' THEN 'Legacy full market access'
      ELSE COALESCE(metadata_json->>'activeMarketLabel','Active markets')
    END
  ),
  updated_at = now()
WHERE plan_code IN ('DISCOVERY','STARTER','GROWTH','SCALE','LEGACY_FULL');

-- Discovery lineage must not depend on the mutable one-row-per-organisation
-- activation queue. Persist the original campaign and original brief on the run.
ALTER TABLE public.anonymous_discovery_runs
  ADD COLUMN IF NOT EXISTS original_campaign_id uuid,
  ADD COLUMN IF NOT EXISTS objective_text text,
  ADD COLUMN IF NOT EXISTS target_market_text text;

UPDATE public.anonymous_discovery_runs r
SET objective_text = COALESCE(r.objective_text, a.objective_text),
    target_market_text = COALESCE(r.target_market_text, a.target_market_text)
FROM public.workspace_activation_jobs a
WHERE a.id = r.activation_job_id
  AND (r.objective_text IS NULL OR r.target_market_text IS NULL);

-- Prefer the campaign recorded by the original activation job. If that mutable
-- row has already been reused, the earliest campaign in the organisation is the
-- original Discovery campaign by construction.
UPDATE public.anonymous_discovery_runs r
SET original_campaign_id = COALESCE(
  (
    SELECT c.id
    FROM public.campaigns c
    WHERE c.organisation_id=r.organisation_id
    ORDER BY c.created_at,c.id
    LIMIT 1
  ),
  CASE
    WHEN nullif(a.result_json->>'campaignId','') IS NOT NULL
      AND EXISTS(
        SELECT 1 FROM public.campaigns cx
        WHERE cx.id=(a.result_json->>'campaignId')::uuid
          AND cx.organisation_id=r.organisation_id
      )
    THEN (a.result_json->>'campaignId')::uuid
    ELSE NULL
  END
)
FROM public.workspace_activation_jobs a
WHERE a.id=r.activation_job_id
  AND r.original_campaign_id IS NULL;

DO $do$
BEGIN
  IF NOT EXISTS(
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.anonymous_discovery_runs'::regclass
      AND conname='anonymous_discovery_original_campaign_fk'
  ) THEN
    ALTER TABLE public.anonymous_discovery_runs
      ADD CONSTRAINT anonymous_discovery_original_campaign_fk
      FOREIGN KEY(original_campaign_id) REFERENCES public.campaigns(id) ON DELETE RESTRICT;
  END IF;
END;$do$;

-- Existing runs whose original campaign was already archived are terminal for
-- free continuation. Preserve the claimed account/intelligence, but close the
-- remaining free research window and exhaust any continuation job.
UPDATE public.anonymous_discovery_runs r
SET research_expires_at = GREATEST(r.created_at + interval '1 second', LEAST(r.research_expires_at, now())),
    updated_at = now()
WHERE r.status IN ('ACTIVE','CLAIMED')
  AND r.original_campaign_id IS NOT NULL
  AND EXISTS(
    SELECT 1 FROM public.campaigns c
    WHERE c.id=r.original_campaign_id
      AND c.organisation_id=r.organisation_id
      AND c.workflow_state='ARCHIVED'
  )
  AND r.research_expires_at>now();

UPDATE public.anonymous_discovery_extension_jobs j
SET status='EXHAUSTED',worker_id=NULL,lease_expires_at=NULL,
    last_error_code='MARKETROUTE_DISCOVERY_ORIGINAL_CAMPAIGN_ARCHIVED',updated_at=now()
WHERE j.status IN ('PENDING','RUNNING','DEFERRED','SUCCEEDED')
  AND EXISTS(
    SELECT 1
    FROM public.anonymous_discovery_runs r
    JOIN public.campaigns c ON c.id=r.original_campaign_id AND c.organisation_id=r.organisation_id
    WHERE r.id=j.run_id AND c.workflow_state='ARCHIVED'
  );

CREATE OR REPLACE FUNCTION public.marketroute_campaign_capacity_v1(
  p_organisation_id uuid,
  p_at timestamptz DEFAULT now()
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE
  v_plan_code text;
  v_plan_name text;
  v_limit integer:=1;
  v_count integer:=0;
  v_mode text:='UNENTITLED';
  v_current_price numeric:=0;
  v_next_code text;
  v_next_name text;
  v_next_limit integer;
BEGIN
  PERFORM public.marketroute_require_service_role();

  SELECT e.plan_code,p.display_name,p.active_market_limit,p.monthly_price_gbp
  INTO v_plan_code,v_plan_name,v_limit,v_current_price
  FROM public.organisation_commercial_entitlements e
  JOIN public.marketroute_plan_catalog p ON p.plan_code=e.plan_code
  WHERE e.organisation_id=p_organisation_id
    AND e.status='ACTIVE'
    AND (e.current_period_start IS NULL OR e.current_period_start<=p_at)
    AND (e.current_period_end IS NULL OR e.current_period_end>p_at)
  ORDER BY e.updated_at DESC
  LIMIT 1;

  IF v_plan_code IS NOT NULL THEN
    v_mode:=CASE WHEN v_plan_code='LEGACY_FULL' THEN 'FULL' ELSE 'PAID' END;
  ELSIF EXISTS(
    SELECT 1 FROM public.anonymous_discovery_runs r
    WHERE r.organisation_id=p_organisation_id
      AND r.status IN ('ACTIVE','CLAIMED')
  ) THEN
    v_plan_code:='DISCOVERY';v_plan_name:='MarketRoute Discovery';v_limit:=1;v_current_price:=0;v_mode:='DISCOVERY_FREE';
  ELSE
    v_plan_code:=NULL;v_plan_name:=NULL;v_limit:=1;v_current_price:=0;v_mode:='UNENTITLED';
  END IF;

  SELECT count(*)::int INTO v_count
  FROM public.campaigns c
  WHERE c.organisation_id=p_organisation_id
    AND c.workflow_state<>'ARCHIVED';

  IF v_mode IN ('PAID','FULL') AND v_count<v_limit THEN
    v_next_code:=NULL;v_next_name:=NULL;v_next_limit:=NULL;
  ELSE
    SELECT p.plan_code,p.display_name,p.active_market_limit
    INTO v_next_code,v_next_name,v_next_limit
    FROM public.marketroute_plan_catalog p
    WHERE p.public_visible=true
      AND p.plan_code IN ('STARTER','GROWTH','SCALE')
      AND p.active_market_limit>=v_count+1
      AND p.monthly_price_gbp>v_current_price
    ORDER BY p.monthly_price_gbp,p.active_market_limit
    LIMIT 1;
  END IF;

  RETURN jsonb_build_object(
    'mode',v_mode,
    'planCode',v_plan_code,
    'planName',v_plan_name,
    'activeMarketLimit',v_limit,
    'activeMarketCount',v_count,
    'remainingMarkets',greatest(0,v_limit-v_count),
    'canCreate',(v_mode IN ('PAID','FULL') AND v_count<v_limit),
    'requiresUpgrade',NOT (v_mode IN ('PAID','FULL') AND v_count<v_limit),
    'nextPlanCode',v_next_code,
    'nextPlanName',v_next_name,
    'nextPlanActiveMarketLimit',v_next_limit
  );
END;$fn$;
REVOKE ALL ON FUNCTION public.marketroute_campaign_capacity_v1(uuid,timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_campaign_capacity_v1(uuid,timestamptz) TO service_role;

-- Additional campaigns are always created from a complete configured brief.
-- Commercial capacity is checked transactionally at submission time.
CREATE OR REPLACE FUNCTION public.marketroute_submit_campaign_v2(
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
  v_existing_status text;
  v_existing_lease timestamptz;
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
    AND e.plan_code IN ('STARTER','GROWTH','SCALE','LEGACY_FULL')
    AND (e.current_period_start IS NULL OR e.current_period_start<=now())
    AND (e.current_period_end IS NULL OR e.current_period_end>now())
  ORDER BY e.updated_at DESC
  LIMIT 1;
  IF v_plan_code IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_CAMPAIGN_PLAN_REQUIRED'; END IF;

  SELECT count(*)::int INTO v_live
  FROM public.campaigns c
  WHERE c.organisation_id=p_organisation_id
    AND c.workflow_state<>'ARCHIVED';
  IF v_live>=v_limit THEN RAISE EXCEPTION 'MARKETROUTE_CAMPAIGN_LIMIT_REACHED'; END IF;

  SELECT j.status,j.lease_expires_at INTO v_existing_status,v_existing_lease
  FROM public.workspace_activation_jobs j
  WHERE j.organisation_id=p_organisation_id
  FOR UPDATE;
  IF v_existing_status='PENDING'
     OR (v_existing_status='RUNNING' AND COALESCE(v_existing_lease,now()+interval '1 minute')>=now()) THEN
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
    last_error_code,result_json,activation_stage,activation_progress,activation_stage_detail_json
  ) VALUES(
    p_organisation_id,v_seller,v_name,v_offering,btrim(p_objective_text),btrim(p_target_market_text),
    CASE WHEN v_no_hard THEN NULL ELSE v_hard END,v_no_hard,'PENDING',0,now(),NULL,NULL,NULL,'{}'::jsonb,
    'QUEUED',0,'{}'::jsonb
  )
  ON CONFLICT(organisation_id) DO UPDATE SET
    seller_business_id=EXCLUDED.seller_business_id,
    campaign_name=EXCLUDED.campaign_name,
    seller_offering_text=EXCLUDED.seller_offering_text,
    objective_text=EXCLUDED.objective_text,
    target_market_text=EXCLUDED.target_market_text,
    hard_constraints_text=EXCLUDED.hard_constraints_text,
    no_hard_constraints=EXCLUDED.no_hard_constraints,
    status='PENDING',attempt_count=0,available_at=now(),worker_id=NULL,lease_expires_at=NULL,last_error_code=NULL,
    result_json='{}'::jsonb,activation_stage='QUEUED',activation_progress=0,activation_stage_detail_json='{}'::jsonb,
    updated_at=now()
  RETURNING id INTO v_job;
  RETURN v_job;
END;$fn$;
REVOKE ALL ON FUNCTION public.marketroute_submit_campaign_v2(uuid,text,text,text,text,text,boolean) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_submit_campaign_v2(uuid,text,text,text,text,text,boolean) TO authenticated;

-- Keep the legacy RPC callable by older deployed clients, but route it through
-- the new plan-governed multi-campaign submission contract.
CREATE OR REPLACE FUNCTION public.marketroute_submit_replacement_campaign_v1(
  p_organisation_id uuid,p_campaign_name text,p_seller_offering_text text,p_objective_text text,
  p_target_market_text text,p_hard_constraints_text text,p_no_hard_constraints boolean
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
BEGIN
  RETURN public.marketroute_submit_campaign_v2(
    p_organisation_id,p_campaign_name,p_seller_offering_text,p_objective_text,
    p_target_market_text,p_hard_constraints_text,p_no_hard_constraints
  );
END;$fn$;
REVOKE ALL ON FUNCTION public.marketroute_submit_replacement_campaign_v1(uuid,text,text,text,text,text,boolean) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_submit_replacement_campaign_v1(uuid,text,text,text,text,text,boolean) TO authenticated;

-- Activation v3 is job-bound and idempotent. Every configured additional campaign
-- gets a distinct campaign row; retries return the campaign already attached to
-- this activation job instead of mutating another live campaign.
CREATE OR REPLACE FUNCTION public.marketroute_create_activation_campaign_v3(
  p_job_id uuid,
  p_organisation_id uuid,
  p_seller_business_id uuid,
  p_campaign_name text,
  p_objective_text text
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE
  v_job public.workspace_activation_jobs%ROWTYPE;
  v_id uuid;
  v_user uuid;
  v_name text:=COALESCE(nullif(btrim(p_campaign_name),''),'Initial market research');
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF length(v_name) NOT BETWEEN 3 AND 120 THEN RAISE EXCEPTION 'MARKETROUTE_CAMPAIGN_NAME_REQUIRED'; END IF;

  SELECT * INTO v_job
  FROM public.workspace_activation_jobs j
  WHERE j.id=p_job_id
    AND j.organisation_id=p_organisation_id
    AND j.seller_business_id=p_seller_business_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_ACTIVATION_JOB_SCOPE_INVALID'; END IF;

  IF nullif(v_job.result_json->>'campaignId','') IS NOT NULL THEN
    v_id:=(v_job.result_json->>'campaignId')::uuid;
    IF EXISTS(SELECT 1 FROM public.campaigns c WHERE c.id=v_id AND c.organisation_id=p_organisation_id) THEN RETURN v_id; END IF;
  END IF;
  IF nullif(v_job.activation_stage_detail_json->>'campaignId','') IS NOT NULL THEN
    v_id:=(v_job.activation_stage_detail_json->>'campaignId')::uuid;
    IF EXISTS(SELECT 1 FROM public.campaigns c WHERE c.id=v_id AND c.organisation_id=p_organisation_id) THEN
      UPDATE public.workspace_activation_jobs SET result_json=COALESCE(result_json,'{}'::jsonb)||jsonb_build_object('campaignId',v_id) WHERE id=p_job_id;
      RETURN v_id;
    END IF;
  END IF;

  SELECT o.created_by INTO v_user
  FROM public.organisations o
  WHERE o.id=p_organisation_id AND o.status='ACTIVE'
  FOR UPDATE;
  IF NOT FOUND OR NOT EXISTS(
    SELECT 1 FROM public.seller_businesses s
    WHERE s.id=p_seller_business_id AND s.organisation_id=p_organisation_id AND s.lifecycle_state='ACTIVE'
  ) THEN RAISE EXCEPTION 'MARKETROUTE_ACTIVATION_SCOPE_INVALID'; END IF;

  -- Migration-safe recovery for an activation that created its campaign under the
  -- previous function but crashed before final result persistence.
  IF v_job.attempt_count>1 OR COALESCE(v_job.activation_progress,0)>=48 THEN
    SELECT c.id INTO v_id
    FROM public.campaigns c
    WHERE c.organisation_id=p_organisation_id
      AND c.seller_business_id=p_seller_business_id
      AND c.name=v_name
      AND c.objective_text=btrim(p_objective_text)
      AND c.workflow_state<>'ARCHIVED'
    ORDER BY c.created_at DESC,c.id DESC LIMIT 1;
  END IF;

  IF v_id IS NULL THEN
    INSERT INTO public.campaigns(organisation_id,seller_business_id,name,workflow_state,objective_text,created_by)
    VALUES(p_organisation_id,p_seller_business_id,v_name,'ACTIVE',btrim(p_objective_text),v_user)
    RETURNING id INTO v_id;
  END IF;

  UPDATE public.workspace_activation_jobs
  SET result_json=COALESCE(result_json,'{}'::jsonb)||jsonb_build_object('campaignId',v_id),updated_at=now()
  WHERE id=p_job_id;

  UPDATE public.anonymous_discovery_runs r
  SET original_campaign_id=COALESCE(r.original_campaign_id,v_id),updated_at=now()
  WHERE r.activation_job_id=p_job_id;

  RETURN v_id;
END;$fn$;
REVOKE ALL ON FUNCTION public.marketroute_create_activation_campaign_v3(uuid,uuid,uuid,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_create_activation_campaign_v3(uuid,uuid,uuid,text,text) TO service_role;

-- New anonymous runs persist their immutable brief immediately. Launch cost caps
-- remain 10 companies / USD 1 / 12 hours.
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
  INSERT INTO public.workspace_activation_jobs(id,organisation_id,seller_business_id,campaign_name,seller_offering_text,objective_text,target_market_text,hard_constraints_text,no_hard_constraints,status,attempt_count,available_at,worker_id,lease_expires_at,last_error_code,result_json)
  VALUES(v_job,v_org,v_seller,'MarketRoute discovery',v_offering,v_objective,v_target,NULL,true,'PENDING',0,now(),NULL,NULL,NULL,'{}'::jsonb);
  INSERT INTO public.anonymous_discovery_runs(browser_key_hash,ip_hash,organisation_id,seller_business_id,activation_job_id,company_name,website_url,lifetime_budget_usd,target_count,research_expires_at,status,objective_text,target_market_text)
  VALUES(p_browser_key_hash,p_ip_hash,v_org,v_seller,v_job,v_name,v_url,v_budget,v_target_count,now()+make_interval(hours=>v_hours),'ACTIVE',v_objective,v_target)
  RETURNING id INTO v_run;
  RETURN jsonb_build_object('runId',v_run,'existing',false);
END;$fn$;
REVOKE ALL ON FUNCTION public.marketroute_create_anonymous_discovery_v1(text,text,text,text,text,text,text,numeric,integer,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_create_anonymous_discovery_v1(text,text,text,text,text,text,text,numeric,integer,integer) TO service_role;

-- A claimed Discovery workspace stops using anonymous activation policy as soon
-- as a paid entitlement becomes active. New paid campaigns therefore receive
-- their paid research policy and are never accidentally capped by the old free run.
CREATE OR REPLACE FUNCTION public.marketroute_anonymous_discovery_policy_v1(p_organisation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_run public.anonymous_discovery_runs%ROWTYPE;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF public.marketroute_paid_entitlement_active_v1(p_organisation_id,now()) THEN RETURN NULL; END IF;
  SELECT * INTO v_run
  FROM public.anonymous_discovery_runs r
  WHERE r.organisation_id=p_organisation_id
    AND r.status IN('ACTIVE','CLAIMED')
    AND r.research_expires_at>now();
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN jsonb_build_object('runId',v_run.id,'lifetimeBudgetUsd',v_run.lifetime_budget_usd,'researchExpiresAt',v_run.research_expires_at,'targetCount',v_run.target_count,'originalCampaignId',v_run.original_campaign_id);
END;$fn$;
REVOKE ALL ON FUNCTION public.marketroute_anonymous_discovery_policy_v1(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_anonymous_discovery_policy_v1(uuid) TO service_role;

-- Continuation follows only the immutable original Discovery campaign. It never
-- migrates to a later paid campaign created in the same workspace.
CREATE OR REPLACE FUNCTION public.marketroute_claim_anonymous_discovery_extension_v1(p_worker_id text,p_at timestamptz DEFAULT now())
RETURNS TABLE(job_id uuid,run_id uuid,organisation_id uuid,campaign_id uuid,seller_business_id uuid,seller_name text,canonical_domain text,website_url text,objective_text text,target_market_text text,target_count integer,scoped_count integer,remaining_count integer,attempt_count integer,existing_domains text[])
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_job uuid;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF length(btrim(COALESCE(p_worker_id,'')))<3 THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_EXTENSION_WORKER_REQUIRED'; END IF;

  INSERT INTO public.anonymous_discovery_extension_jobs(run_id,organisation_id,campaign_id,status,available_at)
  SELECT r.id,r.organisation_id,r.original_campaign_id,'PENDING',p_at
  FROM public.anonymous_discovery_runs r
  JOIN public.campaigns c ON c.id=r.original_campaign_id AND c.organisation_id=r.organisation_id
  WHERE r.status IN('ACTIVE','CLAIMED')
    AND r.original_campaign_id IS NOT NULL
    AND c.workflow_state='ACTIVE'
    AND r.research_expires_at>p_at
    AND NOT public.marketroute_paid_entitlement_active_v1(r.organisation_id,p_at)
    AND (SELECT count(DISTINCT s.company_id) FROM public.organisation_company_scopes s WHERE s.organisation_id=r.organisation_id AND s.campaign_id=r.original_campaign_id AND s.scope_kind='CAMPAIGN')<r.target_count
  ON CONFLICT ON CONSTRAINT anonymous_discovery_extension_jobs_run_id_key DO UPDATE SET
    campaign_id=EXCLUDED.campaign_id,
    status=CASE WHEN anonymous_discovery_extension_jobs.status IN('SUCCEEDED','EXHAUSTED') AND anonymous_discovery_extension_jobs.attempt_count<3 THEN 'PENDING' ELSE anonymous_discovery_extension_jobs.status END,
    available_at=CASE WHEN anonymous_discovery_extension_jobs.status IN('SUCCEEDED','EXHAUSTED') AND anonymous_discovery_extension_jobs.attempt_count<3 THEN p_at ELSE anonymous_discovery_extension_jobs.available_at END;

  UPDATE public.anonymous_discovery_extension_jobs j SET status='DEFERRED',worker_id=NULL,lease_expires_at=NULL,available_at=p_at,last_error_code='MARKETROUTE_ANONYMOUS_EXTENSION_LEASE_RECOVERED'
  WHERE j.status='RUNNING' AND j.lease_expires_at<p_at;

  SELECT j.id INTO v_job
  FROM public.anonymous_discovery_extension_jobs j
  JOIN public.anonymous_discovery_runs r ON r.id=j.run_id AND r.original_campaign_id=j.campaign_id
  JOIN public.campaigns c ON c.id=j.campaign_id AND c.organisation_id=j.organisation_id
  WHERE j.status IN('PENDING','DEFERRED') AND j.available_at<=p_at AND j.attempt_count<3
    AND r.status IN('ACTIVE','CLAIMED') AND r.research_expires_at>p_at AND c.workflow_state='ACTIVE'
    AND NOT public.marketroute_paid_entitlement_active_v1(j.organisation_id,p_at)
    AND (SELECT count(DISTINCT s.company_id) FROM public.organisation_company_scopes s WHERE s.organisation_id=j.organisation_id AND s.campaign_id=j.campaign_id AND s.scope_kind='CAMPAIGN')<r.target_count
  ORDER BY j.available_at,j.created_at,j.id FOR UPDATE OF j SKIP LOCKED LIMIT 1;
  IF v_job IS NULL THEN RETURN; END IF;

  UPDATE public.anonymous_discovery_extension_jobs SET status='RUNNING',attempt_count=anonymous_discovery_extension_jobs.attempt_count+1,worker_id=left(btrim(p_worker_id),200),lease_expires_at=p_at+interval '5 minutes',last_error_code=NULL WHERE id=v_job;

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
END;$fn$;
REVOKE ALL ON FUNCTION public.marketroute_claim_anonymous_discovery_extension_v1(text,timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_claim_anonymous_discovery_extension_v1(text,timestamptz) TO service_role;

-- Archiving the original Discovery campaign terminates only that free continuation
-- envelope. Paid/new campaigns are separate and unaffected.
CREATE OR REPLACE FUNCTION public.marketroute_discovery_campaign_archive_guard_v1()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
BEGIN
  IF OLD.workflow_state IS DISTINCT FROM 'ARCHIVED' AND NEW.workflow_state='ARCHIVED' THEN
    UPDATE public.anonymous_discovery_runs r
    SET research_expires_at=GREATEST(r.created_at+interval '1 second',LEAST(r.research_expires_at,now())),updated_at=now()
    WHERE r.original_campaign_id=NEW.id AND r.organisation_id=NEW.organisation_id AND r.status IN('ACTIVE','CLAIMED');
    UPDATE public.anonymous_discovery_extension_jobs j
    SET status='EXHAUSTED',worker_id=NULL,lease_expires_at=NULL,last_error_code='MARKETROUTE_DISCOVERY_ORIGINAL_CAMPAIGN_ARCHIVED',updated_at=now()
    WHERE j.campaign_id=NEW.id AND j.organisation_id=NEW.organisation_id AND j.status IN('PENDING','RUNNING','DEFERRED','SUCCEEDED');
  END IF;
  RETURN NEW;
END;$fn$;
DROP TRIGGER IF EXISTS campaign_discovery_archive_guard ON public.campaigns;
CREATE TRIGGER campaign_discovery_archive_guard
AFTER UPDATE OF workflow_state ON public.campaigns
FOR EACH ROW EXECUTE FUNCTION public.marketroute_discovery_campaign_archive_guard_v1();

INSERT INTO public.marketroute_schema_releases(release_key,build_number,constitution_version,metadata_json)
VALUES('MARKETROUTE_V2_RC_MULTI_CAMPAIGN_PLAN_GOVERNANCE',53,'MRV2-CONSTITUTION-1.0.0',jsonb_build_object(
  'migration','0053_multi_campaign_plan_governance.sql','new_authority_writer',false,'authority_semantics_unchanged',true,
  'starter_active_market_limit',1,'growth_active_market_limit',3,'scale_active_market_limit',10,
  'add_campaign_always_visible',true,'campaign_configuration_required',true,'campaign_limit_server_enforced',true,
  'discovery_lineage_immutable',true,'discovery_archive_terminates_free_continuation',true
)) ON CONFLICT(release_key) DO NOTHING;

NOTIFY pgrst,'reload schema';
COMMIT;
