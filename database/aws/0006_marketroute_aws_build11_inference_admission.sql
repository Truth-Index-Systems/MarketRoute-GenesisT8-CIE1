-- Build 11: durable sub-reservations inside the existing canonical job budget.
-- This migration does NOT enable inference. The model-scope policy starts disabled.
-- No Truth/authority writer, ranking rule or canonical budget event is changed.
BEGIN;

CREATE TABLE public.marketroute_aws_v0_inference_scopes (
  scope_key text PRIMARY KEY,
  profile_arns text[] NOT NULL,
  enabled boolean NOT NULL DEFAULT false,
  minimum_interval_seconds integer NOT NULL DEFAULT 11 CHECK (minimum_interval_seconds BETWEEN 11 AND 3600),
  next_start_at timestamptz NOT NULL DEFAULT '-infinity',
  input_usd_per_million numeric(12,6) NOT NULL CHECK (input_usd_per_million > 0),
  output_usd_per_million numeric(12,6) NOT NULL CHECK (output_usd_per_million > 0),
  tariff_version text NOT NULL,
  last_halt_reason text,
  CHECK (cardinality(profile_arns) > 0)
);

INSERT INTO public.marketroute_aws_v0_inference_scopes
  (scope_key,profile_arns,input_usd_per_million,output_usd_per_million,tariff_version)
VALUES (
  '801132668416:eu-west-2:EU:anthropic.claude-sonnet-4-5-20250929-v1:0',
  ARRAY['arn:aws:bedrock:eu-west-2:801132668416:application-inference-profile/1t6o6h9xl4qb'],
  3.3,16.5,'MR-AWS-V0-SONNET45-EXISTING-TARIFF-1'
);
-- The tariff above preserves the existing accounting rates. Live price/configuration
-- verification is still a release gate; credits never make economic cost zero.

CREATE TABLE public.marketroute_aws_v0_inference_attempts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  work_unit_id uuid NOT NULL REFERENCES public.research_work_units(id) ON DELETE RESTRICT,
  canonical_attempt_number integer NOT NULL CHECK (canonical_attempt_number > 0),
  execution_attempt_number integer NOT NULL CHECK (execution_attempt_number BETWEEN 1 AND 3),
  worker_id text NOT NULL,
  envelope_fingerprint text NOT NULL CHECK (envelope_fingerprint ~ '^[a-f0-9]{64}$'),
  request_fingerprint text NOT NULL CHECK (request_fingerprint ~ '^[a-f0-9]{64}$'),
  scope_key text NOT NULL REFERENCES public.marketroute_aws_v0_inference_scopes(scope_key),
  profile_arn text NOT NULL,
  state text NOT NULL DEFAULT 'RESERVED' CHECK (state IN ('RESERVED','MEASURED','UNKNOWN','NOT_SENT')),
  input_token_ceiling bigint NOT NULL CHECK (input_token_ceiling > 0),
  output_token_ceiling integer NOT NULL CHECK (output_token_ceiling BETWEEN 1 AND 1400),
  reserved_cost_usd numeric(18,8) NOT NULL CHECK (reserved_cost_usd > 0),
  accounted_cost_usd numeric(18,8) CHECK (accounted_cost_usd >= 0),
  input_usd_per_million numeric(12,6) NOT NULL,
  output_usd_per_million numeric(12,6) NOT NULL,
  tariff_version text NOT NULL,
  input_units bigint,
  output_units bigint,
  admitted_at timestamptz NOT NULL,
  start_before timestamptz NOT NULL,
  settled_at timestamptz,
  telemetry_json jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(telemetry_json)='object'),
  UNIQUE(work_unit_id,canonical_attempt_number,execution_attempt_number),
  CHECK (start_before > admitted_at),
  CHECK ((state='RESERVED' AND accounted_cost_usd IS NULL AND settled_at IS NULL)
      OR (state<>'RESERVED' AND accounted_cost_usd IS NOT NULL AND settled_at IS NOT NULL))
);
CREATE INDEX marketroute_aws_v0_inference_attempts_scope_time
  ON public.marketroute_aws_v0_inference_attempts(scope_key,admitted_at);

