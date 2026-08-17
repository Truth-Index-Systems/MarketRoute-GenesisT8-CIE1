BEGIN;

-- MarketRoute V2 Product Build 20: Anonymous Discovery + Progressive Pipeline.
-- This adds an isolated, server-mediated pre-auth discovery workspace. It does
-- not grant anonymous database access and creates no Truth/R4/R5/R6/opportunity
-- authority writer. Anonymous research is lifetime-budgeted and time-bounded.

ALTER TABLE public.organisations
  ADD COLUMN IF NOT EXISTS workspace_kind text NOT NULL DEFAULT 'CUSTOMER';

ALTER TABLE public.organisations ALTER COLUMN created_by DROP NOT NULL;
ALTER TABLE public.seller_businesses ALTER COLUMN created_by DROP NOT NULL;
ALTER TABLE public.campaigns ALTER COLUMN created_by DROP NOT NULL;

DO $do$
BEGIN
  IF NOT EXISTS(
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.organisations'::regclass
      AND conname='organisations_workspace_kind_valid'
  ) THEN
    ALTER TABLE public.organisations
      ADD CONSTRAINT organisations_workspace_kind_valid
      CHECK (workspace_kind IN ('CUSTOMER','ANONYMOUS_DISCOVERY'));
  END IF;
  IF NOT EXISTS(
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.organisations'::regclass
      AND conname='organisations_creator_kind_consistent'
  ) THEN
    ALTER TABLE public.organisations
      ADD CONSTRAINT organisations_creator_kind_consistent
      CHECK (
        (workspace_kind='CUSTOMER' AND created_by IS NOT NULL)
        OR (workspace_kind='ANONYMOUS_DISCOVERY' AND created_by IS NULL)
      );
  END IF;
END;
$do$;

CREATE OR REPLACE FUNCTION public.marketroute_enforce_workspace_creator_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
DECLARE v_kind text;
BEGIN
  SELECT workspace_kind INTO v_kind
  FROM public.organisations
  WHERE id=NEW.organisation_id;
  IF v_kind IS NULL THEN
    RAISE EXCEPTION 'MARKETROUTE_WORKSPACE_NOT_FOUND';
  END IF;
  IF v_kind='CUSTOMER' AND NEW.created_by IS NULL THEN
    RAISE EXCEPTION 'MARKETROUTE_CUSTOMER_CREATOR_REQUIRED';
  END IF;
  IF v_kind='ANONYMOUS_DISCOVERY' AND NEW.created_by IS NOT NULL THEN
    RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_CREATOR_FORBIDDEN';
  END IF;
  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS seller_businesses_workspace_creator_guard ON public.seller_businesses;
CREATE TRIGGER seller_businesses_workspace_creator_guard
BEFORE INSERT OR UPDATE OF organisation_id,created_by ON public.seller_businesses
FOR EACH ROW EXECUTE FUNCTION public.marketroute_enforce_workspace_creator_v1();

DROP TRIGGER IF EXISTS campaigns_workspace_creator_guard ON public.campaigns;
CREATE TRIGGER campaigns_workspace_creator_guard
BEFORE INSERT OR UPDATE OF organisation_id,created_by ON public.campaigns
FOR EACH ROW EXECUTE FUNCTION public.marketroute_enforce_workspace_creator_v1();

