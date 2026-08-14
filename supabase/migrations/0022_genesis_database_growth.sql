BEGIN;

-- MarketRoute V2 production growth activation.
-- Purpose: continuously build a GLOBAL factual/evidence intelligence bank before launch.
-- This migration creates NO authority writer and cannot write R4/R5/R6/opportunity/execution authority.

CREATE TABLE public.genesis_growth_industries (
  industry_key text PRIMARY KEY CHECK (industry_key ~ '^[a-z0-9][a-z0-9-]{1,62}$'),
  display_name text NOT NULL CHECK (length(btrim(display_name)) BETWEEN 2 AND 120),
  priority integer NOT NULL CHECK (priority BETWEEN 1 AND 1000),
  seed_target_company_count integer NOT NULL DEFAULT 50 CHECK (seed_target_company_count BETWEEN 1 AND 10000),
  launch_target_company_count integer NOT NULL DEFAULT 500 CHECK (launch_target_company_count >= seed_target_company_count AND launch_target_company_count <= 100000),
  enabled boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.genesis_growth_industries(industry_key,display_name,priority,seed_target_company_count,launch_target_company_count)
VALUES
 ('software','Software & SaaS',100,50,500),
 ('professional-services','Professional Services',95,50,500),
 ('marketing','Marketing & Advertising',90,50,500),
 ('recruitment','Recruitment & HR',90,50,500),
 ('finance','Finance & FinTech',85,50,500),
 ('healthcare','Healthcare & HealthTech',85,50,500),
 ('retail','Retail & E-commerce',80,50,500),
 ('manufacturing','Manufacturing',80,50,500),
 ('logistics','Logistics & Supply Chain',80,50,500),
 ('construction','Construction & PropTech',75,50,500)
ON CONFLICT(industry_key) DO UPDATE SET display_name=EXCLUDED.display_name,priority=EXCLUDED.priority;

CREATE TABLE public.genesis_growth_company_memberships (
  industry_key text NOT NULL REFERENCES public.genesis_growth_industries(industry_key) ON DELETE RESTRICT,
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  discovery_reason text,
  first_discovered_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(industry_key,company_id)
);
CREATE INDEX genesis_growth_membership_company_idx ON public.genesis_growth_company_memberships(company_id);

CREATE TABLE public.genesis_growth_company_progress (
  company_id uuid PRIMARY KEY REFERENCES public.companies(id) ON DELETE CASCADE,
  core_scan_at timestamptz,
  core_complete_at timestamptz,
  profile_complete_at timestamptz,
  routes_scan_at timestamptz,
  routes_complete_at timestamptz,
  contacts_scan_at timestamptz,
  contacts_complete_at timestamptz,
  last_researched_at timestamptz,
  retry_after timestamptz,
  last_error_code text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX genesis_growth_progress_retry_idx ON public.genesis_growth_company_progress(retry_after,last_researched_at);

CREATE TABLE public.genesis_growth_people (
  identity_key text PRIMARY KEY,
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  person_id uuid NOT NULL REFERENCES public.people(id) ON DELETE CASCADE,
  canonical_name text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(company_id,person_id)
);

CREATE TABLE public.genesis_growth_settings (
  singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
  enabled boolean NOT NULL DEFAULT true,
  seed_target_company_count integer NOT NULL DEFAULT 50 CHECK(seed_target_company_count BETWEEN 1 AND 10000),
  launch_target_company_count integer NOT NULL DEFAULT 500 CHECK(launch_target_company_count >= seed_target_company_count AND launch_target_company_count <= 100000),
  daily_budget_usd numeric(18,6) NOT NULL DEFAULT 100 CHECK(daily_budget_usd BETWEEN 0 AND 1000000),
  max_action_cost_usd numeric(18,6) NOT NULL DEFAULT 0.50 CHECK(max_action_cost_usd BETWEEN 0.001 AND 10000),
  discovery_batch_size integer NOT NULL DEFAULT 10 CHECK(discovery_batch_size BETWEEN 1 AND 25),
  max_actions_per_run integer NOT NULL DEFAULT 1 CHECK(max_actions_per_run BETWEEN 1 AND 20),
  retry_hours integer NOT NULL DEFAULT 24 CHECK(retry_hours BETWEEN 1 AND 720),
  refresh_days integer NOT NULL DEFAULT 30 CHECK(refresh_days BETWEEN 1 AND 365),
  updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.genesis_growth_settings(singleton) VALUES(true) ON CONFLICT(singleton) DO NOTHING;

CREATE TABLE public.genesis_growth_action_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  scheduler_run_id uuid NOT NULL REFERENCES public.scheduler_runs(id) ON DELETE CASCADE,
  action_kind text NOT NULL CHECK(action_kind IN ('DISCOVER_COMPANIES','RESEARCH_CORE_PROFILE','RESEARCH_ROUTES','RESEARCH_CONTACTS','REFRESH_CORE')),
  phase text NOT NULL CHECK(phase IN ('SEED','BREADTH','DEPTH','REFRESH')),
  industry_key text REFERENCES public.genesis_growth_industries(industry_key) ON DELETE RESTRICT,
  company_id uuid REFERENCES public.companies(id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'RUNNING' CHECK(status IN ('RUNNING','SUCCEEDED','FAILED','SKIPPED')),
  actual_cost_usd numeric(18,8) CHECK(actual_cost_usd IS NULL OR actual_cost_usd >= 0),
  result_json jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(result_json)='object'),
  error_code text,
  started_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  CHECK((action_kind='DISCOVER_COMPANIES' AND industry_key IS NOT NULL AND company_id IS NULL) OR action_kind<>'DISCOVER_COMPANIES')
);
CREATE INDEX genesis_growth_actions_status_idx ON public.genesis_growth_action_runs(status,started_at DESC);
CREATE INDEX genesis_growth_actions_company_idx ON public.genesis_growth_action_runs(company_id,started_at DESC);

CREATE TABLE public.genesis_growth_budget_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  action_run_id uuid NOT NULL REFERENCES public.genesis_growth_action_runs(id) ON DELETE RESTRICT,
  industry_key text REFERENCES public.genesis_growth_industries(industry_key) ON DELETE RESTRICT,
  company_id uuid REFERENCES public.companies(id) ON DELETE SET NULL,
  amount_usd numeric(18,8) NOT NULL CHECK(amount_usd >= 0),
  occurred_at timestamptz NOT NULL DEFAULT now(),
  metadata_json jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(metadata_json)='object'),
  UNIQUE(action_run_id)
);
CREATE INDEX genesis_growth_budget_time_idx ON public.genesis_growth_budget_events(occurred_at DESC);

CREATE TRIGGER genesis_growth_industries_touch_updated_at BEFORE UPDATE ON public.genesis_growth_industries FOR EACH ROW EXECUTE FUNCTION public.marketroute_touch_updated_at();
CREATE TRIGGER genesis_growth_progress_touch_updated_at BEFORE UPDATE ON public.genesis_growth_company_progress FOR EACH ROW EXECUTE FUNCTION public.marketroute_touch_updated_at();
CREATE TRIGGER genesis_growth_settings_touch_updated_at BEFORE UPDATE ON public.genesis_growth_settings FOR EACH ROW EXECUTE FUNCTION public.marketroute_touch_updated_at();
CREATE TRIGGER genesis_growth_budget_append_only BEFORE UPDATE OR DELETE ON public.genesis_growth_budget_events FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