-- Read-only checks before even the non-generating CountTokens preflight.
CREATE FUNCTION public.marketroute_preflight_aws_v0_inference_v1(
  p_work_unit_id uuid,p_envelope_fingerprint text,p_worker_id text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE
  v_work public.research_work_units%ROWTYPE;
  v_input jsonb;
  v_at timestamptz:=clock_timestamp();
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT w.* INTO v_work FROM public.research_work_units w
    JOIN public.marketroute_aws_v0_research_executions x ON x.work_unit_id=w.id
    JOIN public.background_jobs j ON j.id=w.background_job_id
    JOIN public.marketroute_aws_v0_research_dispatches d ON d.work_unit_id=w.id
      AND d.envelope_fingerprint=p_envelope_fingerprint
    WHERE w.id=p_work_unit_id AND w.action='SYNTHESIZE_COMPANY_UNDERSTANDING'
      AND x.state='CLAIMED' AND x.worker_id=p_worker_id
      AND x.envelope_fingerprint=p_envelope_fingerprint AND x.lease_expires_at>v_at
      AND j.status='RUNNING' AND j.attempt_count=d.canonical_attempt_number
      AND j.reserved_by_run_id=d.scheduler_run_id AND d.state='SENT' AND d.ownership_expires_at>v_at;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_AWS_V0_ADMISSION_OWNERSHIP_INVALID'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.campaigns c JOIN public.organisations o ON o.id=c.organisation_id
    WHERE c.id=v_work.campaign_id AND c.organisation_id=v_work.organisation_id
      AND c.workflow_state='ACTIVE' AND o.status='ACTIVE') THEN
    RETURN jsonb_build_object('outcome','DEFERRED','reason','CAMPAIGN_NOT_ACTIVE');
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.marketroute_aws_v0_inference_scopes
    WHERE scope_key='801132668416:eu-west-2:EU:anthropic.claude-sonnet-4-5-20250929-v1:0' AND enabled) THEN
    RETURN jsonb_build_object('outcome','DEFERRED','reason','MODEL_SCOPE_DISABLED');
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.research_budget_policies
    WHERE organisation_id=v_work.organisation_id AND campaign_id=v_work.campaign_id AND enabled) THEN
    RETURN jsonb_build_object('outcome','DEFERRED','reason','BUDGET_POLICY_DISABLED');
  END IF;
  v_input:=v_work.payload_json#>'{metadata,awsV0Executor,input}';
  IF jsonb_typeof(v_input->'evidence') IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'MARKETROUTE_AWS_V0_ADMISSION_EVIDENCE_INVALID';
  END IF;
  IF jsonb_array_length(v_input->'evidence') NOT BETWEEN 1 AND 40 OR EXISTS(
    SELECT 1 FROM jsonb_array_elements(v_input->'evidence') supplied
    LEFT JOIN public.evidence_items e ON e.id=(supplied->>'evidenceId')::uuid
    LEFT JOIN public.source_acquisitions a ON a.id=e.acquisition_id
    LEFT JOIN public.source_records s ON s.id=a.source_id
    WHERE e.id IS NULL OR e.subject_type<>'COMPANY' OR e.subject_id<>v_work.company_id
      OR (e.tenant_scope_organisation_id IS NOT NULL AND e.tenant_scope_organisation_id<>v_work.organisation_id)
      OR supplied->>'statement' IS DISTINCT FROM e.excerpt_text
      OR NULLIF(supplied->>'observedAt','')::timestamptz IS DISTINCT FROM e.observed_at
      OR supplied->>'sourceType' IS DISTINCT FROM CASE s.source_kind
        WHEN 'WEB' THEN 'WEBSITE' WHEN 'REGISTRY' THEN 'REGISTRY' WHEN 'DOCUMENT' THEN 'DOCUMENT' ELSE 'OTHER' END
  ) THEN RAISE EXCEPTION 'MARKETROUTE_AWS_V0_ADMISSION_EVIDENCE_SCOPE_OR_CONTENT_INVALID'; END IF;
  RETURN jsonb_build_object('outcome','READY');
END;
$$;