CREATE TABLE IF NOT EXISTS public.anonymous_discovery_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  browser_key_hash text NOT NULL UNIQUE CHECK (browser_key_hash ~ '^[a-f0-9]{64}$'),
  ip_hash text NOT NULL CHECK (ip_hash ~ '^[a-f0-9]{64}$'),
  organisation_id uuid NOT NULL UNIQUE REFERENCES public.organisations(id) ON DELETE RESTRICT,
  seller_business_id uuid NOT NULL UNIQUE,
  activation_job_id uuid NOT NULL UNIQUE REFERENCES public.workspace_activation_jobs(id) ON DELETE RESTRICT,
  company_name text NOT NULL CHECK (length(btrim(company_name)) BETWEEN 2 AND 160),
  website_url text NOT NULL CHECK (website_url ~ '^https?://'),
  lifetime_budget_usd numeric(18,8) NOT NULL CHECK (lifetime_budget_usd BETWEEN 0.50 AND 25.00),
  target_count integer NOT NULL CHECK (target_count BETWEEN 8 AND 20),
  research_expires_at timestamptz NOT NULL,
  status text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','CLAIMED','EXPIRED','BLOCKED')),
  claimed_by_user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  claimed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT anonymous_discovery_seller_scope_fk FOREIGN KEY(organisation_id,seller_business_id)
    REFERENCES public.seller_businesses(organisation_id,id) ON DELETE RESTRICT,
  CHECK (research_expires_at > created_at),
  CHECK ((status='CLAIMED' AND claimed_by_user_id IS NOT NULL AND claimed_at IS NOT NULL) OR status<>'CLAIMED')
);
CREATE INDEX IF NOT EXISTS anonymous_discovery_ip_time_idx ON public.anonymous_discovery_runs(ip_hash,created_at DESC);
CREATE INDEX IF NOT EXISTS anonymous_discovery_expiry_idx ON public.anonymous_discovery_runs(status,research_expires_at);

DROP TRIGGER IF EXISTS anonymous_discovery_touch_updated_at ON public.anonymous_discovery_runs;
CREATE TRIGGER anonymous_discovery_touch_updated_at
BEFORE UPDATE ON public.anonymous_discovery_runs
FOR EACH ROW EXECUTE FUNCTION public.marketroute_touch_updated_at();

ALTER TABLE public.anonymous_discovery_runs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.anonymous_discovery_runs FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT,INSERT,UPDATE ON public.anonymous_discovery_runs TO service_role;

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
  v_budget numeric:=round(COALESCE(p_lifetime_budget_usd,3)::numeric,8);
  v_hours integer:=COALESCE(p_research_window_hours,24);
  v_target_count integer:=COALESCE(p_target_count,12);
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
  IF v_budget<0.50 OR v_budget>25 OR v_hours<1 OR v_hours>72 OR v_target_count<8 OR v_target_count>20 THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_POLICY_INVALID'; END IF;
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

