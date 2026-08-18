BEGIN;

-- MarketRoute V2 Anonymous Discovery Launch Cost Freeze.
--
-- Launch policy:
--   * first 8 authority-ready opportunities remain permanently free;
--   * at most 10 companies are scoped by a free anonymous discovery run;
--   * therefore at most 2 additional company opportunities can sit beyond the
--     permanent free-eight boundary for a newly-created run;
--   * anonymous AI research has a hard USD 1.00 lifetime ceiling;
--   * anonymous research closes after at most 12 hours;
--   * browser/environment inputs may lower those ceilings but can never raise them.
--
-- This is a product-cost boundary only. It creates no authority, changes no Truth
-- semantics, and does not alter R4/R5/R6/CIE decisions.

-- Existing ACTIVE/CLAIMED anonymous runs are tightened so a deployment cannot
-- leave an older generous policy consuming research after the launch freeze.
-- Already-persisted evidence/scope/opportunities are intentionally preserved.
UPDATE public.anonymous_discovery_runs
SET lifetime_budget_usd = LEAST(lifetime_budget_usd, 1.00::numeric),
    target_count = LEAST(target_count, 10),
    research_expires_at = LEAST(research_expires_at, created_at + interval '12 hours'),
    updated_at = now()
WHERE status IN ('ACTIVE','CLAIMED')
  AND (
    lifetime_budget_usd > 1.00::numeric
    OR target_count > 10
    OR research_expires_at > created_at + interval '12 hours'
  );