ALTER TABLE public.genesis_growth_industries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.genesis_growth_company_memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.genesis_growth_company_progress ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.genesis_growth_people ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.genesis_growth_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.genesis_growth_action_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.genesis_growth_budget_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.genesis_growth_industries,public.genesis_growth_company_memberships,public.genesis_growth_company_progress,public.genesis_growth_people,public.genesis_growth_settings,public.genesis_growth_action_runs,public.genesis_growth_budget_events FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT,INSERT,UPDATE ON public.genesis_growth_industries,public.genesis_growth_company_memberships,public.genesis_growth_company_progress,public.genesis_growth_people,public.genesis_growth_settings,public.genesis_growth_action_runs TO service_role;
GRANT SELECT,INSERT ON public.genesis_growth_budget_events TO service_role;

CREATE OR REPLACE FUNCTION public.marketroute_sync_growth_settings_v1(
 p_enabled boolean,p_seed_target integer,p_launch_target integer,p_daily_budget numeric,p_max_action_cost numeric,p_discovery_batch integer,p_max_actions integer,p_retry_hours integer,p_refresh_days integer
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
BEGIN
 PERFORM public.marketroute_require_service_role();
 IF p_seed_target<1 OR p_launch_target<p_seed_target OR p_discovery_batch<1 OR p_discovery_batch>25 OR p_max_actions<1 OR p_max_actions>20 OR p_retry_hours<1 OR p_refresh_days<1 THEN RAISE EXCEPTION 'MARKETROUTE_GROWTH_SETTINGS_INVALID'; END IF;
 IF p_daily_budget<0 OR p_max_action_cost<=0 THEN RAISE EXCEPTION 'MARKETROUTE_GROWTH_BUDGET_INVALID'; END IF;
 INSERT INTO public.genesis_growth_settings(singleton,enabled,seed_target_company_count,launch_target_company_count,daily_budget_usd,max_action_cost_usd,discovery_batch_size,max_actions_per_run,retry_hours,refresh_days,updated_at)
 VALUES(true,p_enabled,p_seed_target,p_launch_target,p_daily_budget,p_max_action_cost,p_discovery_batch,p_max_actions,p_retry_hours,p_refresh_days,now())
 ON CONFLICT(singleton) DO UPDATE SET enabled=EXCLUDED.enabled,seed_target_company_count=EXCLUDED.seed_target_company_count,launch_target_company_count=EXCLUDED.launch_target_company_count,daily_budget_usd=EXCLUDED.daily_budget_usd,max_action_cost_usd=EXCLUDED.max_action_cost_usd,discovery_batch_size=EXCLUDED.discovery_batch_size,max_actions_per_run=EXCLUDED.max_actions_per_run,retry_hours=EXCLUDED.retry_hours,refresh_days=EXCLUDED.refresh_days,updated_at=now();
 UPDATE public.genesis_growth_industries SET seed_target_company_count=p_seed_target,launch_target_company_count=p_launch_target,updated_at=now() WHERE enabled;
END;$fn$;

CREATE OR REPLACE FUNCTION public.marketroute_start_growth_scheduler_run_v1(p_at timestamptz DEFAULT now()) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_id uuid;v_owner uuid;
BEGIN
 PERFORM public.marketroute_require_service_role();
 IF abs(extract(epoch from (p_at-now())))>300 THEN RAISE EXCEPTION 'MARKETROUTE_GROWTH_SCHEDULER_TIME_NOT_CURRENT'; END IF;
 INSERT INTO public.scheduler_runs(runner_key,status,started_at,metadata_json) VALUES('GENESIS_DATABASE_GROWTH_V1','RUNNING',p_at,jsonb_build_object('growthEngine','MRV2-GENESIS-GROWTH-1.0.0')) RETURNING id INTO v_id;
 INSERT INTO public.scheduler_leases(lease_key,owner_run_id,acquired_at,expires_at,heartbeat_at) VALUES('GENESIS_DATABASE_GROWTH_V1',v_id,p_at,p_at+interval '10 minutes',p_at)
 ON CONFLICT(lease_key) DO UPDATE SET owner_run_id=EXCLUDED.owner_run_id,acquired_at=EXCLUDED.acquired_at,expires_at=EXCLUDED.expires_at,heartbeat_at=EXCLUDED.heartbeat_at WHERE public.scheduler_leases.expires_at<=p_at RETURNING owner_run_id INTO v_owner;
 IF v_owner IS DISTINCT FROM v_id THEN UPDATE public.scheduler_runs SET status='CANCELLED',completed_at=p_at,metadata_json=metadata_json||jsonb_build_object('leaseHeld',true) WHERE id=v_id; RAISE EXCEPTION 'MARKETROUTE_GROWTH_SCHEDULER_LEASE_HELD'; END IF;
 RETURN v_id;
END;$fn$;

CREATE OR REPLACE FUNCTION public.marketroute_heartbeat_growth_scheduler_run_v1(p_scheduler_run_id uuid,p_at timestamptz DEFAULT now()) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
BEGIN
 PERFORM public.marketroute_require_service_role();
 UPDATE public.scheduler_leases SET heartbeat_at=p_at,expires_at=p_at+interval '10 minutes' WHERE lease_key='GENESIS_DATABASE_GROWTH_V1' AND owner_run_id=p_scheduler_run_id AND expires_at>p_at AND EXISTS(SELECT 1 FROM public.scheduler_runs r WHERE r.id=p_scheduler_run_id AND r.runner_key='GENESIS_DATABASE_GROWTH_V1' AND r.status='RUNNING');
 IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_GROWTH_SCHEDULER_LEASE_NOT_OWNED'; END IF;
END;$fn$;

CREATE OR REPLACE FUNCTION public.marketroute_finish_growth_scheduler_run_v1(p_scheduler_run_id uuid,p_status text,p_metadata jsonb DEFAULT '{}'::jsonb,p_at timestamptz DEFAULT now()) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
BEGIN
 PERFORM public.marketroute_require_service_role();
 IF p_status NOT IN('SUCCEEDED','PARTIAL','FAILED','CANCELLED') THEN RAISE EXCEPTION 'MARKETROUTE_GROWTH_RUN_STATUS_INVALID'; END IF;
 UPDATE public.scheduler_runs SET status=p_status,completed_at=p_at,metadata_json=COALESCE(metadata_json,'{}'::jsonb)||COALESCE(p_metadata,'{}'::jsonb) WHERE id=p_scheduler_run_id AND runner_key='GENESIS_DATABASE_GROWTH_V1' AND status='RUNNING';
 IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_GROWTH_RUN_NOT_ACTIVE'; END IF;
 DELETE FROM public.scheduler_leases WHERE lease_key='GENESIS_DATABASE_GROWTH_V1' AND owner_run_id=p_scheduler_run_id;
END;$fn$;

CREATE OR REPLACE FUNCTION public.marketroute_growth_existing_domains_v1(p_industry_key text,p_limit integer DEFAULT 1000) RETURNS text[]
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v text[];
BEGIN
 PERFORM public.marketroute_require_service_role();
 SELECT COALESCE(array_agg(c.canonical_domain ORDER BY c.canonical_domain),'{}'::text[]) INTO v FROM public.genesis_growth_company_memberships m JOIN public.companies c ON c.id=m.company_id WHERE m.industry_key=p_industry_key AND c.canonical_domain IS NOT NULL LIMIT greatest(1,least(COALESCE(p_limit,1000),5000));
 RETURN v;
END;$fn$;

CREATE OR REPLACE FUNCTION public.marketroute_growth_ensure_company_v1(p_industry_key text,p_name text,p_domain text,p_website_url text,p_country_code text,p_discovery_reason text DEFAULT NULL) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_domain text:=lower(regexp_replace(btrim(COALESCE(p_domain,'')),'^www\.','','i'));v_company uuid;v_country text;
BEGIN
 PERFORM public.marketroute_require_service_role();
 IF NOT EXISTS(SELECT 1 FROM public.genesis_growth_industries WHERE industry_key=p_industry_key AND enabled) THEN RAISE EXCEPTION 'MARKETROUTE_GROWTH_INDUSTRY_INVALID'; END IF;
 IF v_domain !~ '^[a-z0-9][a-z0-9.-]*\.[a-z]{2,63}$' THEN RAISE EXCEPTION 'MARKETROUTE_GROWTH_COMPANY_DOMAIN_INVALID'; END IF;
 v_country:=CASE WHEN upper(COALESCE(p_country_code,''))~'^[A-Z]{2}$' THEN upper(p_country_code) ELSE NULL END;
 SELECT id INTO v_company FROM public.companies WHERE canonical_domain=v_domain LIMIT 1;
 IF v_company IS NULL THEN INSERT INTO public.companies(canonical_name,canonical_domain,website_url,country_code,lifecycle_state) VALUES(left(btrim(p_name),240),v_domain,COALESCE(nullif(btrim(COALESCE(p_website_url,'')),''),'https://'||v_domain),v_country,'ACTIVE') RETURNING id INTO v_company;
 ELSE UPDATE public.companies SET canonical_name=CASE WHEN length(btrim(COALESCE(p_name,'')))>0 THEN left(btrim(p_name),240) ELSE canonical_name END,website_url=COALESCE(website_url,nullif(btrim(COALESCE(p_website_url,'')),''),'https://'||v_domain),country_code=COALESCE(country_code,v_country),updated_at=now() WHERE id=v_company;
 END IF;
 INSERT INTO public.genesis_growth_company_memberships(industry_key,company_id,discovery_reason) VALUES(p_industry_key,v_company,left(nullif(btrim(COALESCE(p_discovery_reason,'')),''),500)) ON CONFLICT(industry_key,company_id) DO NOTHING;
 INSERT INTO public.genesis_growth_company_progress(company_id) VALUES(v_company) ON CONFLICT(company_id) DO NOTHING;
 RETURN v_company;
END;$fn$;

CREATE OR REPLACE FUNCTION public.marketroute_growth_ensure_person_v1(p_company_id uuid,p_name text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_name text:=left(btrim(COALESCE(p_name,'')),240);v_key text;v_person uuid;
BEGIN
 PERFORM public.marketroute_require_service_role();
 IF v_name='' OR NOT EXISTS(SELECT 1 FROM public.companies WHERE id=p_company_id) THEN RAISE EXCEPTION 'MARKETROUTE_GROWTH_PERSON_INVALID'; END IF;
 v_key:=encode(extensions.digest(convert_to(p_company_id::text||'|'||lower(regexp_replace(v_name,'\s+',' ','g')),'UTF8'),'sha256'),'hex');
 SELECT person_id INTO v_person FROM public.genesis_growth_people WHERE identity_key=v_key;
 IF v_person IS NULL THEN INSERT INTO public.people(display_name,canonical_name,lifecycle_state) VALUES(v_name,v_name,'ACTIVE') RETURNING id INTO v_person; INSERT INTO public.genesis_growth_people(identity_key,company_id,person_id,canonical_name) VALUES(v_key,p_company_id,v_person,v_name); END IF;
 RETURN v_person;
END;$fn$;

CREATE OR REPLACE FUNCTION public.marketroute_growth_mark_stage_v1(p_company_id uuid,p_stage text,p_complete boolean,p_error_code text DEFAULT NULL,p_retry_after timestamptz DEFAULT NULL,p_at timestamptz DEFAULT now()) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
BEGIN
 PERFORM public.marketroute_require_service_role();
 INSERT INTO public.genesis_growth_company_progress(company_id) VALUES(p_company_id) ON CONFLICT(company_id) DO NOTHING;
 IF p_stage='CORE' THEN UPDATE public.genesis_growth_company_progress SET core_scan_at=p_at,core_complete_at=CASE WHEN p_complete THEN COALESCE(core_complete_at,p_at) ELSE core_complete_at END,last_researched_at=p_at,retry_after=p_retry_after,last_error_code=left(p_error_code,300),updated_at=p_at WHERE company_id=p_company_id;
 ELSIF p_stage='PROFILE' THEN UPDATE public.genesis_growth_company_progress SET core_scan_at=COALESCE(core_scan_at,p_at),profile_complete_at=CASE WHEN p_complete THEN COALESCE(profile_complete_at,p_at) ELSE profile_complete_at END,last_researched_at=p_at,retry_after=p_retry_after,last_error_code=left(p_error_code,300),updated_at=p_at WHERE company_id=p_company_id;
 ELSIF p_stage='ROUTES' THEN UPDATE public.genesis_growth_company_progress SET routes_scan_at=p_at,routes_complete_at=CASE WHEN p_complete THEN COALESCE(routes_complete_at,p_at) ELSE routes_complete_at END,last_researched_at=p_at,retry_after=p_retry_after,last_error_code=left(p_error_code,300),updated_at=p_at WHERE company_id=p_company_id;
 ELSIF p_stage='CONTACTS' THEN UPDATE public.genesis_growth_company_progress SET contacts_scan_at=p_at,contacts_complete_at=CASE WHEN p_complete THEN COALESCE(contacts_complete_at,p_at) ELSE contacts_complete_at END,last_researched_at=p_at,retry_after=p_retry_after,last_error_code=left(p_error_code,300),updated_at=p_at WHERE company_id=p_company_id;
 ELSE RAISE EXCEPTION 'MARKETROUTE_GROWTH_STAGE_INVALID'; END IF;
END;$fn$;

CREATE OR REPLACE FUNCTION public.marketroute_growth_next_action_v1(p_scheduler_run_id uuid,p_at timestamptz DEFAULT now()) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE s public.genesis_growth_settings%ROWTYPE;v_day timestamptz:=date_trunc('day',p_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';v_spent numeric;v_phase text;v_industry text;v_company uuid;v_action text;v_id uuid;v_seed_remaining int;v_launch_remaining int;v_incomplete int;
BEGIN
 PERFORM public.marketroute_require_service_role();
 IF NOT EXISTS(SELECT 1 FROM public.scheduler_runs r JOIN public.scheduler_leases l ON l.owner_run_id=r.id AND l.lease_key='GENESIS_DATABASE_GROWTH_V1' WHERE r.id=p_scheduler_run_id AND r.runner_key='GENESIS_DATABASE_GROWTH_V1' AND r.status='RUNNING' AND l.expires_at>p_at) THEN RAISE EXCEPTION 'MARKETROUTE_GROWTH_SCHEDULER_RUN_REQUIRED'; END IF;
 SELECT * INTO s FROM public.genesis_growth_settings WHERE singleton=true; IF NOT FOUND OR NOT s.enabled THEN RETURN NULL; END IF;
 SELECT COALESCE(sum(amount_usd),0) INTO v_spent FROM public.genesis_growth_budget_events WHERE occurred_at>=v_day AND occurred_at<v_day+interval '1 day'; IF v_spent+s.max_action_cost_usd>s.daily_budget_usd THEN RETURN jsonb_build_object('state','BUDGET_EXHAUSTED','spentTodayUsd',v_spent,'dailyBudgetUsd',s.daily_budget_usd); END IF;
 SELECT count(*) INTO v_seed_remaining FROM public.genesis_growth_industries i WHERE i.enabled AND (SELECT count(*) FROM public.genesis_growth_company_memberships m WHERE m.industry_key=i.industry_key)<i.seed_target_company_count;
 SELECT count(*) INTO v_launch_remaining FROM public.genesis_growth_industries i WHERE i.enabled AND (SELECT count(*) FROM public.genesis_growth_company_memberships m WHERE m.industry_key=i.industry_key)<i.launch_target_company_count;
 IF v_seed_remaining>0 THEN v_phase:='SEED';
   SELECT i.industry_key INTO v_industry FROM public.genesis_growth_industries i WHERE i.enabled AND (SELECT count(*) FROM public.genesis_growth_company_memberships m WHERE m.industry_key=i.industry_key)<i.seed_target_company_count ORDER BY ((SELECT count(*) FROM public.genesis_growth_company_memberships m WHERE m.industry_key=i.industry_key)::numeric/greatest(1,i.seed_target_company_count)),i.priority DESC,i.industry_key LIMIT 1;
   v_action:='DISCOVER_COMPANIES';
 ELSIF v_launch_remaining>0 THEN v_phase:='BREADTH';
   SELECT i.industry_key INTO v_industry FROM public.genesis_growth_industries i WHERE i.enabled AND (SELECT count(*) FROM public.genesis_growth_company_memberships m WHERE m.industry_key=i.industry_key)<i.launch_target_company_count ORDER BY ((SELECT count(*) FROM public.genesis_growth_company_memberships m WHERE m.industry_key=i.industry_key)::numeric/greatest(1,i.launch_target_company_count)),i.priority DESC,i.industry_key LIMIT 1;
   v_action:='DISCOVER_COMPANIES';
 ELSE
   SELECT count(*) INTO v_incomplete FROM public.genesis_growth_company_progress p WHERE (p.retry_after IS NULL OR p.retry_after<=p_at) AND (p.core_complete_at IS NULL OR p.profile_complete_at IS NULL OR p.routes_complete_at IS NULL OR p.contacts_complete_at IS NULL);
   IF v_incomplete>0 THEN v_phase:='DEPTH';
     SELECT p.company_id,CASE WHEN p.core_complete_at IS NULL OR p.profile_complete_at IS NULL THEN 'RESEARCH_CORE_PROFILE' WHEN p.routes_complete_at IS NULL THEN 'RESEARCH_ROUTES' ELSE 'RESEARCH_CONTACTS' END INTO v_company,v_action FROM public.genesis_growth_company_progress p WHERE (p.retry_after IS NULL OR p.retry_after<=p_at) AND (p.core_complete_at IS NULL OR p.profile_complete_at IS NULL OR p.routes_complete_at IS NULL OR p.contacts_complete_at IS NULL) ORDER BY ((CASE WHEN p.core_complete_at IS NOT NULL THEN 1 ELSE 0 END)+(CASE WHEN p.profile_complete_at IS NOT NULL THEN 1 ELSE 0 END)+(CASE WHEN p.routes_complete_at IS NOT NULL THEN 1 ELSE 0 END)+(CASE WHEN p.contacts_complete_at IS NOT NULL THEN 1 ELSE 0 END)),COALESCE(p.last_researched_at,'epoch'::timestamptz),p.company_id LIMIT 1;
     SELECT industry_key INTO v_industry FROM public.genesis_growth_company_memberships WHERE company_id=v_company ORDER BY industry_key LIMIT 1;
   ELSE v_phase:='REFRESH';v_action:='REFRESH_CORE';
     SELECT p.company_id INTO v_company FROM public.genesis_growth_company_progress p WHERE COALESCE(p.last_researched_at,'epoch'::timestamptz)<=p_at-make_interval(days=>s.refresh_days) ORDER BY COALESCE(p.last_researched_at,'epoch'::timestamptz),p.company_id LIMIT 1;
     IF v_company IS NULL THEN RETURN NULL; END IF; SELECT industry_key INTO v_industry FROM public.genesis_growth_company_memberships WHERE company_id=v_company ORDER BY industry_key LIMIT 1;
   END IF;
 END IF;
 INSERT INTO public.genesis_growth_action_runs(scheduler_run_id,action_kind,phase,industry_key,company_id,status,started_at) VALUES(p_scheduler_run_id,v_action,v_phase,v_industry,v_company,'RUNNING',p_at) RETURNING id INTO v_id;
 RETURN jsonb_build_object('state','ACTION','actionRunId',v_id,'phase',v_phase,'actionKind',v_action,'industryKey',v_industry,'companyId',v_company,'maxActionCostUsd',s.max_action_cost_usd,'discoveryBatchSize',s.discovery_batch_size,'retryHours',s.retry_hours);
END;$fn$;

CREATE OR REPLACE FUNCTION public.marketroute_growth_complete_action_v1(p_action_run_id uuid,p_actual_cost_usd numeric,p_result jsonb DEFAULT '{}'::jsonb,p_at timestamptz DEFAULT now()) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE r public.genesis_growth_action_runs%ROWTYPE;s public.genesis_growth_settings%ROWTYPE;
BEGIN
 PERFORM public.marketroute_require_service_role(); SELECT * INTO r FROM public.genesis_growth_action_runs WHERE id=p_action_run_id FOR UPDATE; IF NOT FOUND OR r.status<>'RUNNING' THEN RAISE EXCEPTION 'MARKETROUTE_GROWTH_ACTION_NOT_RUNNING'; END IF; SELECT * INTO s FROM public.genesis_growth_settings WHERE singleton=true;
 IF p_actual_cost_usd<0 OR p_actual_cost_usd>s.max_action_cost_usd*2 THEN RAISE EXCEPTION 'MARKETROUTE_GROWTH_ACTION_COST_INVALID'; END IF;
 UPDATE public.genesis_growth_action_runs SET status='SUCCEEDED',actual_cost_usd=p_actual_cost_usd,result_json=COALESCE(p_result,'{}'::jsonb),completed_at=p_at WHERE id=p_action_run_id;
 INSERT INTO public.genesis_growth_budget_events(action_run_id,industry_key,company_id,amount_usd,occurred_at,metadata_json) VALUES(p_action_run_id,r.industry_key,r.company_id,p_actual_cost_usd,p_at,jsonb_build_object('actionKind',r.action_kind,'phase',r.phase));
END;$fn$;

CREATE OR REPLACE FUNCTION public.marketroute_growth_fail_action_v1(p_action_run_id uuid,p_error_code text,p_actual_cost_usd numeric DEFAULT 0,p_retry_after timestamptz DEFAULT NULL,p_at timestamptz DEFAULT now()) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE r public.genesis_growth_action_runs%ROWTYPE;s public.genesis_growth_settings%ROWTYPE;
BEGIN
 PERFORM public.marketroute_require_service_role(); SELECT * INTO r FROM public.genesis_growth_action_runs WHERE id=p_action_run_id FOR UPDATE; IF NOT FOUND OR r.status<>'RUNNING' THEN RAISE EXCEPTION 'MARKETROUTE_GROWTH_ACTION_NOT_RUNNING'; END IF; SELECT * INTO s FROM public.genesis_growth_settings WHERE singleton=true;
 IF p_actual_cost_usd<0 OR p_actual_cost_usd>s.max_action_cost_usd*2 THEN RAISE EXCEPTION 'MARKETROUTE_GROWTH_ACTION_COST_INVALID'; END IF;
 UPDATE public.genesis_growth_action_runs SET status='FAILED',actual_cost_usd=p_actual_cost_usd,error_code=left(COALESCE(p_error_code,'MARKETROUTE_GROWTH_ACTION_FAILED'),300),completed_at=p_at WHERE id=p_action_run_id;
 INSERT INTO public.genesis_growth_budget_events(action_run_id,industry_key,company_id,amount_usd,occurred_at,metadata_json) VALUES(p_action_run_id,r.industry_key,r.company_id,p_actual_cost_usd,p_at,jsonb_build_object('failed',true,'errorCode',left(COALESCE(p_error_code,''),300)));
 IF r.company_id IS NOT NULL THEN UPDATE public.genesis_growth_company_progress SET retry_after=COALESCE(p_retry_after,p_at+make_interval(hours=>s.retry_hours)),last_error_code=left(COALESCE(p_error_code,''),300),updated_at=p_at WHERE company_id=r.company_id; END IF;
END;$fn$;

CREATE OR REPLACE FUNCTION public.marketroute_record_ai_usage_v1(p_organisation_id uuid,p_campaign_id uuid,p_provider text,p_model text,p_request_kind text,p_input_tokens bigint,p_output_tokens bigint,p_cost_usd numeric,p_latency_ms integer,p_status text,p_metadata_json jsonb DEFAULT '{}'::jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_id uuid;
BEGIN
 PERFORM public.marketroute_require_service_role(); IF p_status NOT IN('SUCCEEDED','FAILED','TIMED_OUT','CANCELLED') THEN RAISE EXCEPTION 'MARKETROUTE_AI_USAGE_STATUS_INVALID'; END IF;
 INSERT INTO public.ai_usage_events(organisation_id,campaign_id,provider,model,request_kind,input_tokens,output_tokens,cost_usd,latency_ms,status,metadata_json) VALUES(p_organisation_id,p_campaign_id,left(COALESCE(p_provider,'UNKNOWN'),100),left(COALESCE(p_model,'UNKNOWN'),200),left(COALESCE(p_request_kind,'UNKNOWN'),160),greatest(0,COALESCE(p_input_tokens,0)),greatest(0,COALESCE(p_output_tokens,0)),greatest(0,COALESCE(p_cost_usd,0)),greatest(0,COALESCE(p_latency_ms,0)),p_status,COALESCE(p_metadata_json,'{}'::jsonb)) RETURNING id INTO v_id; RETURN v_id;
END;$fn$;

-- Extend founder runtime observability with the autonomous growth worker.
DO $fn$ DECLARE v_name text;BEGIN SELECT conname INTO v_name FROM pg_constraint WHERE conrelid='public.production_runtime_events'::regclass AND contype='c' AND pg_get_constraintdef(oid) ILIKE '%runtime_kind%'; IF v_name IS NOT NULL THEN EXECUTE format('ALTER TABLE public.production_runtime_events DROP CONSTRAINT %I',v_name); END IF; END;$fn$;
ALTER TABLE public.production_runtime_events ADD CONSTRAINT production_runtime_events_runtime_kind_check CHECK(runtime_kind IN ('BOOTSTRAP','GROWTH','RESEARCH','DELIVERY','PREFLIGHT','SMOKE'));
CREATE OR REPLACE FUNCTION public.marketroute_record_runtime_event_v1(p_correlation_id uuid,p_runtime_kind text,p_event_type text,p_duration_ms integer DEFAULT NULL,p_error_code text DEFAULT NULL,p_metadata_json jsonb DEFAULT '{}'::jsonb,p_at timestamptz DEFAULT now()) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_id uuid;BEGIN PERFORM public.marketroute_require_service_role();IF p_correlation_id IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_RUNTIME_CORRELATION_REQUIRED';END IF;IF p_runtime_kind NOT IN ('BOOTSTRAP','GROWTH','RESEARCH','DELIVERY','PREFLIGHT','SMOKE') THEN RAISE EXCEPTION 'MARKETROUTE_RUNTIME_KIND_INVALID';END IF;IF p_event_type NOT IN ('STARTED','SUCCEEDED','FAILED','DISABLED') THEN RAISE EXCEPTION 'MARKETROUTE_RUNTIME_EVENT_INVALID';END IF;IF p_duration_ms IS NOT NULL AND p_duration_ms<0 THEN RAISE EXCEPTION 'MARKETROUTE_RUNTIME_DURATION_INVALID';END IF;IF jsonb_typeof(COALESCE(p_metadata_json,'{}'::jsonb))<>'object' THEN RAISE EXCEPTION 'MARKETROUTE_RUNTIME_METADATA_INVALID';END IF;INSERT INTO public.production_runtime_events(correlation_id,runtime_kind,event_type,duration_ms,error_code,metadata_json,occurred_at) VALUES(p_correlation_id,p_runtime_kind,p_event_type,p_duration_ms,left(nullif(btrim(COALESCE(p_error_code,'')),''),500),COALESCE(p_metadata_json,'{}'::jsonb),COALESCE(p_at,now())) RETURNING id INTO v_id;RETURN v_id;END;$fn$;

CREATE OR REPLACE FUNCTION public.marketroute_founder_dashboard_snapshot_v1(p_at timestamptz DEFAULT now())
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE
  v_at timestamptz := COALESCE(p_at,now());
  v_day_start timestamptz := date_trunc('day',COALESCE(p_at,now()) AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
  v_24h timestamptz := COALESCE(p_at,now()) - interval '24 hours';
  v_runtime jsonb;
  v_latest_release jsonb;
BEGIN
  PERFORM public.marketroute_require_service_role();

  SELECT COALESCE(jsonb_object_agg(x.runtime_kind,jsonb_build_object(
    'eventType',x.event_type,
    'occurredAt',x.occurred_at,
    'durationMs',x.duration_ms,
    'errorCode',x.error_code,
    'metadata',x.metadata_json
  )),'{}'::jsonb) INTO v_runtime
  FROM (
    SELECT DISTINCT ON (runtime_kind) runtime_kind,event_type,occurred_at,duration_ms,error_code,metadata_json
    FROM public.production_runtime_events
    ORDER BY runtime_kind,occurred_at DESC,id DESC
  ) x;

  SELECT jsonb_build_object('releaseKey',release_key,'buildNumber',build_number,'appliedAt',applied_at)
  INTO v_latest_release
  FROM public.marketroute_schema_releases
  ORDER BY applied_at DESC LIMIT 1;

  RETURN jsonb_build_object(
    'generatedAt',v_at,
    'schemaRelease',COALESCE(v_latest_release,'{}'::jsonb),
    'runtime',COALESCE(v_runtime,'{}'::jsonb),
    'platform',jsonb_build_object(
      'organisations',(SELECT count(*) FROM public.organisations WHERE status='ACTIVE'),
      'sellerBusinesses',(SELECT count(*) FROM public.seller_businesses WHERE lifecycle_state='ACTIVE'),
      'activeCampaigns',(SELECT count(*) FROM public.campaigns WHERE workflow_state='ACTIVE'),
      'allCampaigns',(SELECT count(*) FROM public.campaigns),
      'migrationBatches',(SELECT count(*) FROM public.marketroute_v1_migration_batches),
      'migratedRecords',(SELECT count(*) FROM public.marketroute_v1_migration_id_map),
      'migrationRejections',(SELECT count(*) FROM public.marketroute_v1_migration_rejections)
    ),
    'growth',jsonb_build_object(
      'enabled',(SELECT enabled FROM public.genesis_growth_settings WHERE singleton=true),
      'phase',(CASE WHEN EXISTS(SELECT 1 FROM public.genesis_growth_industries i WHERE i.enabled AND (SELECT count(*) FROM public.genesis_growth_company_memberships m WHERE m.industry_key=i.industry_key)<i.seed_target_company_count) THEN 'SEED' WHEN EXISTS(SELECT 1 FROM public.genesis_growth_industries i WHERE i.enabled AND (SELECT count(*) FROM public.genesis_growth_company_memberships m WHERE m.industry_key=i.industry_key)<i.launch_target_company_count) THEN 'BREADTH' WHEN EXISTS(SELECT 1 FROM public.genesis_growth_company_progress p WHERE p.core_complete_at IS NULL OR p.profile_complete_at IS NULL OR p.routes_complete_at IS NULL OR p.contacts_complete_at IS NULL) THEN 'DEPTH' ELSE 'REFRESH' END),
      'targetCompanies',(SELECT COALESCE(sum(launch_target_company_count),0) FROM public.genesis_growth_industries WHERE enabled),
      'seedTargetCompanies',(SELECT COALESCE(sum(seed_target_company_count),0) FROM public.genesis_growth_industries WHERE enabled),
      'companies',(SELECT count(DISTINCT company_id) FROM public.genesis_growth_company_memberships),
      'dense80',(SELECT count(DISTINCT p.company_id) FROM public.genesis_growth_company_progress p JOIN public.genesis_growth_company_memberships m ON m.company_id=p.company_id WHERE (20 + CASE WHEN p.core_complete_at IS NOT NULL THEN 20 ELSE 0 END + CASE WHEN p.profile_complete_at IS NOT NULL THEN 20 ELSE 0 END + CASE WHEN p.routes_complete_at IS NOT NULL THEN 20 ELSE 0 END + CASE WHEN p.contacts_complete_at IS NOT NULL THEN 20 ELSE 0 END)>=80),
      'dense100',(SELECT count(DISTINCT p.company_id) FROM public.genesis_growth_company_progress p JOIN public.genesis_growth_company_memberships m ON m.company_id=p.company_id WHERE p.core_complete_at IS NOT NULL AND p.profile_complete_at IS NOT NULL AND p.routes_complete_at IS NOT NULL AND p.contacts_complete_at IS NOT NULL),
      'averageDensity',(SELECT COALESCE(round(avg(20 + CASE WHEN p.core_complete_at IS NOT NULL THEN 20 ELSE 0 END + CASE WHEN p.profile_complete_at IS NOT NULL THEN 20 ELSE 0 END + CASE WHEN p.routes_complete_at IS NOT NULL THEN 20 ELSE 0 END + CASE WHEN p.contacts_complete_at IS NOT NULL THEN 20 ELSE 0 END),1),0) FROM public.genesis_growth_company_progress p JOIN public.genesis_growth_company_memberships m ON m.company_id=p.company_id),
      'actions',(SELECT count(*) FROM public.genesis_growth_action_runs),
      'actionsSucceeded',(SELECT count(*) FROM public.genesis_growth_action_runs WHERE status='SUCCEEDED'),
      'actionsFailed',(SELECT count(*) FROM public.genesis_growth_action_runs WHERE status='FAILED'),
      'spendUsd',(SELECT COALESCE(sum(amount_usd),0) FROM public.genesis_growth_budget_events),
      'spentTodayUsd',(SELECT COALESCE(sum(amount_usd),0) FROM public.genesis_growth_budget_events WHERE occurred_at>=v_day_start),
      'dailyBudgetUsd',(SELECT daily_budget_usd FROM public.genesis_growth_settings WHERE singleton=true),
      'latestAt',(SELECT max(completed_at) FROM public.genesis_growth_action_runs),
      'nextPriorityIndustry',(SELECT i.display_name FROM public.genesis_growth_industries i WHERE i.enabled ORDER BY ((SELECT count(*) FROM public.genesis_growth_company_memberships m WHERE m.industry_key=i.industry_key)::numeric/greatest(1,i.launch_target_company_count)),i.priority DESC,i.industry_key LIMIT 1),
      'industries',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'key',q.industry_key,'name',q.display_name,'priority',q.priority,'companies',q.companies,'seedTarget',q.seed_target_company_count,'launchTarget',q.launch_target_company_count,
        'dense80',q.dense80,'dense100',q.dense100,'averageDensity',q.average_density,'people',q.people,'relationships',q.relationships
      ) ORDER BY q.priority DESC,q.display_name),'[]'::jsonb) FROM (
        SELECT i.industry_key,i.display_name,i.priority,i.seed_target_company_count,i.launch_target_company_count,
          count(DISTINCT m.company_id) companies,
          count(DISTINCT p.company_id) FILTER(WHERE (20 + CASE WHEN p.core_complete_at IS NOT NULL THEN 20 ELSE 0 END + CASE WHEN p.profile_complete_at IS NOT NULL THEN 20 ELSE 0 END + CASE WHEN p.routes_complete_at IS NOT NULL THEN 20 ELSE 0 END + CASE WHEN p.contacts_complete_at IS NOT NULL THEN 20 ELSE 0 END)>=80) dense80,
          count(DISTINCT p.company_id) FILTER(WHERE p.core_complete_at IS NOT NULL AND p.profile_complete_at IS NOT NULL AND p.routes_complete_at IS NOT NULL AND p.contacts_complete_at IS NOT NULL) dense100,
          COALESCE(round(avg(20 + CASE WHEN p.core_complete_at IS NOT NULL THEN 20 ELSE 0 END + CASE WHEN p.profile_complete_at IS NOT NULL THEN 20 ELSE 0 END + CASE WHEN p.routes_complete_at IS NOT NULL THEN 20 ELSE 0 END + CASE WHEN p.contacts_complete_at IS NOT NULL THEN 20 ELSE 0 END),1),0) average_density,
          count(DISTINCT gp.person_id) people,
          count(DISTINCT cr.id) relationships
        FROM public.genesis_growth_industries i
        LEFT JOIN public.genesis_growth_company_memberships m ON m.industry_key=i.industry_key
        LEFT JOIN public.genesis_growth_company_progress p ON p.company_id=m.company_id
        LEFT JOIN public.genesis_growth_people gp ON gp.company_id=m.company_id
        LEFT JOIN public.commercial_graph_nodes gn ON gn.node_kind='COMPANY' AND gn.company_id=m.company_id
        LEFT JOIN public.commercial_relationships cr ON cr.tenant_scope_organisation_id IS NULL AND (cr.from_node_id=gn.id OR cr.to_node_id=gn.id)
        WHERE i.enabled GROUP BY i.industry_key,i.display_name,i.priority,i.seed_target_company_count,i.launch_target_company_count
      ) q)
    ),
    'activation',jsonb_build_object(
      'total',(SELECT count(*) FROM public.workspace_activation_jobs),
      'pending',(SELECT count(*) FROM public.workspace_activation_jobs WHERE status='PENDING'),
      'running',(SELECT count(*) FROM public.workspace_activation_jobs WHERE status='RUNNING'),
      'succeeded',(SELECT count(*) FROM public.workspace_activation_jobs WHERE status='SUCCEEDED'),
      'failed',(SELECT count(*) FROM public.workspace_activation_jobs WHERE status='FAILED'),
      'needsInput',(SELECT count(*) FROM public.workspace_activation_jobs WHERE status='NEEDS_INPUT'),
      'latestAt',(SELECT max(updated_at) FROM public.workspace_activation_jobs)
    ),
    'discovery',jsonb_build_object(
      'companies',(SELECT count(*) FROM public.companies),
      'scopedCompanies',(SELECT count(DISTINCT company_id) FROM public.organisation_company_scopes WHERE scope_kind='CAMPAIGN'),
      'people',(SELECT count(*) FROM public.people),
      'latestCompanyAt',(SELECT max(created_at) FROM public.companies),
      'latestPersonAt',(SELECT max(created_at) FROM public.people)
    ),
    'research',jsonb_build_object(
      'plans',(SELECT count(*) FROM public.research_plan_runs),
      'workUnits',(SELECT count(*) FROM public.research_work_units),
      'pending',(SELECT count(*) FROM public.background_jobs WHERE job_type='GENESIS_RESEARCH_V1' AND status IN ('PENDING','DEFERRED')),
      'running',(SELECT count(*) FROM public.background_jobs WHERE job_type='GENESIS_RESEARCH_V1' AND status IN ('RESERVED','RUNNING')),
      'succeeded',(SELECT count(*) FROM public.background_jobs WHERE job_type='GENESIS_RESEARCH_V1' AND status='SUCCEEDED'),
      'failed',(SELECT count(*) FROM public.background_jobs WHERE job_type='GENESIS_RESEARCH_V1' AND status='FAILED'),
      'dailyBudgetUsd',(SELECT COALESCE(sum(daily_budget_usd),0) FROM public.research_budget_policies WHERE enabled),
      'spentUsd',(SELECT COALESCE(sum(amount_usd),0) FROM public.research_budget_events WHERE event_type='COMMIT'),
      'spentTodayUsd',(SELECT COALESCE(sum(amount_usd),0) FROM public.research_budget_events WHERE event_type='COMMIT' AND occurred_at>=v_day_start),
      'latestPlanAt',(SELECT max(created_at) FROM public.research_plan_runs),
      'latestWorkAt',(SELECT max(updated_at) FROM public.background_jobs WHERE job_type='GENESIS_RESEARCH_V1'),
      'latestScheduler',(
        SELECT COALESCE(jsonb_build_object('status',status,'startedAt',started_at,'completedAt',completed_at,'metadata',metadata_json),'{}'::jsonb)
        FROM public.scheduler_runs WHERE runner_key='GENESIS_RESEARCH_V1' ORDER BY started_at DESC LIMIT 1
      )
    ),
    'evidence',jsonb_build_object(
      'sources',(SELECT count(*) FROM public.source_records),
      'acquisitions',(SELECT count(*) FROM public.source_acquisitions),
      'items',(SELECT count(*) FROM public.evidence_items),
      'claims',(SELECT count(*) FROM public.claims),
      'links',(SELECT count(*) FROM public.claim_evidence_links),
      'latestAt',(SELECT max(created_at) FROM public.evidence_items)
    ),
    'truth',jsonb_build_object(
      'claimSnapshots',(SELECT count(*) FROM public.truth_claim_snapshots),
      'entitySnapshots',(SELECT count(*) FROM public.truth_entity_snapshots),
      'researchedCompanies',(SELECT count(DISTINCT subject_id) FROM public.truth_entity_snapshots WHERE subject_type='COMPANY'),
      'knownOrSupportedCompanies',(SELECT count(DISTINCT subject_id) FROM public.truth_entity_snapshots WHERE subject_type='COMPANY' AND entity_state IN ('KNOWN','SUPPORTED')),
      'latestAt',(SELECT max(created_at) FROM public.truth_entity_snapshots)
    ),
    'r4',jsonb_build_object(
      'records',(SELECT count(*) FROM public.commercial_reality_r4_records),
      'companies',(SELECT count(DISTINCT company_id) FROM public.commercial_reality_r4_records),
      'candidates',(SELECT count(DISTINCT company_id) FROM public.commercial_reality_r4_records WHERE decision_code='COMMERCIAL_CANDIDATE'),
      'researchRequired',(SELECT count(DISTINCT company_id) FROM public.commercial_reality_r4_records WHERE decision_code='RESEARCH_REQUIRED'),
      'notAdmissible',(SELECT count(DISTINCT company_id) FROM public.commercial_reality_r4_records WHERE decision_code='NOT_ADMISSIBLE'),
      'latestAt',(SELECT max(created_at) FROM public.commercial_reality_r4_records)
    ),
    'r5',jsonb_build_object(
      'records',(SELECT count(*) FROM public.route_authority_r5_records),
      'relationships',(SELECT count(*) FROM public.commercial_relationships),
      'graphNodes',(SELECT count(*) FROM public.commercial_graph_nodes),
      'reachableCompanies',(SELECT count(DISTINCT company_id) FROM public.route_authority_r5_records WHERE decision_code='ROUTE_STRUCTURALLY_OPEN'),
      'researchRequired',(SELECT count(DISTINCT company_id) FROM public.route_authority_r5_records WHERE decision_code='ROUTE_RESEARCH_REQUIRED'),
      'latestAt',(SELECT max(created_at) FROM public.route_authority_r5_records)
    ),
    'r6',jsonb_build_object(
      'records',(SELECT count(*) FROM public.contact_authority_r6_records),
      'contactQualifiedCompanies',(SELECT count(DISTINCT company_id) FROM public.contact_authority_r6_records WHERE decision_code='CONTACT_AUTHORISED'),
      'authorisedAccessPoints',(SELECT COALESCE(sum(distinct_authorised_access_point_count),0) FROM public.contact_authority_r6_records WHERE decision_code='CONTACT_AUTHORISED'),
      'researchRequired',(SELECT count(DISTINCT company_id) FROM public.contact_authority_r6_records WHERE decision_code='CONTACT_RESEARCH_REQUIRED'),
      'latestAt',(SELECT max(created_at) FROM public.contact_authority_r6_records)
    ),
    'opportunity',jsonb_build_object(
      'total',(SELECT count(*) FROM public.opportunities WHERE workflow_state<>'ARCHIVED'),
      'researching',(SELECT count(*) FROM public.opportunities WHERE workflow_state='RESEARCHING'),
      'reviewable',(SELECT count(*) FROM public.opportunities WHERE workflow_state='REVIEWABLE'),
      'approved',(SELECT count(*) FROM public.opportunities WHERE workflow_state='APPROVED'),
      'engaged',(SELECT count(*) FROM public.opportunities WHERE workflow_state='ENGAGED'),
      'rejected',(SELECT count(*) FROM public.opportunities WHERE workflow_state='REJECTED'),
      'syncEvents',(SELECT count(*) FROM public.opportunity_sync_events),
      'latestAt',(SELECT max(updated_at) FROM public.opportunities)
    ),
    'engagement',jsonb_build_object(
      'strategies',(SELECT count(*) FROM public.engagement_strategies),
      'messages',(SELECT count(*) FROM public.engagement_messages),
      'reviews',(SELECT count(*) FROM public.engagement_ai_reviews),
      'reviewPass',(SELECT count(*) FROM public.engagement_ai_reviews WHERE verdict='PASS'),
      'reviewRewrite',(SELECT count(*) FROM public.engagement_ai_reviews WHERE verdict='REWRITE'),
      'reviewBlock',(SELECT count(*) FROM public.engagement_ai_reviews WHERE verdict='BLOCK'),
      'approvals',(SELECT count(*) FROM public.engagement_message_approvals WHERE decision='APPROVE'),
      'queued',(SELECT count(*) FROM public.engagement_queue_items),
      'deliveryPending',(SELECT count(*) FROM public.engagement_delivery_jobs WHERE status='PENDING'),
      'deliverySent',(SELECT count(*) FROM public.engagement_delivery_jobs WHERE status='SENT'),
      'deliveryFailed',(SELECT count(*) FROM public.engagement_delivery_jobs WHERE status='FAILED'),
      'deliveryBlockedStale',(SELECT count(*) FROM public.engagement_delivery_jobs WHERE status='BLOCKED_STALE'),
      'deliveryReconciliation',(SELECT count(*) FROM public.engagement_delivery_jobs WHERE status='RECONCILIATION_REQUIRED'),
      'latestAt',(SELECT max(created_at) FROM public.engagement_messages)
    ),
    'ai',jsonb_build_object(
      'requests',(SELECT count(*) FROM public.ai_usage_events),
      'requests24h',(SELECT count(*) FROM public.ai_usage_events WHERE created_at>=v_24h),
      'success24h',(SELECT count(*) FROM public.ai_usage_events WHERE created_at>=v_24h AND status='SUCCEEDED'),
      'failed24h',(SELECT count(*) FROM public.ai_usage_events WHERE created_at>=v_24h AND status IN ('FAILED','TIMED_OUT','CANCELLED')),
      'inputTokens',(SELECT COALESCE(sum(input_tokens),0) FROM public.ai_usage_events),
      'outputTokens',(SELECT COALESCE(sum(output_tokens),0) FROM public.ai_usage_events),
      'spendUsd',(SELECT COALESCE(sum(cost_usd),0) FROM public.ai_usage_events),
      'spend24hUsd',(SELECT COALESCE(sum(cost_usd),0) FROM public.ai_usage_events WHERE created_at>=v_24h),
      'latestAt',(SELECT max(created_at) FROM public.ai_usage_events),
      'latestModel',(SELECT model FROM public.ai_usage_events ORDER BY created_at DESC,id DESC LIMIT 1)
    )
  );
END;$fn$;
REVOKE ALL ON FUNCTION public.marketroute_founder_dashboard_snapshot_v1(timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_founder_dashboard_snapshot_v1(timestamptz) TO service_role;

REVOKE ALL ON FUNCTION public.marketroute_sync_growth_settings_v1(boolean,integer,integer,numeric,numeric,integer,integer,integer,integer) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_start_growth_scheduler_run_v1(timestamptz),public.marketroute_heartbeat_growth_scheduler_run_v1(uuid,timestamptz),public.marketroute_finish_growth_scheduler_run_v1(uuid,text,jsonb,timestamptz),public.marketroute_growth_existing_domains_v1(text,integer),public.marketroute_growth_ensure_company_v1(text,text,text,text,text,text),public.marketroute_growth_ensure_person_v1(uuid,text),public.marketroute_growth_mark_stage_v1(uuid,text,boolean,text,timestamptz,timestamptz),public.marketroute_growth_next_action_v1(uuid,timestamptz),public.marketroute_growth_complete_action_v1(uuid,numeric,jsonb,timestamptz),public.marketroute_growth_fail_action_v1(uuid,text,numeric,timestamptz,timestamptz),public.marketroute_record_ai_usage_v1(uuid,uuid,text,text,text,bigint,bigint,numeric,integer,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_sync_growth_settings_v1(boolean,integer,integer,numeric,numeric,integer,integer,integer,integer),public.marketroute_start_growth_scheduler_run_v1(timestamptz),public.marketroute_heartbeat_growth_scheduler_run_v1(uuid,timestamptz),public.marketroute_finish_growth_scheduler_run_v1(uuid,text,jsonb,timestamptz),public.marketroute_growth_existing_domains_v1(text,integer),public.marketroute_growth_ensure_company_v1(text,text,text,text,text,text),public.marketroute_growth_ensure_person_v1(uuid,text),public.marketroute_growth_mark_stage_v1(uuid,text,boolean,text,timestamptz,timestamptz),public.marketroute_growth_next_action_v1(uuid,timestamptz),public.marketroute_growth_complete_action_v1(uuid,numeric,jsonb,timestamptz),public.marketroute_growth_fail_action_v1(uuid,text,numeric,timestamptz,timestamptz),public.marketroute_record_ai_usage_v1(uuid,uuid,text,text,text,bigint,bigint,numeric,integer,text,jsonb) TO service_role;

INSERT INTO public.marketroute_schema_releases(release_key,build_number,constitution_version,metadata_json)
VALUES('MARKETROUTE_V2_GENESIS_DATABASE_GROWTH_0_18_3',18,'MRV2-CONSTITUTION-1.0.0',jsonb_build_object(
 'migration','0022_genesis_database_growth.sql','new_authority_writer',false,'global_evidence_bank',true,'canonical_industries',10,'seed_target_per_industry',50,'launch_target_per_industry',500,'growth_planner','DETERMINISTIC','ai_creates_authority',false
)) ON CONFLICT(release_key) DO NOTHING;

NOTIFY pgrst,'reload schema';
COMMIT;
