BEGIN;

-- MarketRoute V2 Product Build 23: Free Eight + Anonymous Run Claiming.
-- Product-entitlement layer only. No Truth, R4, R5, R6 or opportunity authority is created here.

CREATE TABLE IF NOT EXISTS public.anonymous_discovery_opportunity_unlocks (
  run_id uuid NOT NULL REFERENCES public.anonymous_discovery_runs(id) ON DELETE RESTRICT,
  opportunity_id uuid NOT NULL REFERENCES public.opportunities(id) ON DELETE RESTRICT,
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  ordinal integer NOT NULL CHECK (ordinal BETWEEN 1 AND 8),
  unlocked_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (run_id, opportunity_id),
  UNIQUE (run_id, ordinal)
);
CREATE INDEX IF NOT EXISTS anonymous_discovery_unlock_company_idx
  ON public.anonymous_discovery_opportunity_unlocks(run_id,company_id);

ALTER TABLE public.anonymous_discovery_opportunity_unlocks ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.anonymous_discovery_opportunity_unlocks FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT,INSERT ON public.anonymous_discovery_opportunity_unlocks TO service_role;

-- Allocate free opportunity slots only after the existing authority stack says the
-- opportunity is currently ready. Allocation order is stable arrival order; Build 23
-- deliberately does not invent a scalar ranking that CIE does not own.
CREATE OR REPLACE FUNCTION public.marketroute_anonymous_discovery_refresh_unlocks_v1(p_browser_key_hash text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
DECLARE
  v_run public.anonymous_discovery_runs%ROWTYPE;
  v_job public.workspace_activation_jobs%ROWTYPE;
  v_campaign uuid;
  v_count integer:=0;
  v_candidate record;
  v_result jsonb:='[]'::jsonb;
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT * INTO v_run FROM public.anonymous_discovery_runs WHERE browser_key_hash=p_browser_key_hash FOR UPDATE;
  IF NOT FOUND THEN RETURN '[]'::jsonb; END IF;
  IF v_run.status='BLOCKED' THEN RETURN '[]'::jsonb; END IF;

  SELECT * INTO v_job FROM public.workspace_activation_jobs WHERE id=v_run.activation_job_id;
  IF nullif(v_job.result_json->>'campaignId','') IS NOT NULL THEN
    v_campaign:=(v_job.result_json->>'campaignId')::uuid;
  END IF;
  IF v_campaign IS NULL THEN
    SELECT id INTO v_campaign FROM public.campaigns
    WHERE organisation_id=v_run.organisation_id AND workflow_state<>'ARCHIVED'
    ORDER BY created_at DESC LIMIT 1;
  END IF;
  IF v_campaign IS NULL THEN RETURN '[]'::jsonb; END IF;

  SELECT count(*)::int INTO v_count
  FROM public.anonymous_discovery_opportunity_unlocks
  WHERE run_id=v_run.id;

  IF v_count<8 THEN
    FOR v_candidate IN
      SELECT o.id AS opportunity_id,o.company_id
      FROM public.opportunities o
      WHERE o.organisation_id=v_run.organisation_id
        AND o.campaign_id=v_campaign
        AND o.workflow_state IN('REVIEWABLE','APPROVED','ENGAGED')
        AND public.marketroute_authority_ready_v1(o.organisation_id,o.campaign_id,o.company_id,now())
        AND NOT EXISTS(
          SELECT 1 FROM public.anonymous_discovery_opportunity_unlocks u
          WHERE u.run_id=v_run.id AND u.opportunity_id=o.id
        )
      ORDER BY o.created_at,o.id
      LIMIT greatest(0,8-v_count)
    LOOP
      v_count:=v_count+1;
      INSERT INTO public.anonymous_discovery_opportunity_unlocks(run_id,opportunity_id,company_id,ordinal)
      VALUES(v_run.id,v_candidate.opportunity_id,v_candidate.company_id,v_count)
      ON CONFLICT DO NOTHING;
    END LOOP;
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'ordinal',u.ordinal,
    'opportunityId',u.opportunity_id,
    'companyId',u.company_id,
    'unlockedAt',u.unlocked_at,
    'company',public.marketroute_application_company_read_v1(v_run.organisation_id,v_campaign,u.company_id,now()),
    'routes',public.marketroute_application_route_display_read_v1(v_run.organisation_id,v_campaign,u.company_id,now())
  ) ORDER BY u.ordinal),'[]'::jsonb)
  INTO v_result
  FROM public.anonymous_discovery_opportunity_unlocks u
  WHERE u.run_id=v_run.id;

  RETURN v_result;
