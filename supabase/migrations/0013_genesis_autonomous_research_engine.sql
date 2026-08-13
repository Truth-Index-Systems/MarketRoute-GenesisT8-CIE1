BEGIN;

-- MarketRoute V2 Build 10: Genesis Autonomous Research Engine.
-- Research produces evidence/revalidation work only. It is not an authority writer.

CREATE TABLE public.research_budget_policies (
  organisation_id uuid NOT NULL REFERENCES public.organisations(id) ON DELETE CASCADE,
  campaign_id uuid NOT NULL,
  daily_budget_usd numeric(18,8) NOT NULL CHECK (daily_budget_usd >= 0 AND daily_budget_usd <= 100000),
  max_job_cost_usd numeric(18,8) NOT NULL CHECK (max_job_cost_usd >= 0 AND max_job_cost_usd <= daily_budget_usd),
  max_concurrent_jobs integer NOT NULL CHECK (max_concurrent_jobs BETWEEN 0 AND 100),
  max_work_units_per_plan integer NOT NULL CHECK (max_work_units_per_plan BETWEEN 0 AND 100),
  refresh_horizon_hours integer NOT NULL CHECK (refresh_horizon_hours BETWEEN 0 AND 168),
  enabled boolean NOT NULL DEFAULT true,
  policy_version text NOT NULL DEFAULT 'MRV2-RESEARCH-BUDGET-1.0.0',
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (organisation_id,campaign_id),
  CONSTRAINT research_budget_policies_campaign_scope_fk FOREIGN KEY(organisation_id,campaign_id) REFERENCES public.campaigns(organisation_id,id) ON DELETE CASCADE
);

CREATE TABLE public.research_plan_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organisation_id uuid NOT NULL REFERENCES public.organisations(id) ON DELETE RESTRICT,
  campaign_id uuid NOT NULL,
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  reference_time timestamptz NOT NULL,
  lifecycle_state text NOT NULL,
  authority_envelope_fingerprint text NOT NULL CHECK(authority_envelope_fingerprint ~ '^[a-f0-9]{64}$'),
  planner_version text NOT NULL,
  semantics_version text NOT NULL,
  gap_set_fingerprint text NOT NULL CHECK(gap_set_fingerprint ~ '^[a-f0-9]{64}$'),
  gap_context_json jsonb NOT NULL CHECK(jsonb_typeof(gap_context_json)='object'),
  work_units_json jsonb NOT NULL CHECK(jsonb_typeof(work_units_json)='array'),
  budget_policy_snapshot_json jsonb NOT NULL CHECK(jsonb_typeof(budget_policy_snapshot_json)='object'),
  budget_snapshot_json jsonb NOT NULL CHECK(jsonb_typeof(budget_snapshot_json)='object'),
  plan_fingerprint text NOT NULL UNIQUE CHECK(plan_fingerprint ~ '^[a-f0-9]{64}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT research_plan_runs_campaign_scope_fk FOREIGN KEY(organisation_id,campaign_id) REFERENCES public.campaigns(organisation_id,id) ON DELETE RESTRICT
);

CREATE TABLE public.research_work_units (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_id uuid NOT NULL REFERENCES public.research_plan_runs(id) ON DELETE RESTRICT,
  organisation_id uuid NOT NULL REFERENCES public.organisations(id) ON DELETE RESTRICT,
  campaign_id uuid NOT NULL,
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  ordinal integer NOT NULL CHECK(ordinal > 0),
  gap_key text NOT NULL,
  layer text NOT NULL CHECK(layer IN ('R4','R5','R6')),
  tier text NOT NULL CHECK(tier IN ('DECISION_BLOCKER','CURRENTNESS_REPAIR','EXPIRING_SOON','ENRICHMENT')),
  action text NOT NULL CHECK(action IN ('ACQUIRE_CLAIM_EVIDENCE','DISCOVER_ROUTE_STRUCTURE','RESEARCH_CONTACT_BINDING','REVALIDATE_R4','REVALIDATE_R5','REVALIDATE_R6')),
  subject_type text NOT NULL CHECK(subject_type IN ('COMPANY','PERSON','RELATIONSHIP','CHANNEL','CAMPAIGN')),
  subject_id text NOT NULL,
  claim_key text,
  reason_code text NOT NULL,
  query_hints_json jsonb NOT NULL CHECK(jsonb_typeof(query_hints_json)='array'),
  payload_json jsonb NOT NULL CHECK(jsonb_typeof(payload_json)='object'),
  cost_ceiling_usd numeric(18,8) NOT NULL CHECK(cost_ceiling_usd >= 0),
  dedupe_key text NOT NULL UNIQUE CHECK(dedupe_key ~ '^[a-f0-9]{64}$'),
  background_job_id uuid UNIQUE REFERENCES public.background_jobs(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(plan_id,ordinal),
  UNIQUE(plan_id,gap_key),
  CONSTRAINT research_work_units_campaign_scope_fk FOREIGN KEY(organisation_id,campaign_id) REFERENCES public.campaigns(organisation_id,id) ON DELETE RESTRICT
);

CREATE TABLE public.research_budget_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organisation_id uuid NOT NULL REFERENCES public.organisations(id) ON DELETE RESTRICT,
  campaign_id uuid NOT NULL,
  work_unit_id uuid NOT NULL REFERENCES public.research_work_units(id) ON DELETE RESTRICT,
  scheduler_run_id uuid REFERENCES public.scheduler_runs(id) ON DELETE SET NULL,
  attempt_number integer NOT NULL CHECK(attempt_number > 0),
  event_type text NOT NULL CHECK(event_type IN ('RESERVE','COMMIT','RELEASE')),
  amount_usd numeric(18,8) NOT NULL CHECK(amount_usd >= 0),
  occurred_at timestamptz NOT NULL DEFAULT now(),
  metadata_json jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(metadata_json)='object'),
  UNIQUE(work_unit_id,attempt_number,event_type),
  CONSTRAINT research_budget_events_campaign_scope_fk FOREIGN KEY(organisation_id,campaign_id) REFERENCES public.campaigns(organisation_id,id) ON DELETE RESTRICT
);

CREATE INDEX research_plan_scope_idx ON public.research_plan_runs(organisation_id,campaign_id,company_id,created_at DESC);
CREATE INDEX research_work_queue_idx ON public.research_work_units(organisation_id,campaign_id,created_at,id);
CREATE INDEX research_budget_day_idx ON public.research_budget_events(organisation_id,campaign_id,occurred_at,event_type);