CREATE OR REPLACE FUNCTION public.marketroute_anonymous_discovery_policy_v1(p_organisation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_run public.anonymous_discovery_runs%ROWTYPE;
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT * INTO v_run FROM public.anonymous_discovery_runs WHERE organisation_id=p_organisation_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN jsonb_build_object('runId',v_run.id,'lifetimeBudgetUsd',v_run.lifetime_budget_usd,'researchExpiresAt',v_run.research_expires_at,'targetCount',v_run.target_count);
END;
$fn$;

-- Activation campaign creation remains the same for customer workspaces but may
-- use a NULL creator only for the isolated anonymous-discovery workspace kind.
CREATE OR REPLACE FUNCTION public.marketroute_create_activation_campaign_v2(
  p_organisation_id uuid,p_seller_business_id uuid,p_campaign_name text,p_objective_text text
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_id uuid;v_user uuid;v_kind text;v_name text:=COALESCE(nullif(btrim(p_campaign_name),''),'Initial market research');
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF length(v_name) NOT BETWEEN 3 AND 120 THEN RAISE EXCEPTION 'MARKETROUTE_CAMPAIGN_NAME_REQUIRED'; END IF;
  SELECT created_by,workspace_kind INTO v_user,v_kind FROM public.organisations WHERE id=p_organisation_id FOR UPDATE;
  IF v_kind IS NULL OR NOT EXISTS(SELECT 1 FROM public.seller_businesses WHERE id=p_seller_business_id AND organisation_id=p_organisation_id AND lifecycle_state='ACTIVE') THEN RAISE EXCEPTION 'MARKETROUTE_ACTIVATION_SCOPE_INVALID'; END IF;
  IF (v_kind='CUSTOMER' AND v_user IS NULL) OR (v_kind='ANONYMOUS_DISCOVERY' AND v_user IS NOT NULL) THEN RAISE EXCEPTION 'MARKETROUTE_ACTIVATION_CREATOR_SCOPE_INVALID'; END IF;
  SELECT id INTO v_id FROM public.campaigns WHERE organisation_id=p_organisation_id AND seller_business_id=p_seller_business_id AND workflow_state<>'ARCHIVED' ORDER BY created_at LIMIT 1;
  IF v_id IS NULL THEN
    INSERT INTO public.campaigns(organisation_id,seller_business_id,name,workflow_state,objective_text,created_by)
    VALUES(p_organisation_id,p_seller_business_id,v_name,'ACTIVE',btrim(p_objective_text),v_user) RETURNING id INTO v_id;
  ELSE
    UPDATE public.campaigns SET name=v_name,workflow_state='ACTIVE',objective_text=btrim(p_objective_text),updated_at=now() WHERE id=v_id;
  END IF;
  RETURN v_id;
END;
$fn$;

-- Anonymous runs never receive the fallback five-dollar policy. The bootstrap
-- application reads the policy above and supplies the smaller bounded values.
-- This planner surface also refuses expired anonymous campaigns and disabled policies.
CREATE OR REPLACE FUNCTION public.marketroute_research_planning_targets_v1(p_limit integer DEFAULT 100)
RETURNS TABLE(organisation_id uuid,campaign_id uuid,company_id uuid)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
 SELECT DISTINCT s.organisation_id,s.campaign_id,s.company_id
 FROM public.organisation_company_scopes s
 JOIN public.campaigns c ON c.id=s.campaign_id AND c.organisation_id=s.organisation_id
 JOIN public.research_budget_policies p ON p.organisation_id=s.organisation_id AND p.campaign_id=s.campaign_id AND p.enabled=true
 LEFT JOIN public.anonymous_discovery_runs a ON a.organisation_id=s.organisation_id
 WHERE s.scope_kind='CAMPAIGN' AND s.campaign_id IS NOT NULL AND c.workflow_state='ACTIVE'
   AND (a.id IS NULL OR (a.status='ACTIVE' AND a.research_expires_at>now()))
 ORDER BY s.organisation_id,s.campaign_id,s.company_id
 LIMIT greatest(0,least(COALESCE(p_limit,100),1000));
$$;

-- Preserve the existing daily budget and add a second, all-time budget gate for
-- anonymous discovery. Work cannot reserve beyond either boundary.
CREATE OR REPLACE FUNCTION public.marketroute_claim_research_work_v1(p_scheduler_run_id uuid,p_at timestamptz DEFAULT now())
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE
  v_work public.research_work_units%ROWTYPE; v_job public.background_jobs%ROWTYPE; v_policy jsonb; v_budget jsonb; v_attempt int; v_remaining numeric;
  v_anon_budget numeric;v_anon_expires timestamptz;v_anon_spent numeric:=0;v_anon_reserved numeric:=0;v_anon_remaining numeric;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.scheduler_runs r JOIN public.scheduler_leases l ON l.owner_run_id=r.id AND l.lease_key='GENESIS_RESEARCH_V1' WHERE r.id=p_scheduler_run_id AND r.status='RUNNING' AND r.runner_key='GENESIS_RESEARCH_V1' AND l.expires_at>p_at) THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_SCHEDULER_RUN_REQUIRED'; END IF;
 SELECT w.* INTO v_work FROM public.research_work_units w JOIN public.background_jobs j ON j.id=w.background_job_id
 WHERE j.job_type='GENESIS_RESEARCH_V1' AND j.status IN('PENDING','DEFERRED') AND j.available_at<=p_at
   AND NOT EXISTS(SELECT 1 FROM public.anonymous_discovery_runs a WHERE a.organisation_id=w.organisation_id AND (a.status<>'ACTIVE' OR a.research_expires_at<=p_at))
 ORDER BY j.priority,j.created_at,j.id FOR UPDATE OF j SKIP LOCKED LIMIT 1;
 IF NOT FOUND THEN RETURN NULL; END IF;
 SELECT * INTO v_job FROM public.background_jobs WHERE id=v_work.background_job_id FOR UPDATE;
 v_policy:=public.marketroute_research_policy_v1(v_work.organisation_id,v_work.campaign_id); v_budget:=public.marketroute_research_budget_snapshot_v1(v_work.organisation_id,v_work.campaign_id,p_at);
 IF COALESCE((v_policy->>'enabled')::boolean,true)=false OR (v_budget->>'activeJobs')::int >= (v_policy->>'maxConcurrentJobs')::int THEN UPDATE public.background_jobs SET status='DEFERRED',available_at=p_at+interval '5 minutes',updated_at=p_at WHERE id=v_job.id; RETURN NULL; END IF;
 v_remaining:=(v_policy->>'dailyBudgetUsd')::numeric-(v_budget->>'spentTodayUsd')::numeric-(v_budget->>'reservedTodayUsd')::numeric;
 SELECT lifetime_budget_usd,research_expires_at INTO v_anon_budget,v_anon_expires FROM public.anonymous_discovery_runs WHERE organisation_id=v_work.organisation_id AND status='ACTIVE';
 IF v_anon_budget IS NOT NULL THEN
   IF v_anon_expires<=p_at THEN UPDATE public.background_jobs SET status='CANCELLED',last_error_code='MARKETROUTE_ANONYMOUS_RESEARCH_WINDOW_CLOSED',updated_at=p_at WHERE id=v_job.id; RETURN NULL; END IF;
   SELECT COALESCE(sum(amount_usd),0) INTO v_anon_spent FROM public.research_budget_events WHERE organisation_id=v_work.organisation_id AND campaign_id=v_work.campaign_id AND event_type='COMMIT';
   SELECT COALESCE(sum(r.amount_usd),0) INTO v_anon_reserved FROM public.research_budget_events r WHERE r.organisation_id=v_work.organisation_id AND r.campaign_id=v_work.campaign_id AND r.event_type='RESERVE' AND NOT EXISTS(SELECT 1 FROM public.research_budget_events x WHERE x.work_unit_id=r.work_unit_id AND x.attempt_number=r.attempt_number AND x.event_type IN('COMMIT','RELEASE'));
   v_anon_remaining:=greatest(0,v_anon_budget-v_anon_spent-v_anon_reserved);
   v_remaining:=least(v_remaining,v_anon_remaining);
 END IF;
 IF v_work.cost_ceiling_usd>greatest(0,v_remaining) OR v_work.cost_ceiling_usd>(v_policy->>'maxJobCostUsd')::numeric THEN
   UPDATE public.background_jobs SET status=CASE WHEN v_anon_budget IS NOT NULL AND greatest(0,v_remaining)<=0 THEN 'CANCELLED' ELSE 'DEFERRED' END,available_at=CASE WHEN v_anon_budget IS NOT NULL THEN available_at ELSE (date_trunc('day',p_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC')+interval '1 day' END,last_error_code=CASE WHEN v_anon_budget IS NOT NULL AND greatest(0,v_remaining)<=0 THEN 'MARKETROUTE_ANONYMOUS_RESEARCH_BUDGET_EXHAUSTED' ELSE last_error_code END,updated_at=p_at WHERE id=v_job.id;
   RETURN NULL;
 END IF;
 v_attempt:=v_job.attempt_count+1;
 IF EXISTS(SELECT 1 FROM public.research_budget_events WHERE work_unit_id=v_work.id AND attempt_number=v_attempt AND event_type='RESERVE') THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_BUDGET_ALREADY_RESERVED'; END IF;
 INSERT INTO public.research_budget_events(organisation_id,campaign_id,work_unit_id,scheduler_run_id,attempt_number,event_type,amount_usd,occurred_at) VALUES(v_work.organisation_id,v_work.campaign_id,v_work.id,p_scheduler_run_id,v_attempt,'RESERVE',v_work.cost_ceiling_usd,p_at);
 UPDATE public.background_jobs SET status='RUNNING',reserved_by_run_id=p_scheduler_run_id,reserved_at=p_at,attempt_count=v_attempt,updated_at=p_at WHERE id=v_job.id;
 INSERT INTO public.background_job_attempts(job_id,scheduler_run_id,attempt_number,status,started_at) VALUES(v_job.id,p_scheduler_run_id,v_attempt,'RUNNING',p_at);
 RETURN jsonb_build_object('workUnitId',v_work.id,'jobId',v_job.id,'planId',v_work.plan_id,'organisationId',v_work.organisation_id,'campaignId',v_work.campaign_id,'companyId',v_work.company_id,'gapKey',v_work.gap_key,'layer',v_work.layer,'tier',v_work.tier,'action',v_work.action,'subjectType',v_work.subject_type,'subjectId',v_work.subject_id,'claimKey',v_work.claim_key,'reasonCode',v_work.reason_code,'queryHints',v_work.query_hints_json,'payload',v_work.payload_json||jsonb_build_object('dedupeKey',v_work.dedupe_key,'researchOrigin',CASE WHEN v_anon_budget IS NULL THEN COALESCE(v_work.payload_json->>'researchOrigin','CUSTOMER_CAMPAIGN') ELSE 'ANONYMOUS_DISCOVERY' END),'costCeilingUsd',v_work.cost_ceiling_usd,'attemptNumber',v_attempt);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.marketroute_anonymous_discovery_status_v1(p_browser_key_hash text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE
  v_run public.anonymous_discovery_runs%ROWTYPE;v_job public.workspace_activation_jobs%ROWTYPE;v_campaign uuid;
  v_scoped int:=0;v_researched int:=0;v_work_total int:=0;v_work_done int:=0;v_opps int:=0;v_r5 int:=0;v_r6 int:=0;
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT * INTO v_run FROM public.anonymous_discovery_runs WHERE browser_key_hash=p_browser_key_hash;
  IF NOT FOUND THEN RETURN NULL; END IF;
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
  RETURN jsonb_build_object(
    'runId',v_run.id,'companyName',v_run.company_name,'websiteUrl',v_run.website_url,
    'runStatus',CASE WHEN v_run.status='ACTIVE' AND v_run.research_expires_at<=now() THEN 'EXPIRED' ELSE v_run.status END,
    'activation',jsonb_build_object('status',COALESCE(v_job.status,'PENDING'),'stage',COALESCE(v_job.activation_stage,'QUEUED'),'progress',COALESCE(v_job.activation_progress,0),'lastErrorCode',v_job.last_error_code,'updatedAt',v_job.updated_at,'stageDetail',COALESCE(v_job.activation_stage_detail_json,'{}'::jsonb)),
    'metrics',jsonb_build_object('scopedCompanies',v_scoped,'researchedCompanies',v_researched,'researchWorkTotal',v_work_total,'researchWorkCompleted',v_work_done,'opportunities',v_opps,'structuralRoutes',v_r5,'authorisedRoutes',v_r6)
  );
END;
$fn$;

REVOKE ALL ON FUNCTION public.marketroute_create_anonymous_discovery_v1(text,text,text,text,text,text,text,numeric,integer,integer) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_anonymous_discovery_policy_v1(uuid) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_anonymous_discovery_status_v1(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_create_anonymous_discovery_v1(text,text,text,text,text,text,text,numeric,integer,integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_anonymous_discovery_policy_v1(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_anonymous_discovery_status_v1(text) TO service_role;

INSERT INTO public.marketroute_schema_releases(release_key,build_number,constitution_version,metadata_json)
VALUES('MARKETROUTE_V2_PRODUCT_BUILD20_ANONYMOUS_DISCOVERY_PIPELINE',20,'MRV2-CONSTITUTION-1.0.0',jsonb_build_object(
  'migration','0040_product_anonymous_discovery_pipeline.sql','new_authority_writer',false,'anonymous_database_access',false,
  'anonymous_discovery',true,'one_run_per_browser_key',true,'lifetime_research_budget',true,'research_window_bounded',true,
  'progress_from_persisted_state',true,'account_claiming_deferred_to_build23',true
)) ON CONFLICT(release_key) DO NOTHING;

NOTIFY pgrst,'reload schema';
COMMIT;