CREATE OR REPLACE FUNCTION public.marketroute_create_anonymous_discovery_v1(
  p_browser_key_hash text,
  p_ip_hash text,
  p_company_name text,
  p_website_url text,
  p_seller_offering_text text,
  p_target_market_text text,
  p_objective_text text,
  p_lifetime_budget_usd numeric,
  p_research_window_hours integer,
  p_target_count integer
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp,extensions
AS $fn$
DECLARE
  v_existing public.anonymous_discovery_runs%ROWTYPE;
  v_org uuid:=gen_random_uuid();
  v_seller uuid:=gen_random_uuid();
  v_job uuid:=gen_random_uuid();
  v_slug text;
  v_name text:=btrim(COALESCE(p_company_name,''));
  v_url text:=btrim(COALESCE(p_website_url,''));
  v_host text;
  v_offering text:=btrim(COALESCE(p_seller_offering_text,''));
  v_target text:=btrim(COALESCE(p_target_market_text,''));
  v_objective text:=btrim(COALESCE(p_objective_text,''));
  -- Defence in depth: service callers may request a smaller run, never a more
  -- expensive one. The launch ceilings are enforced here independently of Vercel.
  v_budget numeric:=LEAST(1.00::numeric,GREATEST(0.50::numeric,round(COALESCE(p_lifetime_budget_usd,1.00)::numeric,8)));
  v_hours integer:=LEAST(12,GREATEST(1,COALESCE(p_research_window_hours,12)));
  v_target_count integer:=LEAST(10,GREATEST(8,COALESCE(p_target_count,10)));
  v_run uuid;
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
  -- These checks document the invariant after clamping and fail closed if the
  -- implementation is ever edited inconsistently.
  IF v_budget<0.50 OR v_budget>1.00 OR v_hours<1 OR v_hours>12 OR v_target_count<8 OR v_target_count>10 THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_POLICY_INVALID'; END IF;
  v_slug:='anon-'||left(replace(v_org::text,'-',''),20);

  INSERT INTO public.organisations(id,name,slug,status,workspace_kind,created_by)
  VALUES(v_org,v_name,v_slug,'ACTIVE','ANONYMOUS_DISCOVERY',NULL);
  INSERT INTO public.seller_businesses(id,organisation_id,name,canonical_domain,website_url,lifecycle_state,created_by)
  VALUES(v_seller,v_org,v_name,v_host,v_url,'ACTIVE',NULL);
  INSERT INTO public.workspace_activation_jobs(
    id,organisation_id,seller_business_id,campaign_name,seller_offering_text,objective_text,target_market_text,
    hard_constraints_text,no_hard_constraints,status,attempt_count,available_at,worker_id,lease_expires_at,last_error_code,result_json
  ) VALUES(
    v_job,v_org,v_seller,'MarketRoute discovery',v_offering,v_objective,v_target,NULL,true,'PENDING',0,now(),NULL,NULL,NULL,'{}'::jsonb
  );
  INSERT INTO public.anonymous_discovery_runs(
    browser_key_hash,ip_hash,organisation_id,seller_business_id,activation_job_id,company_name,website_url,lifetime_budget_usd,target_count,research_expires_at,status
  ) VALUES(
    p_browser_key_hash,p_ip_hash,v_org,v_seller,v_job,v_name,v_url,v_budget,v_target_count,now()+make_interval(hours=>v_hours),'ACTIVE'
  ) RETURNING id INTO v_run;
  RETURN jsonb_build_object('runId',v_run,'existing',false);
END;
$fn$;

REVOKE ALL ON FUNCTION public.marketroute_create_anonymous_discovery_v1(text,text,text,text,text,text,text,numeric,integer,integer)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_create_anonymous_discovery_v1(text,text,text,text,text,text,text,numeric,integer,integer)
TO service_role;

-- Discovery-free workspaces may see at most two server-redacted locked teasers before payment.
CREATE OR REPLACE FUNCTION public.marketroute_workspace_commercial_access_v1(p_organisation_id uuid,p_at timestamptz DEFAULT now())
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
DECLARE
  v_ent public.organisation_commercial_entitlements%ROWTYPE;
  v_plan public.marketroute_plan_catalog%ROWTYPE;
  v_run public.anonymous_discovery_runs%ROWTYPE;
  v_campaign uuid;
  v_access jsonb;
  v_locked jsonb:='[]'::jsonb;
  v_locked_count integer:=0;
  v_unlocked_count integer:=0;
  v_used integer:=0;
  v_capacity jsonb;
BEGIN
  PERFORM public.marketroute_require_service_role();

  SELECT * INTO v_ent FROM public.organisation_commercial_entitlements e
  WHERE e.organisation_id=p_organisation_id AND e.status='ACTIVE'
    AND (e.current_period_start IS NULL OR e.current_period_start<=p_at)
    AND (e.current_period_end IS NULL OR e.current_period_end>p_at)
  LIMIT 1;

  IF FOUND AND v_ent.plan_code IN('STARTER','GROWTH','SCALE','LEGACY_FULL') THEN
    SELECT * INTO v_plan FROM public.marketroute_plan_catalog WHERE plan_code=v_ent.plan_code;
    SELECT c.id INTO v_campaign FROM public.campaigns c WHERE c.organisation_id=p_organisation_id AND c.workflow_state<>'ARCHIVED' ORDER BY c.created_at DESC LIMIT 1;
    v_capacity:=public.marketroute_research_capacity_snapshot_v1(p_organisation_id,p_at);
    RETURN jsonb_build_object(
      'mode',CASE WHEN v_ent.plan_code='LEGACY_FULL' THEN 'FULL' ELSE 'PAID' END,
      'planCode',v_ent.plan_code,'planName',v_plan.display_name,'campaignId',v_campaign,
      'freeLimit',8,'unlockedCount',NULL,'lockedCount',0,'opportunityIds','[]'::jsonb,'companyIds','[]'::jsonb,'lockedOpportunities','[]'::jsonb,
      'researchCapacity',v_capacity
    );
  END IF;

  SELECT * INTO v_run FROM public.anonymous_discovery_runs a WHERE a.organisation_id=p_organisation_id AND a.status='CLAIMED' LIMIT 1 FOR UPDATE;
  IF FOUND THEN
    v_access:=public.marketroute_discovery_free_access_v1(p_organisation_id);
    v_campaign:=NULLIF(v_access->>'campaignId','')::uuid;
    SELECT count(*)::int INTO v_unlocked_count FROM public.anonymous_discovery_opportunity_unlocks u WHERE u.run_id=v_run.id;
    IF v_campaign IS NOT NULL THEN
      WITH locked AS (
        SELECT o.id AS opportunity_id,o.company_id,c.canonical_name,c.canonical_domain,o.created_at
        FROM public.opportunities o
        JOIN public.companies c ON c.id=o.company_id
        WHERE o.organisation_id=p_organisation_id AND o.campaign_id=v_campaign
          AND o.workflow_state IN('REVIEWABLE','APPROVED','ENGAGED')
          AND public.marketroute_authority_ready_v1(o.organisation_id,o.campaign_id,o.company_id,p_at)
          AND NOT EXISTS(SELECT 1 FROM public.anonymous_discovery_opportunity_unlocks u WHERE u.run_id=v_run.id AND u.opportunity_id=o.id)
      ), locked_limited AS (
        SELECT * FROM locked ORDER BY created_at,opportunity_id LIMIT 2
      )
      SELECT count(*)::int,
        COALESCE(jsonb_agg(jsonb_build_object(
          'opportunityId',l.opportunity_id,'companyId',l.company_id,'companyName',l.canonical_name,
          'canonicalDomain',l.canonical_domain,'discoveredAt',l.created_at,'state','READY_LOCKED'
        ) ORDER BY l.created_at,l.opportunity_id),'[]'::jsonb)
      INTO v_locked_count,v_locked
      FROM locked_limited l;
    END IF;
    RETURN jsonb_build_object(
      'mode','DISCOVERY_FREE','planCode','DISCOVERY','planName','MarketRoute Discovery','campaignId',v_campaign,
      'freeLimit',8,'unlockedCount',v_unlocked_count,'lockedCount',v_locked_count,
      'opportunityIds',COALESCE(v_access->'opportunityIds','[]'::jsonb),'companyIds',COALESCE(v_access->'companyIds','[]'::jsonb),
      'lockedOpportunities',v_locked,
      'researchCapacity',jsonb_build_object('limitUnits',0,'usedUnits',0,'remainingUnits',0,'periodStart',NULL,'periodEnd',NULL)
    );
  END IF;

  RETURN jsonb_build_object(
    'mode','UNENTITLED','planCode',NULL,'planName',NULL,'campaignId',NULL,'freeLimit',0,'unlockedCount',0,'lockedCount',0,
    'opportunityIds','[]'::jsonb,'companyIds','[]'::jsonb,'lockedOpportunities','[]'::jsonb,
    'researchCapacity',jsonb_build_object('limitUnits',0,'usedUnits',0,'remainingUnits',0,'periodStart',NULL,'periodEnd',NULL)
  );
END;
$fn$;
REVOKE ALL ON FUNCTION public.marketroute_workspace_commercial_access_v1(uuid,timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_workspace_commercial_access_v1(uuid,timestamptz) TO service_role;

INSERT INTO public.marketroute_schema_releases(
  release_key,
  build_number,
  constitution_version,
  metadata_json
)
VALUES(
  'MARKETROUTE_V2_ANONYMOUS_DISCOVERY_LAUNCH_COST_FREEZE_2026_08_18',
  26,
  'MRV2-CONSTITUTION-1.0.0',
  jsonb_build_object(
    'migration','0048_anonymous_discovery_launch_cost_freeze.sql',
    'new_authority_writer',false,
    'authority_semantics_unchanged',true,
    'anonymous_free_opportunity_limit',8,
    'anonymous_target_company_ceiling',10,
    'anonymous_max_post_free_companies',2,
    'anonymous_locked_teaser_ceiling',2,
    'anonymous_lifetime_ai_budget_usd',1.00,
    'anonymous_research_window_hours',12,
    'environment_can_raise_launch_ceiling',false,
    'existing_active_runs_tightened',true,
    'growth_reactivated',false,
    'delivery_enabled',false
  )
)
ON CONFLICT(release_key) DO NOTHING;

NOTIFY pgrst,'reload schema';
COMMIT;