CREATE TRIGGER research_plan_runs_append_only BEFORE UPDATE OR DELETE ON public.research_plan_runs FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();
CREATE TRIGGER research_work_units_append_only BEFORE UPDATE OR DELETE ON public.research_work_units FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();
CREATE TRIGGER research_budget_events_append_only BEFORE UPDATE OR DELETE ON public.research_budget_events FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

ALTER TABLE public.research_budget_policies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.research_plan_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.research_work_units ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.research_budget_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.research_budget_policies,public.research_plan_runs,public.research_work_units,public.research_budget_events FROM anon,authenticated,service_role;
GRANT SELECT ON public.research_budget_policies,public.research_plan_runs,public.research_work_units,public.research_budget_events TO service_role;

CREATE OR REPLACE FUNCTION public.marketroute_research_policy_v1(p_organisation_id uuid,p_campaign_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
 SELECT COALESCE((SELECT jsonb_build_object('dailyBudgetUsd',daily_budget_usd,'maxJobCostUsd',max_job_cost_usd,'maxConcurrentJobs',max_concurrent_jobs,'maxWorkUnitsPerPlan',max_work_units_per_plan,'refreshHorizonHours',refresh_horizon_hours,'enabled',enabled,'policyVersion',policy_version) FROM public.research_budget_policies WHERE organisation_id=p_organisation_id AND campaign_id=p_campaign_id),
 jsonb_build_object('dailyBudgetUsd',5.00000000,'maxJobCostUsd',0.50000000,'maxConcurrentJobs',2,'maxWorkUnitsPerPlan',4,'refreshHorizonHours',2,'enabled',true,'policyVersion','MRV2-RESEARCH-BUDGET-1.0.0'));
$$;

CREATE OR REPLACE FUNCTION public.marketroute_set_research_policy_v1(p_organisation_id uuid,p_campaign_id uuid,p_daily_budget_usd numeric,p_max_job_cost_usd numeric,p_max_concurrent_jobs integer,p_max_work_units_per_plan integer,p_refresh_horizon_hours integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.campaigns WHERE id=p_campaign_id AND organisation_id=p_organisation_id) THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_POLICY_SCOPE_MISMATCH'; END IF;
 IF p_daily_budget_usd<0 OR p_daily_budget_usd>100000 OR p_max_job_cost_usd<0 OR p_max_job_cost_usd>p_daily_budget_usd OR p_max_concurrent_jobs<0 OR p_max_concurrent_jobs>100 OR p_max_work_units_per_plan<0 OR p_max_work_units_per_plan>100 OR p_refresh_horizon_hours<0 OR p_refresh_horizon_hours>168 THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_POLICY_INVALID'; END IF;
 INSERT INTO public.research_budget_policies(organisation_id,campaign_id,daily_budget_usd,max_job_cost_usd,max_concurrent_jobs,max_work_units_per_plan,refresh_horizon_hours,enabled,updated_at)
 VALUES(p_organisation_id,p_campaign_id,p_daily_budget_usd,p_max_job_cost_usd,p_max_concurrent_jobs,p_max_work_units_per_plan,p_refresh_horizon_hours,true,now())
 ON CONFLICT(organisation_id,campaign_id) DO UPDATE SET daily_budget_usd=EXCLUDED.daily_budget_usd,max_job_cost_usd=EXCLUDED.max_job_cost_usd,max_concurrent_jobs=EXCLUDED.max_concurrent_jobs,max_work_units_per_plan=EXCLUDED.max_work_units_per_plan,refresh_horizon_hours=EXCLUDED.refresh_horizon_hours,enabled=true,updated_at=now();
 RETURN public.marketroute_research_policy_v1(p_organisation_id,p_campaign_id);
END $$;

CREATE OR REPLACE FUNCTION public.marketroute_research_budget_snapshot_v1(p_organisation_id uuid,p_campaign_id uuid,p_at timestamptz DEFAULT now())
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
 WITH day_bounds AS (SELECT date_trunc('day',p_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AS d0),
 committed AS (SELECT COALESCE(sum(e.amount_usd),0) v FROM public.research_budget_events e,day_bounds d WHERE e.organisation_id=p_organisation_id AND e.campaign_id=p_campaign_id AND e.event_type='COMMIT' AND e.occurred_at>=d.d0 AND e.occurred_at<d.d0+interval '1 day'),
 active_reserved AS (SELECT COALESCE(sum(r.amount_usd),0) v FROM public.research_budget_events r,day_bounds d WHERE r.organisation_id=p_organisation_id AND r.campaign_id=p_campaign_id AND r.event_type='RESERVE' AND r.occurred_at>=d.d0 AND r.occurred_at<d.d0+interval '1 day' AND NOT EXISTS(SELECT 1 FROM public.research_budget_events x WHERE x.work_unit_id=r.work_unit_id AND x.attempt_number=r.attempt_number AND x.event_type IN('COMMIT','RELEASE'))),
 active_jobs AS (SELECT count(*)::int v FROM public.research_work_units w JOIN public.background_jobs j ON j.id=w.background_job_id WHERE w.organisation_id=p_organisation_id AND w.campaign_id=p_campaign_id AND j.status IN('RESERVED','RUNNING'))
 SELECT jsonb_build_object('spentTodayUsd',(SELECT v FROM committed),'reservedTodayUsd',(SELECT v FROM active_reserved),'activeJobs',(SELECT v FROM active_jobs));
$$;

CREATE OR REPLACE FUNCTION public.marketroute_research_gap_context_v1(p_organisation_id uuid,p_campaign_id uuid,p_company_id uuid,p_at timestamptz DEFAULT now())
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_env jsonb; v_env_fp text; v_gap_fp text; v_state text; v_candidates jsonb:='[]'::jsonb; v_policy jsonb; v_budget jsonb; v_r4 public.commercial_reality_r4_records%ROWTYPE; v_r5 public.route_authority_r5_records%ROWTYPE; v_r6 public.contact_authority_r6_records%ROWTYPE; v_gap jsonb; v_item jsonb; v_i int:=0; v_earliest_layer text; v_earliest timestamptz; v_t timestamptz;
BEGIN
 v_env:=public.marketroute_authority_envelope_v1(p_organisation_id,p_campaign_id,p_company_id,p_at); v_env_fp:=public.marketroute_authority_envelope_fingerprint_v1(v_env); v_state:=v_env->>'lifecycleState'; v_policy:=public.marketroute_research_policy_v1(p_organisation_id,p_campaign_id); v_budget:=public.marketroute_research_budget_snapshot_v1(p_organisation_id,p_campaign_id,p_at);
 IF COALESCE((v_policy->>'enabled')::boolean,true)=false THEN RETURN jsonb_build_object('organisationId',p_organisation_id,'campaignId',p_campaign_id,'companyId',p_company_id,'referenceTime',p_at,'lifecycleState',v_state,'authorityEnvelopeFingerprint',v_env_fp,'gapSetFingerprint',encode(extensions.digest('MRV2-RESEARCH-GAP-SET-1.0.0|'||('[]'::jsonb)::text,'sha256'),'hex'),'candidates','[]'::jsonb,'policy',v_policy,'budget',v_budget); END IF;
 IF v_state='R4_REVALIDATION_REQUIRED' THEN
   v_candidates:=v_candidates||jsonb_build_array(jsonb_build_object('gapKey','r4:revalidate','layer','R4','tier','CURRENTNESS_REPAIR','action','REVALIDATE_R4','subjectType','COMPANY','subjectId',p_company_id::text,'claimKey',NULL,'reasonCode','CURRENT_R4_REQUIRED','queryHints','[]'::jsonb,'metadata','{}'::jsonb));
 ELSIF v_state='COMMERCIAL_RESEARCH_REQUIRED' THEN
   SELECT r.* INTO v_r4 FROM public.commercial_reality_r4_records r WHERE r.organisation_id=p_organisation_id AND r.campaign_id=p_campaign_id AND r.company_id=p_company_id AND public.marketroute_r4_authority_current_v1(r.authority_record_id,p_at) ORDER BY r.created_at DESC,r.id DESC LIMIT 1;
   FOR v_item IN SELECT value FROM jsonb_array_elements(COALESCE(v_r4.boundaries_json,'[]'::jsonb)) x(value) WHERE value->>'state' IN('UNRESOLVED','CONTRADICTED','STALE') ORDER BY value->>'boundaryKey' LOOP
     v_candidates:=v_candidates||jsonb_build_array(jsonb_build_object('gapKey','r4:'||(v_item->>'boundaryKey'),'layer','R4','tier','DECISION_BLOCKER','action','ACQUIRE_CLAIM_EVIDENCE','subjectType','COMPANY','subjectId',p_company_id::text,'claimKey',v_item->>'claimKey','reasonCode',v_item->>'reasonCode','queryHints',CASE WHEN v_item->>'claimKey' IS NULL THEN '[]'::jsonb ELSE jsonb_build_array(v_item->>'claimKey') END,'metadata',jsonb_build_object('boundaryKey',v_item->>'boundaryKey','boundaryState',v_item->>'state')));
   END LOOP;
 ELSIF v_state='R5_REVALIDATION_REQUIRED' THEN
   v_candidates:=v_candidates||jsonb_build_array(jsonb_build_object('gapKey','r5:revalidate','layer','R5','tier','CURRENTNESS_REPAIR','action','REVALIDATE_R5','subjectType','COMPANY','subjectId',p_company_id::text,'claimKey',NULL,'reasonCode','CURRENT_R5_REQUIRED','queryHints','[]'::jsonb,'metadata','{}'::jsonb));
 ELSIF v_state='ROUTE_RESEARCH_REQUIRED' THEN
   v_candidates:=v_candidates||jsonb_build_array(jsonb_build_object('gapKey','r5:discover-route','layer','R5','tier','DECISION_BLOCKER','action','DISCOVER_ROUTE_STRUCTURE','subjectType','COMPANY','subjectId',p_company_id::text,'claimKey',NULL,'reasonCode','STRUCTURAL_ROUTE_EVIDENCE_REQUIRED','queryHints',jsonb_build_array('contact','team','department','leadership','email','contact form'),'metadata','{}'::jsonb));
 ELSIF v_state='R6_REVALIDATION_REQUIRED' THEN
   v_candidates:=v_candidates||jsonb_build_array(jsonb_build_object('gapKey','r6:revalidate','layer','R6','tier','CURRENTNESS_REPAIR','action','REVALIDATE_R6','subjectType','COMPANY','subjectId',p_company_id::text,'claimKey',NULL,'reasonCode','CURRENT_R6_REQUIRED','queryHints','[]'::jsonb,'metadata','{}'::jsonb));
 ELSIF v_state='CONTACT_RESEARCH_REQUIRED' THEN
   SELECT r.* INTO v_r6 FROM public.contact_authority_r6_records r WHERE r.organisation_id=p_organisation_id AND r.campaign_id=p_campaign_id AND r.company_id=p_company_id AND public.marketroute_r6_authority_current_v1(r.authority_record_id,p_at) ORDER BY r.created_at DESC,r.id DESC LIMIT 1;
   FOR v_item IN SELECT value FROM jsonb_array_elements(COALESCE(v_r6.bindings_json,'[]'::jsonb)) x(value) WHERE value->>'authorityState'='CONTACT_TRUTH_REQUIRED' ORDER BY value->>'pathFingerprint' LOOP
     v_candidates:=v_candidates||jsonb_build_array(jsonb_build_object('gapKey','r6:'||(v_item->>'pathFingerprint'),'layer','R6','tier','DECISION_BLOCKER','action','RESEARCH_CONTACT_BINDING','subjectType','CHANNEL','subjectId',v_item->>'terminalAccessPointId','claimKey',NULL,'reasonCode',v_item->>'reasonCode','queryHints',jsonb_build_array('identity','current employment','current role','channel ownership'),'metadata',jsonb_build_object('pathFingerprint',v_item->>'pathFingerprint','personId',v_item->>'personId','employerCompanyId',v_item->>'employerCompanyId')));
   END LOOP;
 ELSIF v_state='AUTHORITY_READY' AND COALESCE((v_policy->>'refreshHorizonHours')::int,0)>0 THEN
   FOREACH v_earliest_layer IN ARRAY ARRAY['R4','R5','R6'] LOOP
     v_t:=CASE v_earliest_layer WHEN 'R4' THEN NULLIF(v_env->'r4'->>'validUntil','')::timestamptz WHEN 'R5' THEN NULLIF(v_env->'r5'->>'validUntil','')::timestamptz ELSE NULLIF(v_env->'r6'->>'validUntil','')::timestamptz END;
     IF v_t IS NOT NULL AND v_t<=p_at+make_interval(hours=>((v_policy->>'refreshHorizonHours')::int)) AND (v_earliest IS NULL OR v_t<v_earliest) THEN v_earliest:=v_t; END IF;
   END LOOP;
   IF v_earliest IS NOT NULL THEN
     IF NULLIF(v_env->'r4'->>'validUntil','')::timestamptz=v_earliest THEN v_earliest_layer:='R4';
     ELSIF NULLIF(v_env->'r5'->>'validUntil','')::timestamptz=v_earliest THEN v_earliest_layer:='R5'; ELSE v_earliest_layer:='R6'; END IF;
     v_candidates:=v_candidates||jsonb_build_array(jsonb_build_object('gapKey',lower(v_earliest_layer)||':expiring','layer',v_earliest_layer,'tier','EXPIRING_SOON','action','REVALIDATE_'||v_earliest_layer,'subjectType','COMPANY','subjectId',p_company_id::text,'claimKey',NULL,'reasonCode','AUTHORITY_EXPIRING_SOON','queryHints','[]'::jsonb,'metadata',jsonb_build_object('validUntil',v_earliest)));
   END IF;
 END IF;
 SELECT COALESCE(jsonb_agg(x.value ORDER BY x.ord),'[]'::jsonb) INTO v_candidates
 FROM jsonb_array_elements(v_candidates) WITH ORDINALITY x(value,ord)
 WHERE NOT EXISTS (
   SELECT 1 FROM public.research_work_units w JOIN public.background_jobs j ON j.id=w.background_job_id
   WHERE w.organisation_id=p_organisation_id AND w.campaign_id=p_campaign_id AND w.company_id=p_company_id
     AND w.gap_key=x.value->>'gapKey' AND w.action=x.value->>'action'
     AND j.status IN('PENDING','DEFERRED','RESERVED','RUNNING','SUCCEEDED','FAILED')
     AND w.created_at > p_at - interval '6 hours'
 );
 v_gap_fp:=encode(extensions.digest('MRV2-RESEARCH-GAP-SET-1.0.0|'||v_candidates::text,'sha256'),'hex');
 RETURN jsonb_build_object('organisationId',p_organisation_id,'campaignId',p_campaign_id,'companyId',p_company_id,'referenceTime',p_at,'lifecycleState',v_state,'authorityEnvelopeFingerprint',v_env_fp,'gapSetFingerprint',v_gap_fp,'candidates',v_candidates,'policy',v_policy-'enabled'-'policyVersion','budget',v_budget);
END $$;

CREATE OR REPLACE FUNCTION public.marketroute_persist_research_plan_v1(p_context jsonb,p_planner_version text,p_semantics_version text,p_gap_set_fingerprint text,p_work_units jsonb)
RETURNS TABLE(plan_id uuid,created_work_units integer,plan_fingerprint text,deduplicated boolean) LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_expected jsonb; v_policy jsonb; v_budget jsonb; v_plan uuid; v_existing public.research_plan_runs%ROWTYPE; v_item jsonb; v_candidate jsonb; v_count int:=0; v_expected_fp text; v_gap_fp text; v_sum numeric:=0; v_expected_count int; v_expected_ceiling numeric; v_expected_dedupe text; v_max_units int; v_slots int; v_daily numeric; v_job numeric; v_spent numeric; v_reserved numeric; v_active int; v_job_id uuid; v_work_id uuid; v_ord int:=0; v_remaining_plan numeric;
BEGIN
 IF p_planner_version<>'MRV2-RESEARCH-PLANNER-1.0.0' OR p_semantics_version<>'MRV2-RESEARCH-SEMANTICS-1.0.0' THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_VERSION_MISMATCH'; END IF;
 IF jsonb_typeof(p_context)<>'object' OR jsonb_typeof(p_work_units)<>'array' THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_PLAN_PAYLOAD_INVALID'; END IF;
 IF abs(extract(epoch from (((p_context->>'referenceTime')::timestamptz)-now())))>300 THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_PLAN_REFERENCE_TIME_NOT_CURRENT'; END IF;
 v_expected:=public.marketroute_research_gap_context_v1((p_context->>'organisationId')::uuid,(p_context->>'campaignId')::uuid,(p_context->>'companyId')::uuid,(p_context->>'referenceTime')::timestamptz);
 IF v_expected<>p_context THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_CONTEXT_STALE_OR_TAMPERED'; END IF;
 v_gap_fp:=v_expected->>'gapSetFingerprint';
 IF v_gap_fp<>p_gap_set_fingerprint THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_GAP_FINGERPRINT_MISMATCH'; END IF;
 v_policy:=v_expected->'policy'; v_budget:=v_expected->'budget'; v_daily:=(v_policy->>'dailyBudgetUsd')::numeric; v_job:=(v_policy->>'maxJobCostUsd')::numeric; v_spent:=(v_budget->>'spentTodayUsd')::numeric; v_reserved:=(v_budget->>'reservedTodayUsd')::numeric; v_active:=(v_budget->>'activeJobs')::int; v_slots:=greatest(0,(v_policy->>'maxConcurrentJobs')::int-v_active); v_max_units:=least((v_policy->>'maxWorkUnitsPerPlan')::int,v_slots);
 IF jsonb_array_length(p_work_units)>v_max_units THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_CONCURRENCY_OR_PLAN_LIMIT_EXCEEDED'; END IF;
 v_expected_count:=0; v_remaining_plan:=greatest(0,v_daily-v_spent-v_reserved);
 FOR v_candidate IN SELECT value FROM jsonb_array_elements(v_expected->'candidates') WITH ORDINALITY x(value,ord) ORDER BY ord LOOP
   EXIT WHEN v_expected_count>=v_max_units;
   IF v_candidate->>'action' IN('REVALIDATE_R4','REVALIDATE_R5','REVALIDATE_R6') THEN v_expected_count:=v_expected_count+1;
   ELSIF v_remaining_plan>0 AND v_job>0 THEN v_expected_count:=v_expected_count+1; v_remaining_plan:=greatest(0,v_remaining_plan-least(v_job,v_remaining_plan));
   ELSE EXIT; END IF;
 END LOOP;
 IF jsonb_array_length(p_work_units)<>v_expected_count THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_REQUIRED_WORK_SET_INCOMPLETE'; END IF;
 FOR v_item IN SELECT value FROM jsonb_array_elements(p_work_units) x(value) ORDER BY (value->>'ordinal')::int LOOP
   v_ord:=v_ord+1; IF (v_item->>'ordinal')::int<>v_ord THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_WORK_ORDER_INVALID'; END IF;
   SELECT value INTO v_candidate FROM jsonb_array_elements(v_expected->'candidates') WITH ORDINALITY x(value,ord) WHERE ord=v_ord; IF v_candidate IS NULL OR v_candidate->>'gapKey'<>v_item->>'gapKey' THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_WORK_GAP_NOT_CURRENT_OR_REORDERED'; END IF;
   IF v_item->>'layer'<>v_candidate->>'layer' OR v_item->>'tier'<>v_candidate->>'tier' OR v_item->>'action'<>v_candidate->>'action' OR v_item->>'subjectType'<>v_candidate->>'subjectType' OR v_item->>'subjectId'<>v_candidate->>'subjectId' OR COALESCE(v_item->>'claimKey','')<>COALESCE(v_candidate->>'claimKey','') OR v_item->>'reasonCode'<>v_candidate->>'reasonCode' THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_WORK_PREMISE_MISMATCH'; END IF;
   v_expected_ceiling:=CASE WHEN v_candidate->>'action' IN('REVALIDATE_R4','REVALIDATE_R5','REVALIDATE_R6') THEN 0 ELSE least(v_job,greatest(0,v_daily-v_spent-v_reserved-v_sum)) END; IF (v_item->>'costCeilingUsd')::numeric<>v_expected_ceiling THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_JOB_BUDGET_ALLOCATION_MISMATCH'; END IF;
   v_expected_dedupe:=encode(extensions.digest(concat_ws('|','MRV2-RESEARCH-WORK-1.0.0',v_expected->>'organisationId',v_expected->>'campaignId',v_expected->>'companyId',p_gap_set_fingerprint,v_expected->>'referenceTime',v_item->>'gapKey',v_item->>'costCeilingUsd'),'sha256'),'hex'); IF v_item->>'dedupeKey'<>v_expected_dedupe THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_WORK_DEDUPE_MISMATCH'; END IF; v_sum:=v_sum+v_expected_ceiling;
 END LOOP;
 IF v_sum>greatest(0,v_daily-v_spent-v_reserved) THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_DAILY_BUDGET_EXCEEDED'; END IF;
 v_expected_fp:=encode(extensions.digest('MRV2-RESEARCH-PLAN-1.0.0|'||jsonb_build_object('organisationId',v_expected->>'organisationId','campaignId',v_expected->>'campaignId','companyId',v_expected->>'companyId','referenceTime',to_jsonb((v_expected->>'referenceTime')::timestamptz),'lifecycleState',v_expected->>'lifecycleState','authorityEnvelopeFingerprint',v_expected->>'authorityEnvelopeFingerprint','gapSetFingerprint',p_gap_set_fingerprint,'workUnits',p_work_units)::text,'sha256'),'hex');
 SELECT * INTO v_existing FROM public.research_plan_runs WHERE plan_fingerprint=v_expected_fp; IF FOUND THEN RETURN QUERY SELECT v_existing.id,(SELECT count(*)::int FROM public.research_work_units WHERE plan_id=v_existing.id),v_existing.plan_fingerprint,true; RETURN; END IF;
 INSERT INTO public.research_plan_runs(organisation_id,campaign_id,company_id,reference_time,lifecycle_state,authority_envelope_fingerprint,planner_version,semantics_version,gap_set_fingerprint,gap_context_json,work_units_json,budget_policy_snapshot_json,budget_snapshot_json,plan_fingerprint)
 VALUES((v_expected->>'organisationId')::uuid,(v_expected->>'campaignId')::uuid,(v_expected->>'companyId')::uuid,(v_expected->>'referenceTime')::timestamptz,v_expected->>'lifecycleState',v_expected->>'authorityEnvelopeFingerprint',p_planner_version,p_semantics_version,p_gap_set_fingerprint,v_expected,p_work_units,v_policy,v_budget,v_expected_fp) ON CONFLICT(plan_fingerprint) DO NOTHING RETURNING id INTO v_plan;
 IF v_plan IS NULL THEN SELECT id INTO v_plan FROM public.research_plan_runs WHERE plan_fingerprint=v_expected_fp; RETURN QUERY SELECT v_plan,(SELECT count(*)::int FROM public.research_work_units WHERE plan_id=v_plan),v_expected_fp,true; RETURN; END IF;
 FOR v_item IN SELECT value FROM jsonb_array_elements(p_work_units) x(value) ORDER BY (value->>'ordinal')::int LOOP
   INSERT INTO public.background_jobs(organisation_id,campaign_id,job_type,dedupe_key,status,priority,payload_json,max_attempts)
   VALUES((v_expected->>'organisationId')::uuid,(v_expected->>'campaignId')::uuid,'GENESIS_RESEARCH_V1',v_item->>'dedupeKey','PENDING',CASE v_item->>'tier' WHEN 'DECISION_BLOCKER' THEN 10 WHEN 'CURRENTNESS_REPAIR' THEN 20 WHEN 'EXPIRING_SOON' THEN 30 ELSE 40 END,jsonb_build_object('planFingerprint',v_expected_fp,'gapKey',v_item->>'gapKey','action',v_item->>'action'),5)
   RETURNING id INTO v_job_id;
   INSERT INTO public.research_work_units(plan_id,organisation_id,campaign_id,company_id,ordinal,gap_key,layer,tier,action,subject_type,subject_id,claim_key,reason_code,query_hints_json,payload_json,cost_ceiling_usd,dedupe_key,background_job_id)
   VALUES(v_plan,(v_expected->>'organisationId')::uuid,(v_expected->>'campaignId')::uuid,(v_expected->>'companyId')::uuid,(v_item->>'ordinal')::int,v_item->>'gapKey',v_item->>'layer',v_item->>'tier',v_item->>'action',v_item->>'subjectType',v_item->>'subjectId',NULLIF(v_item->>'claimKey',''),v_item->>'reasonCode',COALESCE(v_item->'queryHints','[]'::jsonb),COALESCE(v_item->'payload','{}'::jsonb),(v_item->>'costCeilingUsd')::numeric,v_item->>'dedupeKey',v_job_id); v_count:=v_count+1;
 END LOOP;
 RETURN QUERY SELECT v_plan,v_count,v_expected_fp,false;
END $$;


CREATE OR REPLACE FUNCTION public.marketroute_research_planning_targets_v1(p_limit integer DEFAULT 100)
RETURNS TABLE(organisation_id uuid,campaign_id uuid,company_id uuid)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
 SELECT DISTINCT s.organisation_id,s.campaign_id,s.company_id
 FROM public.organisation_company_scopes s
 JOIN public.campaigns c ON c.id=s.campaign_id AND c.organisation_id=s.organisation_id
 WHERE s.scope_kind='CAMPAIGN' AND s.campaign_id IS NOT NULL AND c.workflow_state='ACTIVE'
 ORDER BY s.organisation_id,s.campaign_id,s.company_id
 LIMIT greatest(0,least(COALESCE(p_limit,100),1000));
$$;

CREATE OR REPLACE FUNCTION public.marketroute_recover_abandoned_research_work_v1(p_scheduler_run_id uuid,p_at timestamptz DEFAULT now())
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_row record; v_count integer:=0; v_terminal boolean;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.scheduler_runs r JOIN public.scheduler_leases l ON l.owner_run_id=r.id AND l.lease_key='GENESIS_RESEARCH_V1' WHERE r.id=p_scheduler_run_id AND r.status='RUNNING' AND r.runner_key='GENESIS_RESEARCH_V1' AND l.expires_at>p_at) THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_SCHEDULER_LEASE_NOT_OWNED'; END IF;
 FOR v_row IN
   SELECT j.id job_id,j.attempt_count,j.max_attempts,j.reserved_by_run_id,w.id work_unit_id,w.organisation_id,w.campaign_id,w.cost_ceiling_usd
   FROM public.background_jobs j JOIN public.research_work_units w ON w.background_job_id=j.id
   WHERE j.job_type='GENESIS_RESEARCH_V1' AND j.status='RUNNING' AND j.reserved_at<=p_at-interval '30 minutes'
     AND NOT EXISTS(SELECT 1 FROM public.scheduler_leases l WHERE l.owner_run_id=j.reserved_by_run_id AND l.lease_key='GENESIS_RESEARCH_V1' AND l.expires_at>p_at)
   ORDER BY j.reserved_at,j.id FOR UPDATE OF j SKIP LOCKED
 LOOP
   IF NOT EXISTS(SELECT 1 FROM public.research_budget_events e WHERE e.work_unit_id=v_row.work_unit_id AND e.attempt_number=v_row.attempt_count AND e.event_type IN('COMMIT','RELEASE')) THEN
     INSERT INTO public.research_budget_events(organisation_id,campaign_id,work_unit_id,scheduler_run_id,attempt_number,event_type,amount_usd,occurred_at,metadata_json)
     VALUES(v_row.organisation_id,v_row.campaign_id,v_row.work_unit_id,p_scheduler_run_id,v_row.attempt_count,'COMMIT',v_row.cost_ceiling_usd,p_at,jsonb_build_object('abandonedAttempt',true,'conservativeCharge',true));
   END IF;
   v_terminal:=v_row.attempt_count>=v_row.max_attempts;
   UPDATE public.background_job_attempts SET status='ABORTED',completed_at=p_at,error_code='MARKETROUTE_RESEARCH_ABANDONED_ATTEMPT',telemetry_json=COALESCE(telemetry_json,'{}'::jsonb)||jsonb_build_object('recoveredByRunId',p_scheduler_run_id) WHERE job_id=v_row.job_id AND attempt_number=v_row.attempt_count AND status='RUNNING';
   UPDATE public.background_jobs SET status=CASE WHEN v_terminal THEN 'FAILED' ELSE 'PENDING' END,available_at=CASE WHEN v_terminal THEN available_at ELSE p_at+interval '5 minutes' END,reserved_by_run_id=NULL,reserved_at=NULL,last_error_code='MARKETROUTE_RESEARCH_ABANDONED_ATTEMPT',updated_at=p_at WHERE id=v_row.job_id;
   v_count:=v_count+1;
 END LOOP;
 UPDATE public.scheduler_runs r SET status='CANCELLED',completed_at=COALESCE(completed_at,p_at),metadata_json=COALESCE(metadata_json,'{}'::jsonb)||jsonb_build_object('leaseExpired',true,'recoveredByRunId',p_scheduler_run_id)
 WHERE r.runner_key='GENESIS_RESEARCH_V1' AND r.status='RUNNING' AND r.id<>p_scheduler_run_id AND NOT EXISTS(SELECT 1 FROM public.scheduler_leases l WHERE l.owner_run_id=r.id AND l.lease_key='GENESIS_RESEARCH_V1' AND l.expires_at>p_at);
 RETURN v_count;
END $$;

CREATE OR REPLACE FUNCTION public.marketroute_start_research_scheduler_run_v1(p_runner_key text DEFAULT 'GENESIS_RESEARCH_V1',p_at timestamptz DEFAULT now())
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_id uuid; v_owner uuid;
BEGIN
 IF p_runner_key<>'GENESIS_RESEARCH_V1' THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_RUNNER_KEY_INVALID'; END IF;
 IF abs(extract(epoch from (p_at-now())))>300 THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_SCHEDULER_TIME_NOT_CURRENT'; END IF;
 INSERT INTO public.scheduler_runs(runner_key,status,started_at,metadata_json) VALUES(p_runner_key,'RUNNING',p_at,jsonb_build_object('researchEngine','MRV2-RESEARCH-PLANNER-1.0.0')) RETURNING id INTO v_id;
 INSERT INTO public.scheduler_leases(lease_key,owner_run_id,acquired_at,expires_at,heartbeat_at) VALUES('GENESIS_RESEARCH_V1',v_id,p_at,p_at+interval '30 minutes',p_at)
 ON CONFLICT(lease_key) DO UPDATE SET owner_run_id=EXCLUDED.owner_run_id,acquired_at=EXCLUDED.acquired_at,expires_at=EXCLUDED.expires_at,heartbeat_at=EXCLUDED.heartbeat_at WHERE public.scheduler_leases.expires_at<=p_at
 RETURNING owner_run_id INTO v_owner;
 IF v_owner IS DISTINCT FROM v_id THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_SCHEDULER_LEASE_HELD'; END IF;
 UPDATE public.scheduler_runs SET metadata_json=metadata_json||jsonb_build_object('recoveredAbandonedWork',public.marketroute_recover_abandoned_research_work_v1(v_id,p_at)) WHERE id=v_id;
 RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION public.marketroute_heartbeat_research_scheduler_run_v1(p_scheduler_run_id uuid,p_at timestamptz DEFAULT now())
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
 IF abs(extract(epoch from (p_at-now())))>300 THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_SCHEDULER_TIME_NOT_CURRENT'; END IF;
 UPDATE public.scheduler_leases SET heartbeat_at=p_at,expires_at=p_at+interval '30 minutes'
 WHERE lease_key='GENESIS_RESEARCH_V1' AND owner_run_id=p_scheduler_run_id AND expires_at>p_at
   AND EXISTS(SELECT 1 FROM public.scheduler_runs r WHERE r.id=p_scheduler_run_id AND r.status='RUNNING' AND r.runner_key='GENESIS_RESEARCH_V1');
 IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_SCHEDULER_LEASE_NOT_OWNED'; END IF;
END $$;

CREATE OR REPLACE FUNCTION public.marketroute_finish_research_scheduler_run_v1(p_scheduler_run_id uuid,p_status text,p_metadata jsonb DEFAULT '{}'::jsonb,p_at timestamptz DEFAULT now())
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
 IF p_status NOT IN('SUCCEEDED','PARTIAL','FAILED','CANCELLED') THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_RUN_STATUS_INVALID'; END IF;
 UPDATE public.scheduler_runs SET status=p_status,completed_at=p_at,metadata_json=COALESCE(metadata_json,'{}'::jsonb)||COALESCE(p_metadata,'{}'::jsonb) WHERE id=p_scheduler_run_id AND status='RUNNING' AND runner_key='GENESIS_RESEARCH_V1';
 IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_RUN_NOT_ACTIVE'; END IF;
 DELETE FROM public.scheduler_leases WHERE lease_key='GENESIS_RESEARCH_V1' AND owner_run_id=p_scheduler_run_id;
END $$;

CREATE OR REPLACE FUNCTION public.marketroute_claim_research_work_v1(p_scheduler_run_id uuid,p_at timestamptz DEFAULT now())
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_work public.research_work_units%ROWTYPE; v_job public.background_jobs%ROWTYPE; v_policy jsonb; v_budget jsonb; v_attempt int; v_remaining numeric;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.scheduler_runs r JOIN public.scheduler_leases l ON l.owner_run_id=r.id AND l.lease_key='GENESIS_RESEARCH_V1' WHERE r.id=p_scheduler_run_id AND r.status='RUNNING' AND r.runner_key='GENESIS_RESEARCH_V1' AND l.expires_at>p_at) THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_SCHEDULER_RUN_REQUIRED'; END IF;
 SELECT w.* INTO v_work FROM public.research_work_units w JOIN public.background_jobs j ON j.id=w.background_job_id
 WHERE j.job_type='GENESIS_RESEARCH_V1' AND j.status IN('PENDING','DEFERRED') AND j.available_at<=p_at
 ORDER BY j.priority,j.created_at,j.id FOR UPDATE OF j SKIP LOCKED LIMIT 1;
 IF NOT FOUND THEN RETURN NULL; END IF;
 SELECT * INTO v_job FROM public.background_jobs WHERE id=v_work.background_job_id FOR UPDATE;
 v_policy:=public.marketroute_research_policy_v1(v_work.organisation_id,v_work.campaign_id); v_budget:=public.marketroute_research_budget_snapshot_v1(v_work.organisation_id,v_work.campaign_id,p_at);
 IF COALESCE((v_policy->>'enabled')::boolean,true)=false OR (v_budget->>'activeJobs')::int >= (v_policy->>'maxConcurrentJobs')::int THEN UPDATE public.background_jobs SET status='DEFERRED',available_at=p_at+interval '5 minutes',updated_at=p_at WHERE id=v_job.id; RETURN NULL; END IF;
 v_remaining:=(v_policy->>'dailyBudgetUsd')::numeric-(v_budget->>'spentTodayUsd')::numeric-(v_budget->>'reservedTodayUsd')::numeric;
 IF v_work.cost_ceiling_usd>greatest(0,v_remaining) OR v_work.cost_ceiling_usd>(v_policy->>'maxJobCostUsd')::numeric THEN UPDATE public.background_jobs SET status='DEFERRED',available_at=(date_trunc('day',p_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC')+interval '1 day',updated_at=p_at WHERE id=v_job.id; RETURN NULL; END IF;
v_attempt:=v_job.attempt_count+1;
 IF EXISTS(SELECT 1 FROM public.research_budget_events WHERE work_unit_id=v_work.id AND attempt_number=v_attempt AND event_type='RESERVE') THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_BUDGET_ALREADY_RESERVED'; END IF;
 INSERT INTO public.research_budget_events(organisation_id,campaign_id,work_unit_id,scheduler_run_id,attempt_number,event_type,amount_usd,occurred_at) VALUES(v_work.organisation_id,v_work.campaign_id,v_work.id,p_scheduler_run_id,v_attempt,'RESERVE',v_work.cost_ceiling_usd,p_at); UPDATE public.background_jobs SET status='RUNNING',reserved_by_run_id=p_scheduler_run_id,reserved_at=p_at,attempt_count=v_attempt,updated_at=p_at WHERE id=v_job.id;
 INSERT INTO public.background_job_attempts(job_id,scheduler_run_id,attempt_number,status,started_at) VALUES(v_job.id,p_scheduler_run_id,v_attempt,'RUNNING',p_at);
 RETURN jsonb_build_object('workUnitId',v_work.id,'jobId',v_job.id,'planId',v_work.plan_id,'organisationId',v_work.organisation_id,'campaignId',v_work.campaign_id,'companyId',v_work.company_id,'gapKey',v_work.gap_key,'layer',v_work.layer,'tier',v_work.tier,'action',v_work.action,'subjectType',v_work.subject_type,'subjectId',v_work.subject_id,'claimKey',v_work.claim_key,'reasonCode',v_work.reason_code,'queryHints',v_work.query_hints_json,'payload',v_work.payload_json||jsonb_build_object('dedupeKey',v_work.dedupe_key),'costCeilingUsd',v_work.cost_ceiling_usd,'attemptNumber',v_attempt);
END $$;

CREATE OR REPLACE FUNCTION public.marketroute_complete_research_work_v1(p_work_unit_id uuid,p_scheduler_run_id uuid,p_actual_cost_usd numeric,p_metadata jsonb DEFAULT '{}'::jsonb,p_at timestamptz DEFAULT now())
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_work public.research_work_units%ROWTYPE; v_job public.background_jobs%ROWTYPE;
BEGIN
 SELECT * INTO v_work FROM public.research_work_units WHERE id=p_work_unit_id; IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_WORK_NOT_FOUND'; END IF; SELECT * INTO v_job FROM public.background_jobs WHERE id=v_work.background_job_id FOR UPDATE;
 IF v_job.status<>'RUNNING' OR v_job.reserved_by_run_id IS DISTINCT FROM p_scheduler_run_id THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_WORK_NOT_OWNED'; END IF;
 IF p_actual_cost_usd<0 OR p_actual_cost_usd>v_work.cost_ceiling_usd THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_ACTUAL_COST_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM public.research_budget_events WHERE work_unit_id=v_work.id AND attempt_number=v_job.attempt_count AND event_type IN('COMMIT','RELEASE')) THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_WORK_ALREADY_SETTLED'; END IF;
 INSERT INTO public.research_budget_events(organisation_id,campaign_id,work_unit_id,scheduler_run_id,attempt_number,event_type,amount_usd,occurred_at,metadata_json) VALUES(v_work.organisation_id,v_work.campaign_id,v_work.id,p_scheduler_run_id,v_job.attempt_count,'COMMIT',p_actual_cost_usd,p_at,COALESCE(p_metadata,'{}'::jsonb));
 UPDATE public.background_jobs SET status='SUCCEEDED',reserved_by_run_id=NULL,reserved_at=NULL,updated_at=p_at WHERE id=v_job.id;
 UPDATE public.background_job_attempts SET status='SUCCEEDED',completed_at=p_at,telemetry_json=COALESCE(p_metadata,'{}'::jsonb) WHERE job_id=v_job.id AND attempt_number=v_job.attempt_count AND status='RUNNING';
END $$;

CREATE OR REPLACE FUNCTION public.marketroute_fail_research_work_v1(p_work_unit_id uuid,p_scheduler_run_id uuid,p_error_code text,p_actual_cost_usd numeric DEFAULT 0,p_retryable boolean DEFAULT true,p_at timestamptz DEFAULT now())
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_work public.research_work_units%ROWTYPE; v_job public.background_jobs%ROWTYPE; v_terminal boolean;
BEGIN
 SELECT * INTO v_work FROM public.research_work_units WHERE id=p_work_unit_id; IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_WORK_NOT_FOUND'; END IF; SELECT * INTO v_job FROM public.background_jobs WHERE id=v_work.background_job_id FOR UPDATE;
 IF v_job.status<>'RUNNING' OR v_job.reserved_by_run_id IS DISTINCT FROM p_scheduler_run_id THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_WORK_NOT_OWNED'; END IF;
 IF p_actual_cost_usd<0 OR p_actual_cost_usd>100000 THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_FAILED_COST_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM public.research_budget_events WHERE work_unit_id=v_work.id AND attempt_number=v_job.attempt_count AND event_type IN('COMMIT','RELEASE')) THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_WORK_ALREADY_SETTLED'; END IF;
 IF p_actual_cost_usd>0 THEN INSERT INTO public.research_budget_events(organisation_id,campaign_id,work_unit_id,scheduler_run_id,attempt_number,event_type,amount_usd,occurred_at,metadata_json) VALUES(v_work.organisation_id,v_work.campaign_id,v_work.id,p_scheduler_run_id,v_job.attempt_count,'COMMIT',p_actual_cost_usd,p_at,jsonb_build_object('failedAttempt',true,'errorCode',p_error_code)); END IF;
 INSERT INTO public.research_budget_events(organisation_id,campaign_id,work_unit_id,scheduler_run_id,attempt_number,event_type,amount_usd,occurred_at,metadata_json) VALUES(v_work.organisation_id,v_work.campaign_id,v_work.id,p_scheduler_run_id,v_job.attempt_count,'RELEASE',greatest(0,v_work.cost_ceiling_usd-p_actual_cost_usd),p_at,jsonb_build_object('errorCode',p_error_code));
 v_terminal:=NOT p_retryable OR v_job.attempt_count>=v_job.max_attempts;
 UPDATE public.background_jobs SET status=CASE WHEN v_terminal THEN 'FAILED' ELSE 'PENDING' END,available_at=CASE WHEN v_terminal THEN available_at ELSE p_at+interval '5 minutes' END,reserved_by_run_id=NULL,reserved_at=NULL,last_error_code=left(COALESCE(p_error_code,'RESEARCH_FAILED'),200),updated_at=p_at WHERE id=v_job.id;
 UPDATE public.background_job_attempts SET status='FAILED',completed_at=p_at,error_code=left(COALESCE(p_error_code,'RESEARCH_FAILED'),200) WHERE job_id=v_job.id AND attempt_number=v_job.attempt_count AND status='RUNNING';