END;
$fn$;

-- Server-side access projection used after a discovery is claimed. Normal customer
-- workspaces remain FULL; claimed discovery workspaces expose only their permanent eight
-- until the commercial entitlement layer lands in Product Build 24.
CREATE OR REPLACE FUNCTION public.marketroute_discovery_free_access_v1(p_organisation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
DECLARE
  v_run public.anonymous_discovery_runs%ROWTYPE;
  v_campaign uuid;
  v_count integer:=0;
  v_candidate record;
  v_opps jsonb:='[]'::jsonb;
  v_companies jsonb:='[]'::jsonb;
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT * INTO v_run FROM public.anonymous_discovery_runs
  WHERE organisation_id=p_organisation_id AND status='CLAIMED' LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('mode','FULL','freeLimit',8,'opportunityIds','[]'::jsonb,'companyIds','[]'::jsonb,'campaignId',NULL); END IF;

  SELECT c.id INTO v_campaign FROM public.campaigns c
  WHERE c.organisation_id=p_organisation_id AND c.workflow_state<>'ARCHIVED'
  ORDER BY c.created_at DESC LIMIT 1;

  -- A claimed run can still be finishing the already-authorised discovery work.
  -- Fill any remaining free slots here as opportunities become authority-ready so the
  -- customer never has to revisit the anonymous page to receive all eight.
  IF v_campaign IS NOT NULL THEN
    SELECT count(*)::int INTO v_count
    FROM public.anonymous_discovery_opportunity_unlocks
    WHERE run_id=v_run.id;

    IF v_count<8 THEN
      FOR v_candidate IN
        SELECT o.id AS opportunity_id,o.company_id
        FROM public.opportunities o
        WHERE o.organisation_id=v_run.organisation_id
          AND o.campaign_id=v_campaign
          AND o.workflow_state IN('REVIEWABLE','APPROVED','ENGAGED')
          AND public.marketroute_authority_ready_v1(o.organisation_id,o.campaign_id,o.company_id,now())
          AND NOT EXISTS(
            SELECT 1 FROM public.anonymous_discovery_opportunity_unlocks u
            WHERE u.run_id=v_run.id AND u.opportunity_id=o.id
          )
        ORDER BY o.created_at,o.id
        LIMIT greatest(0,8-v_count)
      LOOP
        v_count:=v_count+1;
        INSERT INTO public.anonymous_discovery_opportunity_unlocks(run_id,opportunity_id,company_id,ordinal)
        VALUES(v_run.id,v_candidate.opportunity_id,v_candidate.company_id,v_count)
        ON CONFLICT DO NOTHING;
      END LOOP;
    END IF;
  END IF;

  SELECT COALESCE(jsonb_agg(u.opportunity_id::text ORDER BY u.ordinal),'[]'::jsonb),COALESCE(jsonb_agg(u.company_id::text ORDER BY u.ordinal),'[]'::jsonb)
  INTO v_opps,v_companies
  FROM public.anonymous_discovery_opportunity_unlocks u WHERE u.run_id=v_run.id;
  RETURN jsonb_build_object('mode','DISCOVERY_FREE','runId',v_run.id,'campaignId',v_campaign,'freeLimit',8,'opportunityIds',v_opps,'companyIds',v_companies);
END;
$fn$;

-- Claim the existing anonymous organisation transactionally. No research is rerun and
-- no new workspace is created. Email-confirmation flows can perform this same claim on
-- the user's first authenticated sign-in.
CREATE OR REPLACE FUNCTION public.marketroute_claim_anonymous_discovery_v1(p_browser_key_hash text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
DECLARE v_user uuid:=auth.uid();v_run public.anonymous_discovery_runs%ROWTYPE;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_AUTH_REQUIRED'; END IF;
  IF COALESCE(p_browser_key_hash,'') !~ '^[a-f0-9]{64}$' THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_HASH_INVALID'; END IF;
  SELECT * INTO v_run FROM public.anonymous_discovery_runs WHERE browser_key_hash=p_browser_key_hash FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_RUN_NOT_FOUND'; END IF;
  IF v_run.status='BLOCKED' THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_RUN_BLOCKED'; END IF;
  IF v_run.status='CLAIMED' THEN
    IF v_run.claimed_by_user_id IS DISTINCT FROM v_user THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_RUN_ALREADY_CLAIMED'; END IF;
    RETURN jsonb_build_object('organisationId',v_run.organisation_id,'runId',v_run.id,'alreadyClaimed',true);
  END IF;

  -- Membership first is safe while the workspace is still anonymous. Creator ownership
  -- is then promoted atomically before child creator columns are normalised.
  INSERT INTO public.organisation_memberships(organisation_id,user_id,role,status)
  VALUES(v_run.organisation_id,v_user,'OWNER','ACTIVE')
  ON CONFLICT(organisation_id,user_id) DO UPDATE SET role='OWNER',status='ACTIVE',updated_at=now();

  UPDATE public.organisations SET created_by=v_user,workspace_kind='CUSTOMER',updated_at=now()
  WHERE id=v_run.organisation_id;
  UPDATE public.seller_businesses SET created_by=v_user,updated_at=now()
  WHERE organisation_id=v_run.organisation_id AND created_by IS NULL;
  UPDATE public.campaigns SET created_by=v_user,updated_at=now()
  WHERE organisation_id=v_run.organisation_id AND created_by IS NULL;

  UPDATE public.anonymous_discovery_runs
  SET status='CLAIMED',claimed_by_user_id=v_user,claimed_at=now(),updated_at=now()
  WHERE id=v_run.id;

  RETURN jsonb_build_object('organisationId',v_run.organisation_id,'runId',v_run.id,'alreadyClaimed',false);
END;
$fn$;

-- Claimed discovery work may finish the already-authorised free run inside the original
-- lifetime budget/window. Claiming an account must not kill work that was already paid for.
CREATE OR REPLACE FUNCTION public.marketroute_research_planning_targets_v1(p_limit integer DEFAULT 100)
RETURNS TABLE(organisation_id uuid,campaign_id uuid,company_id uuid)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
 SELECT DISTINCT s.organisation_id,s.campaign_id,s.company_id
 FROM public.organisation_company_scopes s
 JOIN public.campaigns c ON c.id=s.campaign_id AND c.organisation_id=s.organisation_id
 JOIN public.research_budget_policies p ON p.organisation_id=s.organisation_id AND p.campaign_id=s.campaign_id AND p.enabled=true
 LEFT JOIN public.anonymous_discovery_runs a ON a.organisation_id=s.organisation_id
 WHERE s.scope_kind='CAMPAIGN' AND s.campaign_id IS NOT NULL AND c.workflow_state='ACTIVE'
   AND (a.id IS NULL OR (a.status IN('ACTIVE','CLAIMED') AND a.research_expires_at>now()))
 ORDER BY s.organisation_id,s.campaign_id,s.company_id
 LIMIT greatest(0,least(COALESCE(p_limit,100),1000));
$$;

CREATE OR REPLACE FUNCTION public.marketroute_claim_research_work_v1(p_scheduler_run_id uuid,p_at timestamptz DEFAULT now())
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE
  v_work public.research_work_units%ROWTYPE; v_job public.background_jobs%ROWTYPE; v_policy jsonb; v_budget jsonb; v_attempt int; v_remaining numeric;
  v_anon_budget numeric;v_anon_expires timestamptz;v_anon_spent numeric:=0;v_anon_reserved numeric:=0;v_anon_remaining numeric;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.scheduler_runs r JOIN public.scheduler_leases l ON l.owner_run_id=r.id AND l.lease_key='GENESIS_RESEARCH_V1' WHERE r.id=p_scheduler_run_id AND r.status='RUNNING' AND r.runner_key='GENESIS_RESEARCH_V1' AND l.expires_at>p_at) THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_SCHEDULER_RUN_REQUIRED'; END IF;
 SELECT w.* INTO v_work FROM public.research_work_units w JOIN public.background_jobs j ON j.id=w.background_job_id
 WHERE j.job_type='GENESIS_RESEARCH_V1' AND j.status IN('PENDING','DEFERRED') AND j.available_at<=p_at
   AND NOT EXISTS(SELECT 1 FROM public.anonymous_discovery_runs a WHERE a.organisation_id=w.organisation_id AND (a.status NOT IN('ACTIVE','CLAIMED') OR a.research_expires_at<=p_at))
 ORDER BY j.priority,j.created_at,j.id FOR UPDATE OF j SKIP LOCKED LIMIT 1;
 IF NOT FOUND THEN RETURN NULL; END IF;
 SELECT * INTO v_job FROM public.background_jobs WHERE id=v_work.background_job_id FOR UPDATE;
 v_policy:=public.marketroute_research_policy_v1(v_work.organisation_id,v_work.campaign_id); v_budget:=public.marketroute_research_budget_snapshot_v1(v_work.organisation_id,v_work.campaign_id,p_at);
 IF COALESCE((v_policy->>'enabled')::boolean,true)=false OR (v_budget->>'activeJobs')::int >= (v_policy->>'maxConcurrentJobs')::int THEN UPDATE public.background_jobs SET status='DEFERRED',available_at=p_at+interval '5 minutes',updated_at=p_at WHERE id=v_job.id; RETURN NULL; END IF;
 v_remaining:=(v_policy->>'dailyBudgetUsd')::numeric-(v_budget->>'spentTodayUsd')::numeric-(v_budget->>'reservedTodayUsd')::numeric;
 SELECT lifetime_budget_usd,research_expires_at INTO v_anon_budget,v_anon_expires FROM public.anonymous_discovery_runs WHERE organisation_id=v_work.organisation_id AND status IN('ACTIVE','CLAIMED');
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
 RETURN jsonb_build_object('workUnitId',v_work.id,'jobId',v_job.id,'planId',v_work.plan_id,'organisationId',v_work.organisation_id,'campaignId',v_work.campaign_id,'companyId',v_work.company_id,'gapKey',v_work.gap_key,'layer',v_work.layer,'tier',v_work.tier,'action',v_work.action,'subjectType',v_work.subject_type,'subjectId',v_work.subject_id,'claimKey',v_work.claim_key,'reasonCode',v_work.reason_code,'queryHints',v_work.query_hints_json,'payload',v_work.payload_json||jsonb_build_object('dedupeKey',v_work.dedupe_key,'researchOrigin',CASE WHEN v_anon_budget IS NULL THEN COALESCE(v_work.payload_json->>'researchOrigin','CUSTOMER_CAMPAIGN') ELSE 'ANONYMOUS_DISCOVERY' END),'costCeilingUsd',v_work.cost_ceiling_usd,'attemptNumber',v_attempt);
END;
$fn$;

-- Discovery-free workspaces cannot create a second market. Build 24 will replace this
-- with plan entitlements; until then one anonymous discovery means one market.
CREATE OR REPLACE FUNCTION public.marketroute_submit_replacement_campaign_v1(
  p_organisation_id uuid,p_campaign_name text,p_seller_offering_text text,p_objective_text text,p_target_market_text text,p_hard_constraints_text text,p_no_hard_constraints boolean
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_user uuid:=auth.uid();v_seller uuid;v_job uuid;v_name text:=nullif(btrim(COALESCE(p_campaign_name,'')),'');v_offering text:=nullif(btrim(COALESCE(p_seller_offering_text,'')),'');v_no_hard boolean:=COALESCE(p_no_hard_constraints,false);v_hard text:=nullif(btrim(COALESCE(p_hard_constraints_text,'')),'');v_existing_status text;v_existing_lease timestamptz;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_AUTH_REQUIRED'; END IF;
  IF NOT public.marketroute_is_org_admin(p_organisation_id) THEN RAISE EXCEPTION 'MARKETROUTE_CAMPAIGN_ADMIN_REQUIRED'; END IF;
  IF EXISTS(SELECT 1 FROM public.anonymous_discovery_runs WHERE organisation_id=p_organisation_id AND status='CLAIMED') THEN RAISE EXCEPTION 'MARKETROUTE_DISCOVERY_UPGRADE_REQUIRED'; END IF;
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

-- Status now reports the permanent free entitlement count, but still exposes no contact values.
CREATE OR REPLACE FUNCTION public.marketroute_anonymous_discovery_status_v1(p_browser_key_hash text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_run public.anonymous_discovery_runs%ROWTYPE;v_job public.workspace_activation_jobs%ROWTYPE;v_campaign uuid;v_scoped int:=0;v_researched int:=0;v_work_total int:=0;v_work_done int:=0;v_opps int:=0;v_r5 int:=0;v_r6 int:=0;v_free int:=0;
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT * INTO v_run FROM public.anonymous_discovery_runs WHERE browser_key_hash=p_browser_key_hash; IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT * INTO v_job FROM public.workspace_activation_jobs WHERE id=v_run.activation_job_id;
  IF nullif(v_job.result_json->>'campaignId','') IS NOT NULL THEN v_campaign:=(v_job.result_json->>'campaignId')::uuid; END IF;
  IF v_campaign IS NULL THEN SELECT id INTO v_campaign FROM public.campaigns WHERE organisation_id=v_run.organisation_id AND workflow_state<>'ARCHIVED' ORDER BY created_at DESC LIMIT 1; END IF;
  IF v_campaign IS NOT NULL THEN
    SELECT count(*)::int INTO v_scoped FROM public.organisation_company_scopes WHERE organisation_id=v_run.organisation_id AND campaign_id=v_campaign AND scope_kind='CAMPAIGN';
    SELECT count(DISTINCT s.company_id)::int INTO v_researched FROM public.organisation_company_scopes s WHERE s.organisation_id=v_run.organisation_id AND s.campaign_id=v_campaign AND s.scope_kind='CAMPAIGN' AND EXISTS(SELECT 1 FROM public.truth_entity_snapshots t WHERE t.subject_type='COMPANY' AND t.subject_id=s.company_id AND t.profile_key='COMPANY_CORE_V1' AND (t.tenant_scope_organisation_id IS NULL OR t.tenant_scope_organisation_id=v_run.organisation_id));
    SELECT count(*)::int,count(*) FILTER(WHERE j.status='SUCCEEDED')::int INTO v_work_total,v_work_done FROM public.research_work_units w JOIN public.background_jobs j ON j.id=w.background_job_id WHERE w.organisation_id=v_run.organisation_id AND w.campaign_id=v_campaign;
    SELECT count(*)::int INTO v_opps FROM public.opportunities WHERE organisation_id=v_run.organisation_id AND campaign_id=v_campaign;
    SELECT count(DISTINCT company_id)::int INTO v_r5 FROM public.route_authority_r5_records r WHERE r.organisation_id=v_run.organisation_id AND r.campaign_id=v_campaign AND r.decision_code='ROUTE_STRUCTURALLY_OPEN' AND public.marketroute_r5_authority_current_v1(r.authority_record_id,now());
    SELECT count(DISTINCT company_id)::int INTO v_r6 FROM public.contact_authority_r6_records r WHERE r.organisation_id=v_run.organisation_id AND r.campaign_id=v_campaign AND r.decision_code='CONTACT_AUTHORISED' AND public.marketroute_r6_authority_current_v1(r.authority_record_id,now());
  END IF;
  SELECT count(*)::int INTO v_free FROM public.anonymous_discovery_opportunity_unlocks WHERE run_id=v_run.id;
  RETURN jsonb_build_object('runId',v_run.id,'companyName',v_run.company_name,'websiteUrl',v_run.website_url,'runStatus',CASE WHEN v_run.status='ACTIVE' AND v_run.research_expires_at<=now() THEN 'EXPIRED' ELSE v_run.status END,'activation',jsonb_build_object('status',COALESCE(v_job.status,'PENDING'),'stage',COALESCE(v_job.activation_stage,'QUEUED'),'progress',COALESCE(v_job.activation_progress,0),'lastErrorCode',v_job.last_error_code,'updatedAt',v_job.updated_at,'stageDetail',COALESCE(v_job.activation_stage_detail_json,'{}'::jsonb)),'metrics',jsonb_build_object('scopedCompanies',v_scoped,'researchedCompanies',v_researched,'researchWorkTotal',v_work_total,'researchWorkCompleted',v_work_done,'opportunities',v_opps,'structuralRoutes',v_r5,'authorisedRoutes',v_r6,'freeUnlocked',v_free));
END;
$fn$;

REVOKE ALL ON FUNCTION public.marketroute_anonymous_discovery_refresh_unlocks_v1(text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_discovery_free_access_v1(uuid) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_claim_anonymous_discovery_v1(text) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_anonymous_discovery_refresh_unlocks_v1(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_discovery_free_access_v1(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_claim_anonymous_discovery_v1(text) TO authenticated;

INSERT INTO public.marketroute_schema_releases(release_key,build_number,constitution_version,metadata_json)
VALUES('MARKETROUTE_V2_PRODUCT_BUILD23_FREE_EIGHT_ACCOUNT_CLAIM',23,'MRV2-CONSTITUTION-1.0.0',jsonb_build_object(
  'migration','0043_product_free_eight_account_claim.sql','new_authority_writer',false,'authority_semantics_unchanged',true,
  'anonymous_free_opportunity_limit',8,'unlock_assignment_persistent',true,'claim_reruns_research',false,
  'claim_preserves_workspace',true,'claimed_research_finishes_inside_original_budget',true,'second_free_market_blocked',true
)) ON CONFLICT(release_key) DO NOTHING;

NOTIFY pgrst,'reload schema';
COMMIT;
