-- MarketRoute AWS V0 Build 9
-- Durable, non-canonical execution receipts for the first bounded Lambda worker.
-- Build 10 owns canonical research-work completion, budget settlement and dispatch.

BEGIN;

CREATE TABLE public.marketroute_aws_v0_research_executions (
    work_unit_id uuid NOT NULL,
    dedupe_key text NOT NULL,
    envelope_fingerprint text NOT NULL,
    execution_contract_version text DEFAULT 'MR-AWS-V0-RESEARCH-EXECUTION-1.0.0'::text NOT NULL,
    state text NOT NULL,
    worker_id text,
    attempt_count integer DEFAULT 0 NOT NULL,
    lease_expires_at timestamp with time zone,
    result_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    result_fingerprint text,
    telemetry_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    last_error_code text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    completed_at timestamp with time zone,
    CONSTRAINT marketroute_aws_v0_research_executions_pkey PRIMARY KEY (work_unit_id),
    CONSTRAINT marketroute_aws_v0_research_executions_work_unit_fkey
      FOREIGN KEY (work_unit_id) REFERENCES public.research_work_units(id) ON DELETE RESTRICT,
    CONSTRAINT marketroute_aws_v0_research_executions_dedupe_unique UNIQUE (dedupe_key),
    CONSTRAINT marketroute_aws_v0_research_executions_dedupe_check CHECK (dedupe_key ~ '^[a-f0-9]{64}$'::text),
    CONSTRAINT marketroute_aws_v0_research_executions_envelope_check CHECK (envelope_fingerprint ~ '^[a-f0-9]{64}$'::text),
    CONSTRAINT marketroute_aws_v0_research_executions_contract_check CHECK (execution_contract_version = 'MR-AWS-V0-RESEARCH-EXECUTION-1.0.0'::text),
    CONSTRAINT marketroute_aws_v0_research_executions_state_check CHECK (state = ANY (ARRAY[
      'CLAIMED'::text,
      'SUCCEEDED'::text,
      'FAILED_RETRYABLE'::text,
      'FAILED_TERMINAL'::text
    ])),
    CONSTRAINT marketroute_aws_v0_research_executions_attempt_check CHECK (attempt_count BETWEEN 0 AND 3),
    CONSTRAINT marketroute_aws_v0_research_executions_result_check CHECK (jsonb_typeof(result_json) = 'object'::text),
    CONSTRAINT marketroute_aws_v0_research_executions_telemetry_check CHECK (jsonb_typeof(telemetry_json) = 'object'::text),
    CONSTRAINT marketroute_aws_v0_research_executions_result_fingerprint_check CHECK (
      result_fingerprint IS NULL OR result_fingerprint ~ '^[a-f0-9]{64}$'::text
    )
);

CREATE INDEX marketroute_aws_v0_research_executions_state_lease_idx
    ON public.marketroute_aws_v0_research_executions (state, lease_expires_at, updated_at);

COMMENT ON TABLE public.marketroute_aws_v0_research_executions IS
    'Build 9 Aurora-owned idempotency and execution-receipt boundary. Results are non-canonical until Build 10 synchronizes them through existing Truth and research contracts.';