END $$;

REVOKE ALL ON FUNCTION public.marketroute_research_policy_v1(uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_set_research_policy_v1(uuid,uuid,numeric,numeric,integer,integer,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_research_budget_snapshot_v1(uuid,uuid,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_research_gap_context_v1(uuid,uuid,uuid,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_persist_research_plan_v1(jsonb,text,text,text,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_research_planning_targets_v1(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_recover_abandoned_research_work_v1(uuid,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_start_research_scheduler_run_v1(text,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_heartbeat_research_scheduler_run_v1(uuid,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_finish_research_scheduler_run_v1(uuid,text,jsonb,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_claim_research_work_v1(uuid,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_complete_research_work_v1(uuid,uuid,numeric,jsonb,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_fail_research_work_v1(uuid,uuid,text,numeric,boolean,timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.marketroute_research_policy_v1(uuid,uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_set_research_policy_v1(uuid,uuid,numeric,numeric,integer,integer,integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_research_budget_snapshot_v1(uuid,uuid,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_research_gap_context_v1(uuid,uuid,uuid,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_persist_research_plan_v1(jsonb,text,text,text,jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_research_planning_targets_v1(integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_start_research_scheduler_run_v1(text,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_heartbeat_research_scheduler_run_v1(uuid,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_finish_research_scheduler_run_v1(uuid,text,jsonb,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_claim_research_work_v1(uuid,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_complete_research_work_v1(uuid,uuid,numeric,jsonb,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_fail_research_work_v1(uuid,uuid,text,numeric,boolean,timestamptz) TO service_role;

INSERT INTO public.marketroute_schema_releases(release_key,build_number,constitution_version,metadata_json)
VALUES('MARKETROUTE_V2_BUILD10_AUTONOMOUS_RESEARCH',10,'MRV2-CONSTITUTION-1.0.0',jsonb_build_object('migration','0013_genesis_autonomous_research_engine.sql','new_authority_writer',false,'research_creates_authority',false,'planner_version','MRV2-RESEARCH-PLANNER-1.0.0','categorical_research_priority',true,'budget_fail_closed',true,'research_outputs_evidence_only',true))
ON CONFLICT(release_key) DO NOTHING;

NOTIFY pgrst, 'reload schema';

COMMIT;
