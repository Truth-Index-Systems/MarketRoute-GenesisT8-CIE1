BEGIN;

-- MarketRoute V2 Product Build 24: Locked Opportunities + Commercial Boundary.
-- Product entitlement and safe teaser projection only. No Truth, R4, R5, R6 or
-- opportunity authority is created or modified here.

CREATE TABLE IF NOT EXISTS public.marketroute_plan_catalog (
  plan_code text PRIMARY KEY CHECK (plan_code IN ('DISCOVERY','STARTER','GROWTH','SCALE','LEGACY_FULL')),
  display_name text NOT NULL,
  monthly_price_gbp numeric(10,2) NOT NULL CHECK (monthly_price_gbp >= 0),
  research_capacity_units integer CHECK (research_capacity_units IS NULL OR research_capacity_units >= 0),
  active_market_limit integer NOT NULL DEFAULT 1 CHECK (active_market_limit >= 1),
  team_seat_limit integer CHECK (team_seat_limit IS NULL OR team_seat_limit >= 1),
  public_visible boolean NOT NULL DEFAULT true,
  sort_order integer NOT NULL DEFAULT 0,
  metadata_json jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata_json)='object'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.marketroute_plan_catalog(plan_code,display_name,monthly_price_gbp,research_capacity_units,active_market_limit,team_seat_limit,public_visible,sort_order,metadata_json)
VALUES
 ('DISCOVERY','MarketRoute Discovery',0,0,1,1,false,0,jsonb_build_object('billingCadence','ONE_TIME','freeOpportunityLimit',8,'capacityLabel','Discovery run only')),
 ('STARTER','Starter',99,100,1,1,true,10,jsonb_build_object('capacityLabel','Core research capacity','depthLabel','Standard research depth','monitoringLabel','Essential monitoring')),
 ('GROWTH','Growth',249,400,1,5,true,20,jsonb_build_object('recommended',true,'capacityLabel','Expanded research capacity','depthLabel','Deeper company research','monitoringLabel','Continuous monitoring')),
 ('SCALE','Scale',599,1200,1,15,true,30,jsonb_build_object('capacityLabel','Highest research capacity','depthLabel','Priority research depth','monitoringLabel','Priority monitoring')),
 ('LEGACY_FULL','Legacy full access',0,NULL,1,NULL,false,100,jsonb_build_object('migrationOnly',true,'capacityLabel','Unmetered legacy access'))
ON CONFLICT(plan_code) DO UPDATE SET
  display_name=EXCLUDED.display_name,monthly_price_gbp=EXCLUDED.monthly_price_gbp,research_capacity_units=EXCLUDED.research_capacity_units,
  active_market_limit=EXCLUDED.active_market_limit,team_seat_limit=EXCLUDED.team_seat_limit,public_visible=EXCLUDED.public_visible,
  sort_order=EXCLUDED.sort_order,metadata_json=EXCLUDED.metadata_json,updated_at=now();

CREATE TABLE IF NOT EXISTS public.organisation_commercial_entitlements (
  organisation_id uuid PRIMARY KEY REFERENCES public.organisations(id) ON DELETE RESTRICT,
  plan_code text NOT NULL REFERENCES public.marketroute_plan_catalog(plan_code) ON DELETE RESTRICT,
  status text NOT NULL CHECK (status IN ('ACTIVE','PAST_DUE','CANCELLED','EXPIRED')),
  source text NOT NULL CHECK (source IN ('SYSTEM','MANUAL','BILLING')),
  external_customer_id text,
  external_subscription_id text,
  current_period_start timestamptz,
  current_period_end timestamptz,
  activated_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  metadata_json jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata_json)='object'),
  CHECK (current_period_end IS NULL OR current_period_start IS NULL OR current_period_end > current_period_start)
);
CREATE UNIQUE INDEX IF NOT EXISTS organisation_commercial_external_subscription_unique
  ON public.organisation_commercial_entitlements(external_subscription_id) WHERE external_subscription_id IS NOT NULL;

ALTER TABLE public.marketroute_plan_catalog ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.organisation_commercial_entitlements ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.marketroute_plan_catalog FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON public.organisation_commercial_entitlements FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON public.marketroute_plan_catalog TO service_role;
GRANT SELECT,INSERT,UPDATE ON public.organisation_commercial_entitlements TO service_role;

