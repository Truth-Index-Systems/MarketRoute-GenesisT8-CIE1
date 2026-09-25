-- AWS V0 Build 11: validate durable terminal receipts before active ownership.
-- Forward-only research transport repair. No canonical authority writer changes.
BEGIN;

CREATE OR REPLACE FUNCTION public.marketroute_claim_aws_v0_research_execution_v2(
  p_envelope jsonb,
  p_envelope_fingerprint text,
  p_worker_id text,
  p_at timestamp with time zone DEFAULT now()
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
  v_work public.research_work_units%ROWTYPE;
  v_job public.background_jobs%ROWTYPE;
  v_dispatch public.marketroute_aws_v0_research_dispatches%ROWTYPE;
  v_execution public.marketroute_aws_v0_research_executions%ROWTYPE;
  v_worker text := btrim(COALESCE(p_worker_id,''));
  v_inserted integer := 0;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF p_at IS NULL OR abs(extract(epoch FROM(now()-p_at)))>300 THEN
    RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RESEARCH_CLAIM_TIME_NOT_CURRENT';
  END IF;
  IF jsonb_typeof(p_envelope) IS DISTINCT FROM 'object'
     OR COALESCE(p_envelope_fingerprint,'') !~ '^[a-f0-9]{64}$'
     OR length(v_worker) NOT BETWEEN 1 AND 200 THEN
    RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RESEARCH_CLAIM_INVALID';
  END IF;
  SELECT * INTO v_work FROM public.research_work_units
    WHERE id=(p_envelope->>'workUnitId')::uuid;
  IF NOT FOUND OR v_work.action IS DISTINCT FROM 'SYNTHESIZE_COMPANY_UNDERSTANDING' THEN
    RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RESEARCH_EXECUTOR_CAPABILITY_UNSUPPORTED';
  END IF;
  SELECT * INTO v_job FROM public.background_jobs WHERE id=v_work.background_job_id;
  IF NOT FOUND OR v_job.job_type IS DISTINCT FROM 'GENESIS_RESEARCH_V1' THEN
    RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RESEARCH_DISPATCH_OWNERSHIP_INVALID';
  END IF;
  SELECT * INTO v_dispatch FROM public.marketroute_aws_v0_research_dispatches
    WHERE work_unit_id=v_work.id AND envelope_fingerprint=p_envelope_fingerprint;
  IF NOT FOUND OR v_dispatch.envelope_json IS DISTINCT FROM p_envelope
     OR p_envelope->>'schemaVersion' IS DISTINCT FROM '1'
     OR p_envelope->>'transport' IS DISTINCT FROM 'AWS_SQS'
     OR p_envelope->>'organisationId' IS DISTINCT FROM v_work.organisation_id::text
     OR p_envelope->>'campaignId' IS DISTINCT FROM v_work.campaign_id::text
     OR p_envelope->>'companyId' IS DISTINCT FROM v_work.company_id::text
     OR p_envelope->>'dedupeKey' IS DISTINCT FROM v_work.dedupe_key
     OR p_envelope->'workUnit'->>'dedupeKey' IS DISTINCT FROM v_work.dedupe_key
     OR p_envelope->'workUnit'->>'action' IS DISTINCT FROM v_work.action
     OR p_envelope->'workUnit'->'payload' IS DISTINCT FROM v_work.payload_json
     OR v_job.attempt_count IS DISTINCT FROM v_dispatch.canonical_attempt_number THEN
    RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RESEARCH_ENVELOPE_OR_ATTEMPT_MISMATCH';
  END IF;
  IF v_work.payload_json#>>'{metadata,awsV0Executor,contractVersion}'
       IS DISTINCT FROM 'MR-AWS-V0-COMPANY-UNDERSTANDING-1.0.0'
     OR v_work.payload_json#>>'{metadata,awsV0Executor,operation}'
       IS DISTINCT FROM 'ai.companyUnderstanding'
     OR v_work.payload_json#>>'{metadata,awsV0SyncContractVersion}'
       IS DISTINCT FROM 'MR-AWS-V0-COMPANY-UNDERSTANDING-SYNC-1.0.0' THEN
    RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RESEARCH_EXECUTOR_CAPABILITY_UNSUPPORTED';
  END IF;

  -- Receipt lookup precedes live ownership checks, but never identity checks.
  -- Lock only execution here, matching synchronizer's execution-first ordering.
  SELECT * INTO v_execution FROM public.marketroute_aws_v0_research_executions
    WHERE work_unit_id=v_work.id FOR UPDATE;
  IF FOUND AND (v_execution.dedupe_key IS DISTINCT FROM v_work.dedupe_key
       OR v_execution.envelope_fingerprint IS DISTINCT FROM p_envelope_fingerprint) THEN
    RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RESEARCH_IDEMPOTENCY_COLLISION';
  END IF;
  IF v_dispatch.state='SYNCED' THEN
    IF v_execution.state IS DISTINCT FROM 'SUCCEEDED'
       OR v_job.status IS DISTINCT FROM 'SUCCEEDED'
       OR v_execution.result_fingerprint IS NULL
       OR NOT EXISTS (
         SELECT 1 FROM public.marketroute_aws_v0_company_understanding_artifacts a
         WHERE a.work_unit_id=v_work.id
           AND a.canonical_attempt_number=v_dispatch.canonical_attempt_number
           AND a.organisation_id=v_work.organisation_id
           AND a.campaign_id=v_work.campaign_id AND a.company_id=v_work.company_id
           AND a.result_fingerprint=v_execution.result_fingerprint
           AND a.result_json=v_execution.result_json
       ) THEN
      RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RESEARCH_TERMINAL_RECEIPT_INVALID';
    END IF;
    RETURN jsonb_build_object('outcome','DEDUPLICATED','attemptCount',v_execution.attempt_count,
      'resultFingerprint',v_execution.result_fingerprint);
  END IF;
  IF v_dispatch.state='FAILED' THEN
    IF v_execution.state IS DISTINCT FROM 'FAILED_TERMINAL'
       OR v_job.status IS DISTINCT FROM 'FAILED' THEN
      RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RESEARCH_TERMINAL_RECEIPT_INVALID';
    END IF;
    RETURN jsonb_build_object('outcome','TERMINAL','attemptCount',v_execution.attempt_count,
      'errorCode',v_execution.last_error_code);
  END IF;

  -- Any new execution or unfinished synchronization still requires live ownership.
  IF v_dispatch.state IS DISTINCT FROM 'SENT'
     OR v_dispatch.ownership_expires_at IS NULL OR v_dispatch.ownership_expires_at<=p_at
     OR v_job.status IS DISTINCT FROM 'RUNNING'
     OR v_job.reserved_by_run_id IS DISTINCT FROM v_dispatch.scheduler_run_id THEN
    RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RESEARCH_DISPATCH_OWNERSHIP_INVALID';
  END IF;
  INSERT INTO public.marketroute_aws_v0_research_executions
    (work_unit_id,dedupe_key,envelope_fingerprint,state,worker_id,attempt_count,
     lease_expires_at,created_at,updated_at)
  VALUES(v_work.id,v_work.dedupe_key,p_envelope_fingerprint,'CLAIMED',v_worker,1,
    p_at+interval '210 seconds',p_at,p_at) ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_inserted=ROW_COUNT;
  SELECT * INTO v_execution FROM public.marketroute_aws_v0_research_executions
    WHERE dedupe_key=v_work.dedupe_key FOR UPDATE;
  IF NOT FOUND OR v_execution.work_unit_id IS DISTINCT FROM v_work.id
     OR v_execution.envelope_fingerprint IS DISTINCT FROM p_envelope_fingerprint THEN
    RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RESEARCH_IDEMPOTENCY_COLLISION';
  END IF;
  IF v_inserted=1 THEN
    RETURN jsonb_build_object('outcome','CLAIMED','attemptCount',1,'leaseExpiresAt',v_execution.lease_expires_at);
  END IF;
  IF v_execution.state='SUCCEEDED' THEN
    RETURN jsonb_build_object('outcome','DEDUPLICATED','attemptCount',v_execution.attempt_count,
      'resultFingerprint',v_execution.result_fingerprint);
  END IF;
  IF v_execution.state='FAILED_TERMINAL' THEN
    RETURN jsonb_build_object('outcome','TERMINAL','attemptCount',v_execution.attempt_count,
      'errorCode',v_execution.last_error_code);
  END IF;
  IF v_execution.state='CLAIMED' AND v_execution.lease_expires_at>p_at THEN
    RETURN jsonb_build_object('outcome','BUSY','attemptCount',v_execution.attempt_count,
      'leaseExpiresAt',v_execution.lease_expires_at);
  END IF;
  IF v_execution.attempt_count>=3 THEN
    UPDATE public.marketroute_aws_v0_research_executions SET state='FAILED_TERMINAL',
      worker_id=NULL,lease_expires_at=NULL,
      last_error_code='MARKETROUTE_AWS_V0_RESEARCH_ATTEMPT_CEILING_REACHED',updated_at=p_at
      WHERE work_unit_id=v_work.id;
    RETURN jsonb_build_object('outcome','TERMINAL','attemptCount',v_execution.attempt_count,
      'errorCode','MARKETROUTE_AWS_V0_RESEARCH_ATTEMPT_CEILING_REACHED');
  END IF;
  UPDATE public.marketroute_aws_v0_research_executions SET state='CLAIMED',worker_id=v_worker,
    attempt_count=attempt_count+1,lease_expires_at=p_at+interval '210 seconds',
    last_error_code=NULL,updated_at=p_at WHERE work_unit_id=v_work.id RETURNING * INTO v_execution;
  RETURN jsonb_build_object('outcome','CLAIMED','attemptCount',v_execution.attempt_count,
    'leaseExpiresAt',v_execution.lease_expires_at);
END;
$$;

REVOKE ALL ON FUNCTION public.marketroute_claim_aws_v0_research_execution_v2
  (jsonb,text,text,timestamp with time zone) FROM PUBLIC;
COMMIT;