CREATE FUNCTION public.marketroute_claim_aws_v0_research_execution_v1(
    p_envelope jsonb,
    p_envelope_fingerprint text,
    p_worker_id text,
    p_at timestamp with time zone DEFAULT now()
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_work public.research_work_units%ROWTYPE;
    v_job public.background_jobs%ROWTYPE;
    v_execution public.marketroute_aws_v0_research_executions%ROWTYPE;
    v_work_json jsonb;
    v_executor jsonb;
    v_worker text := btrim(COALESCE(p_worker_id, ''));
    v_inserted integer := 0;
BEGIN
    PERFORM public.marketroute_require_service_role();

    IF p_at IS NULL OR abs(extract(epoch FROM (now() - p_at))) > 300 THEN
        RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RESEARCH_CLAIM_TIME_NOT_CURRENT';
    END IF;
    IF jsonb_typeof(p_envelope) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RESEARCH_ENVELOPE_REQUIRED';
    END IF;
    IF COALESCE(p_envelope_fingerprint, '') !~ '^[a-f0-9]{64}$' THEN
        RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RESEARCH_ENVELOPE_FINGERPRINT_INVALID';
    END IF;
    IF length(v_worker) NOT BETWEEN 1 AND 200 THEN
        RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RESEARCH_WORKER_ID_INVALID';
    END IF;
    IF p_envelope->>'schemaVersion' IS DISTINCT FROM '1'
       OR p_envelope->>'transport' IS DISTINCT FROM 'AWS_SQS'
       OR jsonb_typeof(p_envelope->'workUnit') IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RESEARCH_TRANSPORT_INVALID';
    END IF;

    SELECT * INTO v_work
    FROM public.research_work_units
    WHERE id = (p_envelope->>'workUnitId')::uuid;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RESEARCH_WORK_NOT_FOUND';
    END IF;

    SELECT * INTO v_job
    FROM public.background_jobs
    WHERE id = v_work.background_job_id;
    IF NOT FOUND OR v_job.job_type <> 'GENESIS_RESEARCH_V1'
       OR v_job.status IN ('SUCCEEDED', 'FAILED', 'CANCELLED') THEN
        RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RESEARCH_WORK_NOT_EXECUTABLE';
    END IF;

    v_work_json := p_envelope->'workUnit';
    IF p_envelope->>'organisationId' IS DISTINCT FROM v_work.organisation_id::text
       OR p_envelope->>'campaignId' IS DISTINCT FROM v_work.campaign_id::text
       OR p_envelope->>'companyId' IS DISTINCT FROM v_work.company_id::text
       OR p_envelope->>'dedupeKey' IS DISTINCT FROM v_work.dedupe_key
       OR v_work_json->>'dedupeKey' IS DISTINCT FROM v_work.dedupe_key
       OR (v_work_json->>'ordinal')::integer IS DISTINCT FROM v_work.ordinal
       OR v_work_json->>'gapKey' IS DISTINCT FROM v_work.gap_key
       OR v_work_json->>'layer' IS DISTINCT FROM v_work.layer
       OR v_work_json->>'tier' IS DISTINCT FROM v_work.tier
       OR v_work_json->>'action' IS DISTINCT FROM v_work.action
       OR v_work_json->>'subjectType' IS DISTINCT FROM v_work.subject_type
       OR v_work_json->>'subjectId' IS DISTINCT FROM v_work.subject_id
       OR NULLIF(v_work_json->>'claimKey', '') IS DISTINCT FROM v_work.claim_key
       OR v_work_json->>'reasonCode' IS DISTINCT FROM v_work.reason_code
       OR v_work_json->'queryHints' IS DISTINCT FROM v_work.query_hints_json
       OR (v_work_json->>'costCeilingUsd')::numeric IS DISTINCT FROM v_work.cost_ceiling_usd
       OR v_work_json->'payload' IS DISTINCT FROM v_work.payload_json THEN
        RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RESEARCH_ENVELOPE_WORK_MISMATCH';
    END IF;

    v_executor := v_work.payload_json->'metadata'->'awsV0Executor';
    IF v_work.action <> 'ACQUIRE_CLAIM_EVIDENCE'
       OR jsonb_typeof(v_executor) IS DISTINCT FROM 'object'
       OR v_executor->>'contractVersion' IS DISTINCT FROM 'MR-AWS-V0-COMPANY-UNDERSTANDING-1.0.0'
       OR v_executor->>'operation' IS DISTINCT FROM 'ai.companyUnderstanding'
       OR jsonb_typeof(v_executor->'input') IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RESEARCH_EXECUTOR_CAPABILITY_UNSUPPORTED';
    END IF;

    INSERT INTO public.marketroute_aws_v0_research_executions (
      work_unit_id, dedupe_key, envelope_fingerprint, state, worker_id,
      attempt_count, lease_expires_at, created_at, updated_at
    ) VALUES (
      v_work.id, v_work.dedupe_key, p_envelope_fingerprint, 'CLAIMED', v_worker,
      1, p_at + interval '210 seconds', p_at, p_at
    ) ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    SELECT * INTO v_execution
    FROM public.marketroute_aws_v0_research_executions
    WHERE dedupe_key = v_work.dedupe_key
    FOR UPDATE;

    IF NOT FOUND OR v_execution.work_unit_id <> v_work.id
       OR v_execution.envelope_fingerprint <> p_envelope_fingerprint THEN
        RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RESEARCH_IDEMPOTENCY_COLLISION';
    END IF;

    IF v_inserted = 1 THEN
        RETURN jsonb_build_object('outcome', 'CLAIMED', 'attemptCount', 1, 'leaseExpiresAt', v_execution.lease_expires_at);
    END IF;
    IF v_execution.state = 'SUCCEEDED' THEN
        RETURN jsonb_build_object('outcome', 'DEDUPLICATED', 'attemptCount', v_execution.attempt_count, 'resultFingerprint', v_execution.result_fingerprint);
    END IF;
    IF v_execution.state = 'FAILED_TERMINAL' THEN
        RETURN jsonb_build_object('outcome', 'TERMINAL', 'attemptCount', v_execution.attempt_count, 'errorCode', v_execution.last_error_code);
    END IF;
    IF v_execution.state = 'CLAIMED' AND v_execution.lease_expires_at > p_at THEN
        RETURN jsonb_build_object('outcome', 'BUSY', 'attemptCount', v_execution.attempt_count, 'leaseExpiresAt', v_execution.lease_expires_at);
    END IF;
    IF v_execution.attempt_count >= 3 THEN
        UPDATE public.marketroute_aws_v0_research_executions
        SET state = 'FAILED_TERMINAL', worker_id = NULL, lease_expires_at = NULL,
            last_error_code = 'MARKETROUTE_AWS_V0_RESEARCH_ATTEMPT_CEILING_REACHED', updated_at = p_at
        WHERE work_unit_id = v_work.id;
        RETURN jsonb_build_object('outcome', 'TERMINAL', 'attemptCount', v_execution.attempt_count, 'errorCode', 'MARKETROUTE_AWS_V0_RESEARCH_ATTEMPT_CEILING_REACHED');
    END IF;

    UPDATE public.marketroute_aws_v0_research_executions
    SET state = 'CLAIMED', worker_id = v_worker,
        attempt_count = attempt_count + 1,
        lease_expires_at = p_at + interval '210 seconds',
        last_error_code = NULL, updated_at = p_at
    WHERE work_unit_id = v_work.id
    RETURNING * INTO v_execution;

    RETURN jsonb_build_object('outcome', 'CLAIMED', 'attemptCount', v_execution.attempt_count, 'leaseExpiresAt', v_execution.lease_expires_at);
END;
$$;

CREATE FUNCTION public.marketroute_complete_aws_v0_research_execution_v1(
    p_work_unit_id uuid,
    p_envelope_fingerprint text,
    p_worker_id text,
    p_result_json jsonb,
    p_telemetry_json jsonb,
    p_at timestamp with time zone DEFAULT now()
) RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_execution public.marketroute_aws_v0_research_executions%ROWTYPE;
    v_result_fingerprint text;
    v_cost_ceiling numeric;
    v_economic_cost numeric;
BEGIN
    PERFORM public.marketroute_require_service_role();
    IF p_at IS NULL OR abs(extract(epoch FROM (now() - p_at))) > 300 THEN
        RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RESEARCH_COMPLETION_TIME_NOT_CURRENT';
    END IF;
    IF jsonb_typeof(p_result_json) IS DISTINCT FROM 'object' OR pg_column_size(p_result_json) > 131072 THEN
        RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RESEARCH_RESULT_INVALID';
    END IF;
    IF jsonb_typeof(p_telemetry_json) IS DISTINCT FROM 'object' OR pg_column_size(p_telemetry_json) > 32768 THEN
        RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RESEARCH_TELEMETRY_INVALID';
    END IF;

    SELECT * INTO v_execution
    FROM public.marketroute_aws_v0_research_executions
    WHERE work_unit_id = p_work_unit_id
    FOR UPDATE;
    IF NOT FOUND OR v_execution.state <> 'CLAIMED'
       OR v_execution.worker_id IS DISTINCT FROM btrim(COALESCE(p_worker_id, ''))
       OR v_execution.envelope_fingerprint IS DISTINCT FROM p_envelope_fingerprint
       OR v_execution.lease_expires_at <= p_at THEN
        RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RESEARCH_EXECUTION_LEASE_INVALID';
    END IF;

    SELECT cost_ceiling_usd INTO v_cost_ceiling
    FROM public.research_work_units
    WHERE id = p_work_unit_id;
    BEGIN
      v_economic_cost := (p_telemetry_json->>'estimatedEquivalentCostUsd')::numeric;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RESEARCH_ECONOMIC_COST_INVALID';
    END;
    IF v_economic_cost < 0 OR v_economic_cost > v_cost_ceiling THEN
      RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RESEARCH_COST_CEILING_EXCEEDED';
    END IF;

    v_result_fingerprint := encode(extensions.digest(
      'MR-AWS-V0-RESEARCH-RESULT-1.0.0|' || p_result_json::text,
      'sha256'
    ), 'hex');

    UPDATE public.marketroute_aws_v0_research_executions
    SET state = 'SUCCEEDED', worker_id = NULL, lease_expires_at = NULL,
        result_json = p_result_json, result_fingerprint = v_result_fingerprint,
        telemetry_json = p_telemetry_json, last_error_code = NULL,
        updated_at = p_at, completed_at = p_at
    WHERE work_unit_id = p_work_unit_id;

    RETURN v_result_fingerprint;
END;
$$;

CREATE FUNCTION public.marketroute_fail_aws_v0_research_execution_v1(
    p_work_unit_id uuid,
    p_envelope_fingerprint text,
    p_worker_id text,
    p_error_code text,
    p_retryable boolean,
    p_telemetry_json jsonb DEFAULT '{}'::jsonb,
    p_at timestamp with time zone DEFAULT now()
) RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_execution public.marketroute_aws_v0_research_executions%ROWTYPE;
    v_state text;
BEGIN
    PERFORM public.marketroute_require_service_role();
    IF p_at IS NULL OR abs(extract(epoch FROM (now() - p_at))) > 300 THEN
        RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RESEARCH_FAILURE_TIME_NOT_CURRENT';
    END IF;
    IF length(btrim(COALESCE(p_error_code, ''))) NOT BETWEEN 1 AND 240
       OR jsonb_typeof(p_telemetry_json) IS DISTINCT FROM 'object'
       OR pg_column_size(p_telemetry_json) > 32768 THEN
        RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RESEARCH_FAILURE_INVALID';
    END IF;

    SELECT * INTO v_execution
    FROM public.marketroute_aws_v0_research_executions
    WHERE work_unit_id = p_work_unit_id
    FOR UPDATE;
    IF NOT FOUND OR v_execution.state <> 'CLAIMED'
       OR v_execution.worker_id IS DISTINCT FROM btrim(COALESCE(p_worker_id, ''))
       OR v_execution.envelope_fingerprint IS DISTINCT FROM p_envelope_fingerprint THEN
        RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RESEARCH_EXECUTION_LEASE_INVALID';
    END IF;

    v_state := CASE
      WHEN COALESCE(p_retryable, false) AND v_execution.attempt_count < 3 THEN 'FAILED_RETRYABLE'
      ELSE 'FAILED_TERMINAL'
    END;
    UPDATE public.marketroute_aws_v0_research_executions
    SET state = v_state, worker_id = NULL, lease_expires_at = NULL,
        telemetry_json = p_telemetry_json,
        last_error_code = left(btrim(p_error_code), 240), updated_at = p_at,
        completed_at = CASE WHEN v_state = 'FAILED_TERMINAL' THEN p_at ELSE NULL END
    WHERE work_unit_id = p_work_unit_id;
    RETURN v_state;
END;
$$;

REVOKE ALL ON TABLE public.marketroute_aws_v0_research_executions FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_claim_aws_v0_research_execution_v1(jsonb, text, text, timestamp with time zone) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_complete_aws_v0_research_execution_v1(uuid, text, text, jsonb, jsonb, timestamp with time zone) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_fail_aws_v0_research_execution_v1(uuid, text, text, text, boolean, jsonb, timestamp with time zone) FROM PUBLIC;

COMMIT;