-- Existing customer workspaces pre-date self-serve commercial entitlements. Preserve
-- their current access while explicitly excluding claimed free discoveries.
INSERT INTO public.organisation_commercial_entitlements(organisation_id,plan_code,status,source,metadata_json)
SELECT o.id,'LEGACY_FULL','ACTIVE','SYSTEM',jsonb_build_object('grandfatheredBy','PRODUCT_BUILD24')
FROM public.organisations o
WHERE o.workspace_kind='CUSTOMER'
  AND NOT EXISTS(SELECT 1 FROM public.anonymous_discovery_runs a WHERE a.organisation_id=o.id AND a.status='CLAIMED')
ON CONFLICT(organisation_id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.marketroute_paid_entitlement_active_v1(p_organisation_id uuid,p_at timestamptz DEFAULT now())
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
 SELECT EXISTS(
   SELECT 1 FROM public.organisation_commercial_entitlements e
   WHERE e.organisation_id=p_organisation_id
     AND e.status='ACTIVE'
     AND e.plan_code IN('STARTER','GROWTH','SCALE','LEGACY_FULL')
     AND (e.current_period_start IS NULL OR e.current_period_start<=p_at)
     AND (e.current_period_end IS NULL OR e.current_period_end>p_at)
 );
$$;

REVOKE ALL ON FUNCTION public.marketroute_paid_entitlement_active_v1(uuid,timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_paid_entitlement_active_v1(uuid,timestamptz) TO service_role;

CREATE OR REPLACE FUNCTION public.marketroute_research_capacity_snapshot_v1(p_organisation_id uuid,p_at timestamptz DEFAULT now())
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_ent public.organisation_commercial_entitlements%ROWTYPE;v_plan public.marketroute_plan_catalog%ROWTYPE;v_used integer:=0;v_reserved integer:=0;
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT * INTO v_ent FROM public.organisation_commercial_entitlements e
  WHERE e.organisation_id=p_organisation_id AND e.status='ACTIVE'
    AND (e.current_period_start IS NULL OR e.current_period_start<=p_at)
    AND (e.current_period_end IS NULL OR e.current_period_end>p_at) LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('planCode',NULL,'limitUnits',0,'usedUnits',0,'reservedUnits',0,'remainingUnits',0,'available',false,'periodStart',NULL,'periodEnd',NULL); END IF;
  SELECT * INTO v_plan FROM public.marketroute_plan_catalog WHERE plan_code=v_ent.plan_code;
  IF v_plan.research_capacity_units IS NULL THEN RETURN jsonb_build_object('planCode',v_ent.plan_code,'limitUnits',NULL,'usedUnits',0,'reservedUnits',0,'remainingUnits',NULL,'available',true,'periodStart',v_ent.current_period_start,'periodEnd',v_ent.current_period_end); END IF;
  SELECT count(DISTINCT b.work_unit_id)::int INTO v_used FROM public.research_budget_events b
  WHERE b.organisation_id=p_organisation_id AND b.event_type='COMMIT'
    AND (v_ent.current_period_start IS NULL OR b.occurred_at>=v_ent.current_period_start)
    AND (v_ent.current_period_end IS NULL OR b.occurred_at<v_ent.current_period_end);
  SELECT count(DISTINCT r.work_unit_id)::int INTO v_reserved FROM public.research_budget_events r
  WHERE r.organisation_id=p_organisation_id AND r.event_type='RESERVE'
    AND (v_ent.current_period_start IS NULL OR r.occurred_at>=v_ent.current_period_start)
    AND (v_ent.current_period_end IS NULL OR r.occurred_at<v_ent.current_period_end)
    AND NOT EXISTS(SELECT 1 FROM public.research_budget_events x WHERE x.work_unit_id=r.work_unit_id AND x.attempt_number=r.attempt_number AND x.event_type IN('COMMIT','RELEASE'));
  RETURN jsonb_build_object('planCode',v_ent.plan_code,'limitUnits',v_plan.research_capacity_units,'usedUnits',v_used,'reservedUnits',v_reserved,'remainingUnits',greatest(0,v_plan.research_capacity_units-v_used-v_reserved),'available',(v_used+v_reserved)<v_plan.research_capacity_units,'periodStart',v_ent.current_period_start,'periodEnd',v_ent.current_period_end);
END;$fn$;
REVOKE ALL ON FUNCTION public.marketroute_research_capacity_snapshot_v1(uuid,timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_research_capacity_snapshot_v1(uuid,timestamptz) TO service_role;

CREATE OR REPLACE FUNCTION public.marketroute_public_plan_catalog_v1()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_result jsonb;
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'planCode',p.plan_code,'displayName',p.display_name,'monthlyPriceGbp',p.monthly_price_gbp,
    'researchCapacityUnits',p.research_capacity_units,'activeMarketLimit',p.active_market_limit,
    'teamSeatLimit',p.team_seat_limit,'metadata',p.metadata_json
  ) ORDER BY p.sort_order,p.plan_code),'[]'::jsonb)
  INTO v_result
  FROM public.marketroute_plan_catalog p WHERE p.public_visible=true;
  RETURN v_result;