CREATE FUNCTION public.marketroute_admit_aws_v0_inference_v1(
  p_work_unit_id uuid,p_envelope_fingerprint text,p_worker_id text,
  p_request_fingerprint text,p_profile_arn text,p_input_tokens bigint,p_output_cap integer
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE
  v_at timestamptz;
  v_work public.research_work_units%ROWTYPE;
  v_job public.background_jobs%ROWTYPE;
  v_exec public.marketroute_aws_v0_research_executions%ROWTYPE;
  v_dispatch public.marketroute_aws_v0_research_dispatches%ROWTYPE;
  v_policy public.research_budget_policies%ROWTYPE;
  v_scope public.marketroute_aws_v0_inference_scopes%ROWTYPE;
  v_existing public.marketroute_aws_v0_inference_attempts%ROWTYPE;
  v_id uuid;
  v_cost numeric;
  v_consumed numeric;
  v_committed numeric;
  v_outstanding numeric;
  v_preflight jsonb;
  v_scope_key constant text := '801132668416:eu-west-2:EU:anthropic.claude-sonnet-4-5-20250929-v1:0';
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF p_work_unit_id IS NULL OR COALESCE(p_envelope_fingerprint,'') !~ '^[a-f0-9]{64}$'
     OR COALESCE(p_request_fingerprint,'') !~ '^[a-f0-9]{64}$'
     OR length(btrim(COALESCE(p_worker_id,''))) NOT BETWEEN 1 AND 200
     OR p_input_tokens IS NULL OR p_input_tokens<=0
     OR p_output_cap IS NULL OR p_output_cap NOT BETWEEN 1 AND 1400
     OR p_input_tokens+p_output_cap>200000 THEN
    RAISE EXCEPTION 'MARKETROUTE_AWS_V0_ADMISSION_INPUT_INVALID';
  END IF;
  SELECT * INTO v_exec FROM public.marketroute_aws_v0_research_executions
    WHERE work_unit_id=p_work_unit_id FOR UPDATE;
  IF NOT FOUND OR v_exec.state IS DISTINCT FROM 'CLAIMED'
     OR v_exec.worker_id IS DISTINCT FROM p_worker_id
     OR v_exec.envelope_fingerprint IS DISTINCT FROM p_envelope_fingerprint THEN
    RAISE EXCEPTION 'MARKETROUTE_AWS_V0_ADMISSION_OWNERSHIP_INVALID';
  END IF;
  SELECT * INTO v_work FROM public.research_work_units WHERE id=p_work_unit_id;
  SELECT * INTO v_dispatch FROM public.marketroute_aws_v0_research_dispatches
    WHERE work_unit_id=p_work_unit_id AND envelope_fingerprint=p_envelope_fingerprint FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_AWS_V0_ADMISSION_OWNERSHIP_INVALID'; END IF;
  SELECT * INTO v_job FROM public.background_jobs WHERE id=v_work.background_job_id FOR UPDATE;
  IF NOT FOUND OR v_job.status IS DISTINCT FROM 'RUNNING'
     OR v_dispatch.state IS DISTINCT FROM 'SENT'
     OR v_work.action IS DISTINCT FROM 'SYNTHESIZE_COMPANY_UNDERSTANDING'
     OR v_job.attempt_count IS DISTINCT FROM v_dispatch.canonical_attempt_number
     OR v_job.reserved_by_run_id IS DISTINCT FROM v_dispatch.scheduler_run_id THEN
    RAISE EXCEPTION 'MARKETROUTE_AWS_V0_ADMISSION_OWNERSHIP_INVALID';
  END IF;
  SELECT * INTO v_existing FROM public.marketroute_aws_v0_inference_attempts
    WHERE work_unit_id=p_work_unit_id AND canonical_attempt_number=v_job.attempt_count
      AND execution_attempt_number=v_exec.attempt_count;
  IF FOUND THEN
    IF v_existing.request_fingerprint IS DISTINCT FROM p_request_fingerprint
       OR v_existing.profile_arn IS DISTINCT FROM p_profile_arn THEN
      RAISE EXCEPTION 'MARKETROUTE_AWS_V0_ADMISSION_COLLISION';
    END IF;
    -- An ambiguous response is NOT permission to start the request again.
    RETURN jsonb_build_object('outcome','ALREADY_ADMITTED','admissionId',v_existing.id);
  END IF;
  SELECT * INTO v_policy FROM public.research_budget_policies
    WHERE organisation_id=v_work.organisation_id AND campaign_id=v_work.campaign_id FOR UPDATE;
  IF NOT FOUND OR NOT v_policy.enabled OR v_policy.max_concurrent_jobs<=0 THEN
    RETURN jsonb_build_object('outcome','DEFERRED','reason','BUDGET_POLICY_DISABLED');
  END IF;
  SELECT * INTO v_scope FROM public.marketroute_aws_v0_inference_scopes WHERE scope_key=v_scope_key FOR UPDATE;
  IF NOT FOUND OR NOT v_scope.enabled THEN
    RETURN jsonb_build_object('outcome','DEFERRED','reason','MODEL_SCOPE_DISABLED');
  END IF;
  IF p_profile_arn IS NULL OR NOT p_profile_arn=ANY(v_scope.profile_arns) THEN
    RAISE EXCEPTION 'MARKETROUTE_AWS_V0_ADMISSION_PROFILE_FORBIDDEN';
  END IF;
  -- Server time after lock acquisition; callers cannot backdate rate permits.
  v_at:=clock_timestamp();
  IF v_exec.lease_expires_at IS NULL OR v_exec.lease_expires_at<=v_at
     OR v_dispatch.ownership_expires_at IS NULL OR v_dispatch.ownership_expires_at<=v_at THEN
    RAISE EXCEPTION 'MARKETROUTE_AWS_V0_ADMISSION_OWNERSHIP_EXPIRED';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.research_budget_events e
    WHERE e.work_unit_id=p_work_unit_id AND e.attempt_number=v_job.attempt_count
      AND e.event_type='RESERVE' AND e.amount_usd>=v_work.cost_ceiling_usd
      AND NOT EXISTS(SELECT 1 FROM public.research_budget_events settled
        WHERE settled.work_unit_id=e.work_unit_id AND settled.attempt_number=e.attempt_number
          AND settled.event_type IN('COMMIT','RELEASE'))
  ) THEN RETURN jsonb_build_object('outcome','DEFERRED','reason','CANONICAL_RESERVATION_REQUIRED'); END IF;
  SELECT COALESCE(sum(amount_usd),0) INTO v_committed FROM public.research_budget_events
    WHERE organisation_id=v_work.organisation_id AND campaign_id=v_work.campaign_id
      AND event_type='COMMIT' AND occurred_at>=date_trunc('day',v_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
  -- Outstanding reservations from prior days still consume capacity. Do not
  -- double count the provider sub-reservations as new canonical reservations.
  SELECT COALESCE(sum(e.amount_usd),0) INTO v_outstanding FROM public.research_budget_events e
    WHERE e.organisation_id=v_work.organisation_id AND e.campaign_id=v_work.campaign_id
      AND e.event_type='RESERVE' AND NOT EXISTS(
        SELECT 1 FROM public.research_budget_events s WHERE s.work_unit_id=e.work_unit_id
          AND s.attempt_number=e.attempt_number AND s.event_type IN('COMMIT','RELEASE'));
  IF v_committed+v_outstanding>v_policy.daily_budget_usd THEN
    RETURN jsonb_build_object('outcome','DEFERRED','reason','DAILY_BUDGET_EXHAUSTED');
  END IF;
  IF (SELECT count(*) FROM public.marketroute_aws_v0_inference_attempts
      WHERE work_unit_id=p_work_unit_id AND canonical_attempt_number=v_job.attempt_count
        AND execution_attempt_number<v_exec.attempt_count) <> v_exec.attempt_count-1 THEN
    RETURN jsonb_build_object('outcome','DEFERRED','reason','LEGACY_ATTEMPT_ACCOUNTING_REQUIRED');
  END IF;
  v_cost:=ceil(((p_input_tokens::numeric*v_scope.input_usd_per_million
    +p_output_cap::numeric*v_scope.output_usd_per_million)/1000000)*100000000)/100000000;
  SELECT COALESCE(sum(COALESCE(accounted_cost_usd,reserved_cost_usd)),0) INTO v_consumed
    FROM public.marketroute_aws_v0_inference_attempts WHERE work_unit_id=p_work_unit_id
      AND canonical_attempt_number=v_job.attempt_count;
  IF v_cost>v_policy.max_job_cost_usd OR v_consumed+v_cost>v_work.cost_ceiling_usd THEN
    RETURN jsonb_build_object('outcome','DEFERRED','reason','WORK_BUDGET_EXHAUSTED');
  END IF;
  IF v_scope.next_start_at>v_at THEN
    RETURN jsonb_build_object('outcome','DEFERRED','reason','REQUEST_RATE_LIMIT',
      'retryAt',v_scope.next_start_at);
  END IF;
  v_preflight:=public.marketroute_preflight_aws_v0_inference_v1(p_work_unit_id,p_envelope_fingerprint,p_worker_id);
  IF v_preflight->>'outcome'<>'READY' THEN RETURN v_preflight; END IF;
  v_at:=clock_timestamp();
  INSERT INTO public.marketroute_aws_v0_inference_attempts
    (work_unit_id,canonical_attempt_number,execution_attempt_number,worker_id,envelope_fingerprint,
     request_fingerprint,scope_key,profile_arn,input_token_ceiling,output_token_ceiling,reserved_cost_usd,
     input_usd_per_million,output_usd_per_million,tariff_version,admitted_at,start_before)
  VALUES(p_work_unit_id,v_job.attempt_count,v_exec.attempt_count,p_worker_id,p_envelope_fingerprint,
     p_request_fingerprint,v_scope_key,p_profile_arn,p_input_tokens,p_output_cap,v_cost,
     v_scope.input_usd_per_million,v_scope.output_usd_per_million,v_scope.tariff_version,v_at,v_at+interval '1 second')
  RETURNING id INTO v_id;
  UPDATE public.marketroute_aws_v0_inference_scopes
    SET next_start_at=v_at+make_interval(secs=>minimum_interval_seconds) WHERE scope_key=v_scope_key;
  RETURN jsonb_build_object('outcome','ADMITTED','admissionId',v_id,'reservedCostUsd',v_cost,
    'startBefore',v_at+interval '1 second','tariffVersion',v_scope.tariff_version);
END;
$$;

CREATE FUNCTION public.marketroute_defer_aws_v0_inference_v1(
  p_work_unit_id uuid,p_envelope_fingerprint text,p_worker_id text
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE v_exec public.marketroute_aws_v0_research_executions%ROWTYPE;
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT * INTO v_exec FROM public.marketroute_aws_v0_research_executions
    WHERE work_unit_id=p_work_unit_id FOR UPDATE;
  IF NOT FOUND OR v_exec.state IS DISTINCT FROM 'CLAIMED'
     OR v_exec.worker_id IS DISTINCT FROM p_worker_id
     OR v_exec.envelope_fingerprint IS DISTINCT FROM p_envelope_fingerprint THEN RETURN false; END IF;
  IF EXISTS(SELECT 1 FROM public.marketroute_aws_v0_inference_attempts
    WHERE work_unit_id=p_work_unit_id AND envelope_fingerprint=p_envelope_fingerprint
      AND execution_attempt_number=v_exec.attempt_count) THEN RETURN false; END IF;
  UPDATE public.marketroute_aws_v0_research_executions SET state='FAILED_RETRYABLE',
    attempt_count=GREATEST(0,attempt_count-1),worker_id=NULL,lease_expires_at=NULL,
    last_error_code='MARKETROUTE_AWS_V0_ADMISSION_DEFERRED',updated_at=clock_timestamp()
    WHERE work_unit_id=p_work_unit_id;
  RETURN true;
END;
$$;

CREATE FUNCTION public.marketroute_settle_aws_v0_inference_v1(
  p_admission_id uuid,p_worker_id text,p_request_fingerprint text,p_outcome text,
  p_input_units bigint,p_output_units bigint,p_telemetry jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE
  v_row public.marketroute_aws_v0_inference_attempts%ROWTYPE;
  v_cost numeric;
  v_total numeric;
  v_breach boolean;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF p_outcome IS NULL OR p_outcome NOT IN('MEASURED','UNKNOWN','NOT_SENT')
     OR jsonb_typeof(p_telemetry) IS DISTINCT FROM 'object' OR pg_column_size(p_telemetry)>32768 THEN
    RAISE EXCEPTION 'MARKETROUTE_AWS_V0_ADMISSION_SETTLEMENT_INVALID';
  END IF;
  SELECT * INTO v_row FROM public.marketroute_aws_v0_inference_attempts WHERE id=p_admission_id FOR UPDATE;
  IF NOT FOUND OR v_row.worker_id IS DISTINCT FROM p_worker_id
     OR v_row.request_fingerprint IS DISTINCT FROM p_request_fingerprint THEN
    RAISE EXCEPTION 'MARKETROUTE_AWS_V0_ADMISSION_SETTLEMENT_OWNERSHIP_INVALID';
  END IF;
  IF p_outcome='MEASURED' THEN
    IF p_input_units IS NULL OR p_output_units IS NULL OR p_input_units<0 OR p_output_units<0
       OR p_input_units>10000000 OR p_output_units>10000000 THEN
      RAISE EXCEPTION 'MARKETROUTE_AWS_V0_ADMISSION_USAGE_INVALID';
    END IF;
    v_cost:=ceil(((p_input_units::numeric*v_row.input_usd_per_million
      +p_output_units::numeric*v_row.output_usd_per_million)/1000000)*100000000)/100000000;
  ELSE
    IF p_input_units IS NOT NULL OR p_output_units IS NOT NULL THEN
      RAISE EXCEPTION 'MARKETROUTE_AWS_V0_ADMISSION_USAGE_INVALID';
    END IF;
    v_cost:=CASE WHEN p_outcome='NOT_SENT' THEN 0 ELSE v_row.reserved_cost_usd END;
  END IF;
  IF v_row.state<>'RESERVED' THEN
    IF v_row.state IS DISTINCT FROM p_outcome OR v_row.input_units IS DISTINCT FROM p_input_units
       OR v_row.output_units IS DISTINCT FROM p_output_units THEN
      RAISE EXCEPTION 'MARKETROUTE_AWS_V0_ADMISSION_SETTLEMENT_COLLISION';
    END IF;
    -- Repeated receipts do not write or free budget a second time.
  ELSE
    UPDATE public.marketroute_aws_v0_inference_attempts SET state=p_outcome,
      accounted_cost_usd=v_cost,input_units=p_input_units,output_units=p_output_units,
      settled_at=clock_timestamp(),telemetry_json=p_telemetry WHERE id=p_admission_id;
  END IF;
  v_breach:=v_cost>v_row.reserved_cost_usd
    OR (p_outcome='MEASURED' AND (p_input_units>v_row.input_token_ceiling OR p_output_units>v_row.output_token_ceiling));
  IF v_breach THEN
    UPDATE public.marketroute_aws_v0_inference_scopes SET enabled=false,
      last_halt_reason='MEASURED_USAGE_EXCEEDED_RESERVATION' WHERE scope_key=v_row.scope_key;
  END IF;
  SELECT COALESCE(sum(COALESCE(accounted_cost_usd,reserved_cost_usd)),0) INTO v_total
    FROM public.marketroute_aws_v0_inference_attempts WHERE work_unit_id=v_row.work_unit_id
      AND canonical_attempt_number=v_row.canonical_attempt_number;
  RETURN jsonb_build_object('attemptCostUsd',v_cost,'accountedCostUsd',v_total,
    'withinReservation',NOT v_breach,'usageState',p_outcome);
END;
$$;

CREATE OR REPLACE FUNCTION public.marketroute_sync_aws_v0_research_failure_v1(
    p_work_unit_id uuid,
    p_envelope_fingerprint text,
    p_at timestamp with time zone DEFAULT now()
) RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
  v_work public.research_work_units%ROWTYPE;
  v_job public.background_jobs%ROWTYPE;
  v_dispatch public.marketroute_aws_v0_research_dispatches%ROWTYPE;
  v_execution public.marketroute_aws_v0_research_executions%ROWTYPE;
  v_cost numeric;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF p_at IS NULL OR abs(extract(epoch FROM(now()-p_at)))>300 THEN RAISE EXCEPTION 'MARKETROUTE_AWS_V0_SYNC_TIME_NOT_CURRENT'; END IF;
  SELECT * INTO v_work FROM public.research_work_units WHERE id=p_work_unit_id;
  IF NOT FOUND OR v_work.action<>'SYNTHESIZE_COMPANY_UNDERSTANDING' THEN RETURN 'BLOCKED_CAPABILITY'; END IF;
  -- Match claim/admission/success synchronization lock order: execution, dispatch, job.
  SELECT * INTO v_execution FROM public.marketroute_aws_v0_research_executions WHERE work_unit_id=v_work.id FOR UPDATE;
  IF NOT FOUND OR v_execution.state IS DISTINCT FROM 'FAILED_TERMINAL' OR v_execution.envelope_fingerprint IS DISTINCT FROM p_envelope_fingerprint THEN RAISE EXCEPTION 'MARKETROUTE_AWS_V0_SYNC_FAILURE_INVALID'; END IF;
  SELECT * INTO v_dispatch FROM public.marketroute_aws_v0_research_dispatches WHERE work_unit_id=v_work.id AND envelope_fingerprint=p_envelope_fingerprint FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_AWS_V0_SYNC_DISPATCH_NOT_FOUND'; END IF;
  IF v_dispatch.state='FAILED' THEN RETURN 'ALREADY_FAILED'; END IF;
  SELECT * INTO v_job FROM public.background_jobs WHERE id=v_work.background_job_id FOR UPDATE;
  IF v_job.status<>'RUNNING' OR v_job.reserved_by_run_id IS DISTINCT FROM v_dispatch.scheduler_run_id OR v_job.attempt_count IS DISTINCT FROM v_dispatch.canonical_attempt_number THEN RAISE EXCEPTION 'MARKETROUTE_AWS_V0_SYNC_CANONICAL_OWNERSHIP_INVALID'; END IF;
  -- New attempts settle their measured/held sub-reservations exactly once.
  -- Historical failures without admission receipts retain the old conservative ceiling.
  SELECT COALESCE(sum(COALESCE(accounted_cost_usd,reserved_cost_usd)),v_work.cost_ceiling_usd)
    INTO v_cost FROM public.marketroute_aws_v0_inference_attempts
    WHERE work_unit_id=v_work.id AND canonical_attempt_number=v_dispatch.canonical_attempt_number;
  PERFORM public.marketroute_fail_research_work_v1(v_work.id,v_dispatch.scheduler_run_id,COALESCE(v_execution.last_error_code,'MARKETROUTE_AWS_V0_RESEARCH_EXECUTION_FAILED'),v_cost,false,p_at);
  UPDATE public.marketroute_aws_v0_research_dispatches SET state='FAILED',ownership_expires_at=NULL,last_error_code=COALESCE(v_execution.last_error_code,'MARKETROUTE_AWS_V0_RESEARCH_EXECUTION_FAILED'),updated_at=p_at WHERE work_unit_id=v_work.id AND canonical_attempt_number=v_job.attempt_count;
  RETURN 'FAILED_SYNCED';
END;
$$;

REVOKE ALL ON FUNCTION public.marketroute_preflight_aws_v0_inference_v1(uuid,text,text) FROM PUBLIC;
REVOKE ALL ON TABLE public.marketroute_aws_v0_inference_scopes FROM PUBLIC;
REVOKE ALL ON TABLE public.marketroute_aws_v0_inference_attempts FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_admit_aws_v0_inference_v1(uuid,text,text,text,text,bigint,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_defer_aws_v0_inference_v1(uuid,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_settle_aws_v0_inference_v1(uuid,text,text,text,bigint,bigint,jsonb) FROM PUBLIC;
COMMIT;