END;
$fn$;
REVOKE ALL ON FUNCTION public.marketroute_public_plan_catalog_v1() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_public_plan_catalog_v1() TO service_role;

-- One server-authoritative commercial projection. Locked opportunities expose only a
-- safe teaser: organisation identity plus the fact that current authority is ready.
-- No contact, route, evidence, narration or private URL payload is returned.
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
      )
      SELECT count(*)::int,
        COALESCE(jsonb_agg(jsonb_build_object(
          'opportunityId',l.opportunity_id,'companyId',l.company_id,'companyName',l.canonical_name,
          'canonicalDomain',l.canonical_domain,'discoveredAt',l.created_at,'state','READY_LOCKED'
        ) ORDER BY l.created_at,l.opportunity_id) FILTER (WHERE rn<=32),'[]'::jsonb)
      INTO v_locked_count,v_locked
      FROM (SELECT locked.*,row_number() OVER(ORDER BY created_at,opportunity_id) rn FROM locked) l;
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

-- Paid claimed workspaces are no longer bound by the expired anonymous research window;
-- discovery-free claimed workspaces remain strictly inside the original free run.
CREATE OR REPLACE FUNCTION public.marketroute_research_planning_targets_v1(p_limit integer DEFAULT 100)
RETURNS TABLE(organisation_id uuid,campaign_id uuid,company_id uuid)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
 SELECT DISTINCT s.organisation_id,s.campaign_id,s.company_id
 FROM public.organisation_company_scopes s
 JOIN public.campaigns c ON c.id=s.campaign_id AND c.organisation_id=s.organisation_id
 JOIN public.research_budget_policies p ON p.organisation_id=s.organisation_id AND p.campaign_id=s.campaign_id AND p.enabled=true
 LEFT JOIN public.anonymous_discovery_runs a ON a.organisation_id=s.organisation_id
 WHERE s.scope_kind='CAMPAIGN' AND s.campaign_id IS NOT NULL AND c.workflow_state='ACTIVE'
   AND (a.id IS NULL OR (public.marketroute_paid_entitlement_active_v1(s.organisation_id,now()) AND COALESCE((public.marketroute_research_capacity_snapshot_v1(s.organisation_id,now())->>'available')::boolean,false)) OR (a.status IN('ACTIVE','CLAIMED') AND a.research_expires_at>now()))
 ORDER BY s.organisation_id,s.campaign_id,s.company_id
 LIMIT greatest(0,least(COALESCE(p_limit,100),1000));
$$;

CREATE OR REPLACE FUNCTION public.marketroute_claim_research_work_v1(p_scheduler_run_id uuid,p_at timestamptz DEFAULT now())
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE
  v_work public.research_work_units%ROWTYPE; v_job public.background_jobs%ROWTYPE; v_policy jsonb; v_budget jsonb; v_attempt int; v_remaining numeric;
  v_anon_budget numeric;v_anon_expires timestamptz;v_anon_spent numeric:=0;v_anon_reserved numeric:=0;v_anon_remaining numeric;v_paid boolean:=false;v_capacity jsonb;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.scheduler_runs r JOIN public.scheduler_leases l ON l.owner_run_id=r.id AND l.lease_key='GENESIS_RESEARCH_V1' WHERE r.id=p_scheduler_run_id AND r.status='RUNNING' AND r.runner_key='GENESIS_RESEARCH_V1' AND l.expires_at>p_at) THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_SCHEDULER_RUN_REQUIRED'; END IF;
 SELECT w.* INTO v_work FROM public.research_work_units w JOIN public.background_jobs j ON j.id=w.background_job_id
 WHERE j.job_type='GENESIS_RESEARCH_V1' AND j.status IN('PENDING','DEFERRED') AND j.available_at<=p_at
   AND NOT EXISTS(SELECT 1 FROM public.anonymous_discovery_runs a WHERE a.organisation_id=w.organisation_id AND NOT public.marketroute_paid_entitlement_active_v1(w.organisation_id,p_at) AND (a.status NOT IN('ACTIVE','CLAIMED') OR a.research_expires_at<=p_at))
 ORDER BY j.priority,j.created_at,j.id FOR UPDATE OF j SKIP LOCKED LIMIT 1;
 IF NOT FOUND THEN RETURN NULL; END IF;
 SELECT * INTO v_job FROM public.background_jobs WHERE id=v_work.background_job_id FOR UPDATE;
 v_policy:=public.marketroute_research_policy_v1(v_work.organisation_id,v_work.campaign_id); v_budget:=public.marketroute_research_budget_snapshot_v1(v_work.organisation_id,v_work.campaign_id,p_at);
 IF COALESCE((v_policy->>'enabled')::boolean,true)=false OR (v_budget->>'activeJobs')::int >= (v_policy->>'maxConcurrentJobs')::int THEN UPDATE public.background_jobs SET status='DEFERRED',available_at=p_at+interval '5 minutes',updated_at=p_at WHERE id=v_job.id; RETURN NULL; END IF;
 v_remaining:=(v_policy->>'dailyBudgetUsd')::numeric-(v_budget->>'spentTodayUsd')::numeric-(v_budget->>'reservedTodayUsd')::numeric;
 v_paid:=public.marketroute_paid_entitlement_active_v1(v_work.organisation_id,p_at);
 IF v_paid THEN
   v_capacity:=public.marketroute_research_capacity_snapshot_v1(v_work.organisation_id,p_at);
   IF COALESCE((v_capacity->>'available')::boolean,false)=false THEN
     UPDATE public.background_jobs SET status='DEFERRED',available_at=COALESCE(NULLIF(v_capacity->>'periodEnd','')::timestamptz,p_at+interval '1 day'),last_error_code='MARKETROUTE_PLAN_RESEARCH_CAPACITY_EXHAUSTED',updated_at=p_at WHERE id=v_job.id; RETURN NULL;
   END IF;
 END IF;
 IF NOT v_paid THEN
   SELECT lifetime_budget_usd,research_expires_at INTO v_anon_budget,v_anon_expires FROM public.anonymous_discovery_runs WHERE organisation_id=v_work.organisation_id AND status IN('ACTIVE','CLAIMED');
 END IF;
 IF v_anon_budget IS NOT NULL THEN
   IF v_anon_expires<=p_at THEN UPDATE public.background_jobs SET status='CANCELLED',last_error_code='MARKETROUTE_ANONYMOUS_RESEARCH_WINDOW_CLOSED',updated_at=p_at WHERE id=v_job.id; RETURN NULL; END IF;
   SELECT COALESCE(sum(amount_usd),0) INTO v_anon_spent FROM public.research_budget_events WHERE organisation_id=v_work.organisation_id AND campaign_id=v_work.campaign_id AND event_type='COMMIT';
   SELECT COALESCE(sum(r.amount_usd),0) INTO v_anon_reserved FROM public.research_budget_events r WHERE r.organisation_id=v_work.organisation_id AND r.campaign_id=v_work.campaign_id AND r.event_type='RESERVE' AND NOT EXISTS(SELECT 1 FROM public.research_budget_events x WHERE x.work_unit_id=r.work_unit_id AND x.attempt_number=r.attempt_number AND x.event_type IN('COMMIT','RELEASE'));
   v_anon_remaining:=greatest(0,v_anon_budget-v_anon_spent-v_anon_reserved); v_remaining:=least(v_remaining,v_anon_remaining);
 END IF;
 IF v_work.cost_ceiling_usd>greatest(0,v_remaining) OR v_work.cost_ceiling_usd>(v_policy->>'maxJobCostUsd')::numeric THEN
   UPDATE public.background_jobs SET status=CASE WHEN v_anon_budget IS NOT NULL AND greatest(0,v_remaining)<=0 THEN 'CANCELLED' ELSE 'DEFERRED' END,available_at=CASE WHEN v_anon_budget IS NOT NULL THEN available_at ELSE (date_trunc('day',p_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC')+interval '1 day' END,last_error_code=CASE WHEN v_anon_budget IS NOT NULL AND greatest(0,v_remaining)<=0 THEN 'MARKETROUTE_ANONYMOUS_RESEARCH_BUDGET_EXHAUSTED' ELSE last_error_code END,updated_at=p_at WHERE id=v_job.id; RETURN NULL;
 END IF;
 v_attempt:=v_job.attempt_count+1;
 IF EXISTS(SELECT 1 FROM public.research_budget_events WHERE work_unit_id=v_work.id AND attempt_number=v_attempt AND event_type='RESERVE') THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_BUDGET_ALREADY_RESERVED'; END IF;
 INSERT INTO public.research_budget_events(organisation_id,campaign_id,work_unit_id,scheduler_run_id,attempt_number,event_type,amount_usd,occurred_at) VALUES(v_work.organisation_id,v_work.campaign_id,v_work.id,p_scheduler_run_id,v_attempt,'RESERVE',v_work.cost_ceiling_usd,p_at);
 UPDATE public.background_jobs SET status='RUNNING',reserved_by_run_id=p_scheduler_run_id,reserved_at=p_at,attempt_count=v_attempt,updated_at=p_at WHERE id=v_job.id;
 INSERT INTO public.background_job_attempts(job_id,scheduler_run_id,attempt_number,status,started_at) VALUES(v_job.id,p_scheduler_run_id,v_attempt,'RUNNING',p_at);
 RETURN jsonb_build_object('workUnitId',v_work.id,'jobId',v_job.id,'planId',v_work.plan_id,'organisationId',v_work.organisation_id,'campaignId',v_work.campaign_id,'companyId',v_work.company_id,'gapKey',v_work.gap_key,'layer',v_work.layer,'tier',v_work.tier,'action',v_work.action,'subjectType',v_work.subject_type,'subjectId',v_work.subject_id,'claimKey',v_work.claim_key,'reasonCode',v_work.reason_code,'queryHints',v_work.query_hints_json,'payload',v_work.payload_json||jsonb_build_object('dedupeKey',v_work.dedupe_key,'researchOrigin',CASE WHEN v_paid THEN 'CUSTOMER_CAMPAIGN' WHEN v_anon_budget IS NULL THEN COALESCE(v_work.payload_json->>'researchOrigin','CUSTOMER_CAMPAIGN') ELSE 'ANONYMOUS_DISCOVERY' END),'costCeilingUsd',v_work.cost_ceiling_usd,'attemptNumber',v_attempt);
END;
$fn$;

-- New directly-created workspaces are no longer allowed to spend research money without
-- a commercial entitlement. Anonymous discovery never uses this RPC; it inserts its own
-- bounded activation job in the anonymous service-role path.
CREATE OR REPLACE FUNCTION public.marketroute_submit_workspace_activation_v2(
  p_organisation_id uuid,p_seller_offering_text text,p_objective_text text,p_target_market_text text,p_hard_constraints_text text,p_no_hard_constraints boolean
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_user uuid:=auth.uid();v_seller uuid;v_job uuid;v_offering text:=nullif(btrim(COALESCE(p_seller_offering_text,'')),'');v_no_hard boolean:=COALESCE(p_no_hard_constraints,false);v_hard text:=nullif(btrim(COALESCE(p_hard_constraints_text,'')),'');
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_AUTH_REQUIRED';END IF;
  IF NOT public.marketroute_is_org_admin(p_organisation_id) THEN RAISE EXCEPTION 'MARKETROUTE_WORKSPACE_ADMIN_REQUIRED';END IF;
  IF NOT public.marketroute_paid_entitlement_active_v1(p_organisation_id,now()) THEN RAISE EXCEPTION 'MARKETROUTE_PLAN_REQUIRED'; END IF;
  IF v_offering IS NULL OR length(v_offering)<8 THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_OFFERING_REQUIRED';END IF;
  IF length(btrim(COALESCE(p_objective_text,'')))<8 THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_OBJECTIVE_REQUIRED';END IF;
  IF length(btrim(COALESCE(p_target_market_text,'')))<3 THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_TARGET_REQUIRED';END IF;
  IF v_no_hard AND v_hard IS NOT NULL THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_CONSTRAINT_CONFLICT';END IF;
  IF NOT v_no_hard AND v_hard IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_CONSTRAINT_DECLARATION_REQUIRED';END IF;
  SELECT id INTO v_seller FROM public.seller_businesses WHERE organisation_id=p_organisation_id AND lifecycle_state='ACTIVE' ORDER BY created_at ASC LIMIT 1;
  IF v_seller IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_SELLER_NOT_FOUND';END IF;
  INSERT INTO public.workspace_activation_jobs(organisation_id,seller_business_id,seller_offering_text,objective_text,target_market_text,hard_constraints_text,no_hard_constraints,status,attempt_count,available_at,worker_id,lease_expires_at,last_error_code,result_json)
  VALUES(p_organisation_id,v_seller,v_offering,btrim(p_objective_text),btrim(p_target_market_text),CASE WHEN v_no_hard THEN NULL ELSE v_hard END,v_no_hard,'PENDING',0,now(),NULL,NULL,NULL,'{}'::jsonb)
  ON CONFLICT(organisation_id) DO UPDATE SET seller_offering_text=EXCLUDED.seller_offering_text,objective_text=EXCLUDED.objective_text,target_market_text=EXCLUDED.target_market_text,hard_constraints_text=EXCLUDED.hard_constraints_text,no_hard_constraints=EXCLUDED.no_hard_constraints,status='PENDING',attempt_count=0,available_at=now(),worker_id=NULL,lease_expires_at=NULL,last_error_code=NULL,result_json='{}'::jsonb
  RETURNING id INTO v_job;
  RETURN v_job;
END;$fn$;

CREATE OR REPLACE FUNCTION public.marketroute_submit_replacement_campaign_v1(
  p_organisation_id uuid,p_campaign_name text,p_seller_offering_text text,p_objective_text text,p_target_market_text text,p_hard_constraints_text text,p_no_hard_constraints boolean
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_user uuid:=auth.uid();v_seller uuid;v_job uuid;v_name text:=nullif(btrim(COALESCE(p_campaign_name,'')),'');v_offering text:=nullif(btrim(COALESCE(p_seller_offering_text,'')),'');v_no_hard boolean:=COALESCE(p_no_hard_constraints,false);v_hard text:=nullif(btrim(COALESCE(p_hard_constraints_text,'')),'');v_existing_status text;v_existing_lease timestamptz;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_AUTH_REQUIRED'; END IF;
  IF NOT public.marketroute_is_org_admin(p_organisation_id) THEN RAISE EXCEPTION 'MARKETROUTE_CAMPAIGN_ADMIN_REQUIRED'; END IF;
  IF NOT public.marketroute_paid_entitlement_active_v1(p_organisation_id,now()) THEN RAISE EXCEPTION 'MARKETROUTE_DISCOVERY_UPGRADE_REQUIRED'; END IF;
  IF v_name IS NULL OR length(v_name) NOT BETWEEN 3 AND 120 THEN RAISE EXCEPTION 'MARKETROUTE_CAMPAIGN_NAME_REQUIRED'; END IF;
  IF v_offering IS NULL OR length(v_offering)<8 THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_OFFERING_REQUIRED'; END IF;
  IF length(btrim(COALESCE(p_objective_text,'')))<8 THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_OBJECTIVE_REQUIRED'; END IF;
  IF length(btrim(COALESCE(p_target_market_text,'')))<3 THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_TARGET_REQUIRED'; END IF;
  IF v_no_hard AND v_hard IS NOT NULL THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_CONSTRAINT_CONFLICT'; END IF;
  IF NOT v_no_hard AND v_hard IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_CONSTRAINT_DECLARATION_REQUIRED'; END IF;
  PERFORM 1 FROM public.organisations WHERE id=p_organisation_id AND status='ACTIVE' FOR UPDATE; IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_WORKSPACE_NOT_ACTIVE'; END IF;
  IF EXISTS(SELECT 1 FROM public.campaigns WHERE organisation_id=p_organisation_id AND workflow_state<>'ARCHIVED') THEN RAISE EXCEPTION 'MARKETROUTE_LIVE_CAMPAIGN_ALREADY_EXISTS'; END IF;
  SELECT status,lease_expires_at INTO v_existing_status,v_existing_lease FROM public.workspace_activation_jobs WHERE organisation_id=p_organisation_id;
  IF v_existing_status='RUNNING' AND COALESCE(v_existing_lease,now()+interval '1 minute')>=now() THEN RAISE EXCEPTION 'MARKETROUTE_CAMPAIGN_CREATION_ALREADY_PROCESSING'; END IF;
  SELECT id INTO v_seller FROM public.seller_businesses WHERE organisation_id=p_organisation_id AND lifecycle_state='ACTIVE' ORDER BY created_at LIMIT 1;
  IF v_seller IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_SELLER_NOT_FOUND'; END IF;
  INSERT INTO public.workspace_activation_jobs(organisation_id,seller_business_id,campaign_name,seller_offering_text,objective_text,target_market_text,hard_constraints_text,no_hard_constraints,status,attempt_count,available_at,worker_id,lease_expires_at,last_error_code,result_json)
  VALUES(p_organisation_id,v_seller,v_name,v_offering,btrim(p_objective_text),btrim(p_target_market_text),CASE WHEN v_no_hard THEN NULL ELSE v_hard END,v_no_hard,'PENDING',0,now(),NULL,NULL,NULL,'{}'::jsonb)
  ON CONFLICT(organisation_id) DO UPDATE SET seller_business_id=EXCLUDED.seller_business_id,campaign_name=EXCLUDED.campaign_name,seller_offering_text=EXCLUDED.seller_offering_text,objective_text=EXCLUDED.objective_text,target_market_text=EXCLUDED.target_market_text,hard_constraints_text=EXCLUDED.hard_constraints_text,no_hard_constraints=EXCLUDED.no_hard_constraints,status='PENDING',attempt_count=0,available_at=now(),worker_id=NULL,lease_expires_at=NULL,last_error_code=NULL,result_json='{}'::jsonb
  RETURNING id INTO v_job;
  RETURN v_job;
END;
$fn$;

REVOKE ALL ON FUNCTION public.marketroute_submit_workspace_activation_v2(uuid,text,text,text,text,boolean) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_submit_workspace_activation_v2(uuid,text,text,text,text,boolean) TO authenticated;
REVOKE ALL ON FUNCTION public.marketroute_submit_replacement_campaign_v1(uuid,text,text,text,text,text,boolean) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_submit_replacement_campaign_v1(uuid,text,text,text,text,text,boolean) TO authenticated;

INSERT INTO public.marketroute_schema_releases(release_key,build_number,constitution_version,metadata_json)
VALUES('MARKETROUTE_V2_PRODUCT_BUILD24_LOCKED_OPPORTUNITIES_COMMERCIAL_BOUNDARY',24,'MRV2-CONSTITUTION-1.0.0',jsonb_build_object(
  'migration','0044_product_locked_opportunities_commercial_boundary.sql','new_authority_writer',false,'authority_semantics_unchanged',true,
  'locked_payload_server_redacted',true,'plan_catalog_server_owned',true,'billing_processor_authority',false,
  'growth_reactivated',false,'anonymous_free_opportunity_limit',8,'one_active_market_at_launch',true,'legacy_workspaces_grandfathered',true
)) ON CONFLICT(release_key) DO NOTHING;

NOTIFY pgrst,'reload schema';
COMMIT;
