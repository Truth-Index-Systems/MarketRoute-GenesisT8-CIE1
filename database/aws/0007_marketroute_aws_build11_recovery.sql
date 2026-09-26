-- Build 11: bounded same-attempt recovery, independent of SQS message retention.
-- Disabled by default. No rewind of canonical attempts; no inferred zero-cost call.
BEGIN;
CREATE TABLE public.marketroute_aws_v0_recovery_control (
  singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
  enabled boolean NOT NULL DEFAULT false,
  max_republishes integer NOT NULL DEFAULT 3 CHECK(max_republishes BETWEEN 1 AND 5)
);
INSERT INTO public.marketroute_aws_v0_recovery_control(singleton) VALUES(true);
CREATE TABLE public.marketroute_aws_v0_recovery_receipts (
  work_unit_id uuid NOT NULL,
  canonical_attempt_number integer NOT NULL,
  state text NOT NULL DEFAULT 'WAITING' CHECK(state IN('WAITING','LEASED','REVIEW_REQUIRED','RESOLVED')),
  reason text NOT NULL,
  highest_receive_count integer NOT NULL DEFAULT 0 CHECK(highest_receive_count BETWEEN 0 AND 1000000),
  republish_count integer NOT NULL DEFAULT 0 CHECK(republish_count BETWEEN 0 AND 5),
  not_before timestamptz NOT NULL DEFAULT now(),
  lease_token uuid,
  lease_until timestamptz,
  coordinator text,
  confirmed_message_id text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(work_unit_id,canonical_attempt_number),
  FOREIGN KEY(work_unit_id,canonical_attempt_number) REFERENCES public.marketroute_aws_v0_research_dispatches(work_unit_id,canonical_attempt_number) ON DELETE RESTRICT,
  CHECK(length(reason) BETWEEN 1 AND 200)
);
CREATE INDEX marketroute_aws_v0_recovery_due ON public.marketroute_aws_v0_recovery_receipts(state,not_before);
COMMENT ON TABLE public.marketroute_aws_v0_recovery_receipts IS
  'Durable transport recovery/review records, not extra credit, a new work identity or sales authority. Never delete failed SQS messages on receipt recording alone.';

-- Workers record queue exhaustion/deferral, but do NOT acknowledge the message.
CREATE FUNCTION public.marketroute_note_aws_v0_transport_failure_v1(
  p_envelope jsonb,p_fingerprint text,p_receive_count integer,p_reason text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $$
DECLARE d public.marketroute_aws_v0_research_dispatches%ROWTYPE;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF p_receive_count IS NULL OR p_receive_count NOT BETWEEN 1 AND 1000000
    OR COALESCE(p_fingerprint,'') !~ '^[a-f0-9]{64}$'
    OR p_reason IS NULL OR p_reason NOT IN('ADMISSION_DEFERRED','FAILED_RETRYABLE','SYNC_PENDING','RESULT_PERSISTENCE_PENDING','BUSY','EXECUTION_ERROR') THEN
    RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RECOVERY_NOTE_INVALID';
  END IF;
  SELECT * INTO d FROM public.marketroute_aws_v0_research_dispatches
    WHERE work_unit_id=(p_envelope->>'workUnitId')::uuid AND envelope_fingerprint=p_fingerprint;
  IF NOT FOUND OR d.envelope_json IS DISTINCT FROM p_envelope THEN
    RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RECOVERY_ENVELOPE_INVALID';
  END IF;
  IF d.state IN('SYNCED','FAILED') THEN RETURN jsonb_build_object('outcome','TERMINAL'); END IF;
  INSERT INTO public.marketroute_aws_v0_recovery_receipts(work_unit_id,canonical_attempt_number,reason,highest_receive_count,not_before)
    VALUES(d.work_unit_id,d.canonical_attempt_number,p_reason,p_receive_count,clock_timestamp()+interval '25 minutes')
    ON CONFLICT(work_unit_id,canonical_attempt_number) DO UPDATE
      SET highest_receive_count=GREATEST(marketroute_aws_v0_recovery_receipts.highest_receive_count,excluded.highest_receive_count),
          updated_at=clock_timestamp();
  RETURN jsonb_build_object('outcome','RECORDED','acknowledge',false);
END $$;

-- Polling is bounded and carries no model invocation permission. Runtime wiring
-- and the disabled controller's rollout are separate deployment gates.
CREATE FUNCTION public.marketroute_list_aws_v0_recovery_candidates_v1(p_limit integer DEFAULT 5)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $$
DECLARE v_result jsonb;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 20 THEN RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RECOVERY_LIMIT_INVALID'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.marketroute_aws_v0_recovery_control WHERE singleton AND enabled) THEN RETURN '[]'::jsonb; END IF;
  SELECT COALESCE(jsonb_agg(row_data),'[]'::jsonb) INTO v_result FROM (
    SELECT jsonb_build_object('envelope',d.envelope_json) row_data
    FROM public.marketroute_aws_v0_research_dispatches d
    LEFT JOIN public.marketroute_aws_v0_recovery_receipts r USING(work_unit_id,canonical_attempt_number)
    WHERE d.state IN('PREPARED','SENT')
      AND (r.state IS NULL OR r.state IN('WAITING','LEASED'))
      AND COALESCE(r.not_before,d.updated_at+interval '25 minutes')<=clock_timestamp()
      AND (r.lease_until IS NULL OR r.lease_until<=clock_timestamp())
    ORDER BY COALESCE(r.not_before,d.updated_at),d.work_unit_id LIMIT p_limit
  ) candidates;
  RETURN v_result;
END $$;

-- One row-locked transition. External publishing happens only AFTER this commits.
CREATE FUNCTION public.marketroute_prepare_aws_v0_recovery_v1(p_envelope jsonb,p_fingerprint text,p_coordinator text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $$
DECLARE
  w public.research_work_units%ROWTYPE;
  x public.marketroute_aws_v0_research_executions%ROWTYPE;
  d public.marketroute_aws_v0_research_dispatches%ROWTYPE;
  j public.background_jobs%ROWTYPE;
  r public.marketroute_aws_v0_recovery_receipts%ROWTYPE;
  a public.marketroute_aws_v0_inference_attempts%ROWTYPE;
  v_at timestamptz;
  v_max integer;
  v_reason text;
  v_sync text;
  v_token uuid;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF jsonb_typeof(p_envelope) IS DISTINCT FROM 'object' OR COALESCE(p_fingerprint,'') !~ '^[a-f0-9]{64}$'
     OR length(btrim(COALESCE(p_coordinator,''))) NOT BETWEEN 1 AND 200 THEN
    RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RECOVERY_INPUT_INVALID';
  END IF;
  SELECT max_republishes INTO v_max FROM public.marketroute_aws_v0_recovery_control WHERE singleton AND enabled;
  IF NOT FOUND THEN RETURN jsonb_build_object('outcome','DISABLED'); END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('MR-AWS-V0-RECOVERY|'||(p_envelope->>'workUnitId'),0));
  SELECT * INTO w FROM public.research_work_units WHERE id=(p_envelope->>'workUnitId')::uuid;
  IF NOT FOUND OR w.action IS DISTINCT FROM 'SYNTHESIZE_COMPANY_UNDERSTANDING' THEN RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RECOVERY_WORK_INVALID'; END IF;
  -- Same lock ordering as admission and synchronization: execution, dispatch, job.
  SELECT * INTO x FROM public.marketroute_aws_v0_research_executions WHERE work_unit_id=w.id FOR UPDATE;
  SELECT * INTO d FROM public.marketroute_aws_v0_research_dispatches
    WHERE work_unit_id=w.id AND envelope_json=p_envelope FOR UPDATE;
  IF NOT FOUND OR (d.envelope_fingerprint IS NOT NULL AND d.envelope_fingerprint IS DISTINCT FROM p_fingerprint)
    OR p_envelope->>'organisationId' IS DISTINCT FROM w.organisation_id::text
    OR p_envelope->>'campaignId' IS DISTINCT FROM w.campaign_id::text
    OR p_envelope->>'companyId' IS DISTINCT FROM w.company_id::text
    OR p_envelope->>'dedupeKey' IS DISTINCT FROM w.dedupe_key
    OR p_envelope->'workUnit'->'payload' IS DISTINCT FROM w.payload_json
    OR (x.work_unit_id IS NOT NULL AND x.envelope_fingerprint IS DISTINCT FROM p_fingerprint) THEN
    RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RECOVERY_ENVELOPE_INVALID';
  END IF;
  SELECT * INTO j FROM public.background_jobs WHERE id=w.background_job_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RECOVERY_JOB_INVALID'; END IF;
  v_at:=clock_timestamp();
  INSERT INTO public.marketroute_aws_v0_recovery_receipts(work_unit_id,canonical_attempt_number,reason,not_before)
    VALUES(w.id,d.canonical_attempt_number,'RECOVERY_REQUESTED',v_at) ON CONFLICT DO NOTHING;
  SELECT * INTO r FROM public.marketroute_aws_v0_recovery_receipts
    WHERE work_unit_id=w.id AND canonical_attempt_number=d.canonical_attempt_number FOR UPDATE;
  IF r.state IN('REVIEW_REQUIRED','RESOLVED') THEN RETURN jsonb_build_object('outcome',r.state,'reason',r.reason); END IF;
  IF j.attempt_count IS DISTINCT FROM d.canonical_attempt_number
    OR j.organisation_id IS DISTINCT FROM w.organisation_id OR j.campaign_id IS DISTINCT FROM w.campaign_id THEN
    v_reason:='CANONICAL_ATTEMPT_OR_SCOPE_CHANGED';
  ELSIF d.state IN('SYNCED','FAILED') AND (
    (d.state='SYNCED' AND (x.state IS DISTINCT FROM 'SUCCEEDED' OR j.status IS DISTINCT FROM 'SUCCEEDED'
      OR NOT EXISTS(SELECT 1 FROM public.marketroute_aws_v0_company_understanding_artifacts z
        WHERE z.work_unit_id=w.id AND z.canonical_attempt_number=d.canonical_attempt_number
          AND z.organisation_id=w.organisation_id AND z.campaign_id=w.campaign_id AND z.company_id=w.company_id
          AND z.result_fingerprint=x.result_fingerprint AND z.result_json=x.result_json)))
    OR (d.state='FAILED' AND (x.state IS DISTINCT FROM 'FAILED_TERMINAL' OR j.status IS DISTINCT FROM 'FAILED'))
  ) THEN v_reason:='TERMINAL_RECEIPT_REQUIRES_REVIEW';
  ELSIF d.state IN('SYNCED','FAILED') THEN
    UPDATE public.marketroute_aws_v0_recovery_receipts SET state='RESOLVED',reason='ALREADY_TERMINAL',lease_until=NULL,updated_at=v_at
      WHERE work_unit_id=w.id AND canonical_attempt_number=d.canonical_attempt_number;
    RETURN jsonb_build_object('outcome','RESOLVED');
  ELSIF j.status IS DISTINCT FROM 'RUNNING' OR j.reserved_by_run_id IS DISTINCT FROM d.scheduler_run_id THEN
    v_reason:='CANONICAL_OWNERSHIP_CHANGED';
  ELSIF x.state IN('SUCCEEDED','FAILED_TERMINAL') THEN
    -- No provider call and no need to revive an expired transport ownership deadline.
    BEGIN
      IF x.state='SUCCEEDED' THEN
        v_sync:=public.marketroute_sync_aws_v0_research_execution_v1(w.id,p_fingerprint,x.result_fingerprint,v_at);
      ELSE
        v_sync:=public.marketroute_sync_aws_v0_research_failure_v1(w.id,p_fingerprint,v_at);
      END IF;
      IF v_sync IS NULL OR v_sync NOT IN('SYNCED','ALREADY_SYNCED','FAILED_SYNCED','ALREADY_FAILED') THEN RAISE EXCEPTION 'SYNC_BLOCKED'; END IF;
      UPDATE public.marketroute_aws_v0_recovery_receipts SET state='RESOLVED',reason='DURABLE_RESULT_SYNCHRONIZED',lease_until=NULL,updated_at=v_at
        WHERE work_unit_id=w.id AND canonical_attempt_number=d.canonical_attempt_number;
      RETURN jsonb_build_object('outcome','RESOLVED','syncState',v_sync);
    EXCEPTION WHEN OTHERS THEN v_reason:='STORED_RESULT_SYNC_REQUIRES_REVIEW'; END;
  ELSIF x.state='CLAIMED' AND x.lease_expires_at IS NULL THEN
    v_reason:='EXECUTION_DEADLINE_REQUIRES_REVIEW';
  ELSIF x.state='CLAIMED' AND x.lease_expires_at+interval '60 seconds'>v_at THEN
    RETURN jsonb_build_object('outcome','BUSY');
  END IF;
  IF v_reason IS NULL AND (r.not_before>v_at OR r.lease_until>v_at) THEN RETURN jsonb_build_object('outcome','BUSY'); END IF;
  IF v_reason IS NULL THEN
    -- No blind recovery of an invocation whose result may have been lost. Keep
    -- the reservation; human reconciliation or a distinct new job is required.
    SELECT * INTO a FROM public.marketroute_aws_v0_inference_attempts
      WHERE work_unit_id=w.id AND canonical_attempt_number=d.canonical_attempt_number
        AND (state IN('RESERVED','UNKNOWN') OR (x.state='CLAIMED' AND execution_attempt_number=x.attempt_count))
      ORDER BY execution_attempt_number DESC LIMIT 1;
    IF FOUND THEN v_reason:='PROVIDER_OUTCOME_REQUIRES_REVIEW';
    ELSIF x.work_unit_id IS NOT NULL AND
      (SELECT count(*) FROM public.marketroute_aws_v0_inference_attempts WHERE work_unit_id=w.id AND canonical_attempt_number=d.canonical_attempt_number)
        <> (x.attempt_count - (CASE WHEN x.state='CLAIMED' THEN 1 ELSE 0 END)) THEN
      v_reason:='ATTEMPT_ACCOUNTING_REQUIRES_REVIEW';
    ELSIF r.republish_count>=v_max OR d.prepared_at+interval '24 hours'<=v_at THEN
      v_reason:='RECOVERY_LIMIT_REQUIRES_REVIEW';
    ELSIF NOT EXISTS(SELECT 1 FROM public.research_budget_events e
      WHERE e.work_unit_id=w.id AND e.attempt_number=d.canonical_attempt_number AND e.event_type='RESERVE'
        AND e.amount_usd>=w.cost_ceiling_usd AND NOT EXISTS(SELECT 1 FROM public.research_budget_events s
          WHERE s.work_unit_id=w.id AND s.attempt_number=d.canonical_attempt_number AND s.event_type IN('COMMIT','RELEASE'))) THEN
      v_reason:='CANONICAL_RESERVATION_REQUIRES_REVIEW';
    END IF;
  END IF;
  IF v_reason IS NOT NULL THEN
    UPDATE public.marketroute_aws_v0_recovery_receipts SET state='REVIEW_REQUIRED',reason=v_reason,lease_until=NULL,updated_at=v_at
      WHERE work_unit_id=w.id AND canonical_attempt_number=d.canonical_attempt_number;
    RETURN jsonb_build_object('outcome','REVIEW_REQUIRED','reason',v_reason);
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.campaigns c JOIN public.organisations o ON o.id=c.organisation_id
       JOIN public.research_budget_policies p ON p.campaign_id=c.id AND p.organisation_id=c.organisation_id
       WHERE c.id=w.campaign_id AND c.organisation_id=w.organisation_id AND c.workflow_state='ACTIVE' AND o.status='ACTIVE' AND p.enabled)
    OR NOT EXISTS(SELECT 1 FROM public.marketroute_aws_v0_inference_scopes WHERE
       scope_key='801132668416:eu-west-2:EU:anthropic.claude-sonnet-4-5-20250929-v1:0' AND enabled) THEN
    UPDATE public.marketroute_aws_v0_recovery_receipts SET state='WAITING',reason='POLICY_NOT_READY',not_before=v_at+interval '5 minutes',lease_until=NULL,updated_at=v_at
      WHERE work_unit_id=w.id AND canonical_attempt_number=d.canonical_attempt_number;
    RETURN jsonb_build_object('outcome','WAITING');
  END IF;
  IF x.state='CLAIMED' THEN
    -- No receipt for this claim; all previous provider attempts were accounted.
    UPDATE public.marketroute_aws_v0_research_executions SET state='FAILED_RETRYABLE',
      attempt_count=attempt_count-1,worker_id=NULL,lease_expires_at=NULL,
      last_error_code='MARKETROUTE_AWS_V0_RECOVERED_BEFORE_ADMISSION',updated_at=v_at WHERE work_unit_id=w.id;
  END IF;
  v_token:=gen_random_uuid();
  UPDATE public.marketroute_aws_v0_recovery_receipts SET state='LEASED',reason='REDELIVERY_PREPARED',
    lease_token=v_token,lease_until=v_at+interval '60 seconds',not_before=v_at+interval '25 minutes',
    coordinator=p_coordinator,confirmed_message_id=NULL,republish_count=republish_count+1,updated_at=v_at
    WHERE work_unit_id=w.id AND canonical_attempt_number=d.canonical_attempt_number;
  -- Preserve the exact stored envelope, original canonical attempt and budget.
  UPDATE public.marketroute_aws_v0_research_dispatches SET envelope_fingerprint=p_fingerprint,
    ownership_expires_at=CASE WHEN state='SENT' THEN v_at+interval '130 minutes' ELSE ownership_expires_at END,
    updated_at=v_at WHERE work_unit_id=w.id AND canonical_attempt_number=d.canonical_attempt_number;
  RETURN jsonb_build_object('outcome','REDELIVER','envelope',d.envelope_json,'leaseToken',v_token,
    'startBefore',v_at+interval '60 seconds','canonicalAttempt',d.canonical_attempt_number);
END $$;

CREATE FUNCTION public.marketroute_confirm_aws_v0_recovery_send_v1(p_work uuid,p_attempt integer,p_token uuid,p_coordinator text,p_fingerprint text,p_message text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $$
DECLARE d public.marketroute_aws_v0_research_dispatches%ROWTYPE; r public.marketroute_aws_v0_recovery_receipts%ROWTYPE; j public.background_jobs%ROWTYPE;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF length(btrim(COALESCE(p_message,''))) NOT BETWEEN 1 AND 256 THEN RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RECOVERY_MESSAGE_INVALID'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('MR-AWS-V0-RECOVERY|'||p_work::text,0));
  PERFORM 1 FROM public.marketroute_aws_v0_research_executions WHERE work_unit_id=p_work FOR UPDATE;
  SELECT * INTO d FROM public.marketroute_aws_v0_research_dispatches WHERE work_unit_id=p_work AND canonical_attempt_number=p_attempt FOR UPDATE;
  IF NOT FOUND OR d.envelope_fingerprint IS DISTINCT FROM p_fingerprint THEN RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RECOVERY_ENVELOPE_INVALID'; END IF;
  SELECT b.* INTO j FROM public.background_jobs b JOIN public.research_work_units w ON w.background_job_id=b.id WHERE w.id=p_work FOR UPDATE OF b;
  SELECT * INTO r FROM public.marketroute_aws_v0_recovery_receipts WHERE work_unit_id=p_work AND canonical_attempt_number=p_attempt FOR UPDATE;
  IF NOT FOUND OR r.lease_token IS DISTINCT FROM p_token OR r.coordinator IS DISTINCT FROM p_coordinator THEN RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RECOVERY_LEASE_INVALID'; END IF;
  IF r.confirmed_message_id IS NOT NULL THEN
    IF r.confirmed_message_id IS DISTINCT FROM p_message THEN RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RECOVERY_CONFIRM_COLLISION'; END IF;
    RETURN jsonb_build_object('outcome','ALREADY_CONFIRMED');
  END IF;
  IF r.state<>'LEASED' OR r.lease_until IS NULL OR r.lease_until<=clock_timestamp() OR j.attempt_count IS DISTINCT FROM p_attempt THEN
    RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RECOVERY_LEASE_INVALID';
  END IF;
  IF d.state NOT IN('SYNCED','FAILED') THEN
    IF j.status IS DISTINCT FROM 'RUNNING' OR j.reserved_by_run_id IS DISTINCT FROM d.scheduler_run_id THEN RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RECOVERY_JOB_INVALID'; END IF;
    UPDATE public.marketroute_aws_v0_research_dispatches SET state='SENT',sqs_message_id=COALESCE(sqs_message_id,p_message),
      sent_at=COALESCE(sent_at,clock_timestamp()),ownership_expires_at=clock_timestamp()+interval '130 minutes',updated_at=clock_timestamp()
      WHERE work_unit_id=p_work AND canonical_attempt_number=p_attempt;
  END IF;
  UPDATE public.marketroute_aws_v0_recovery_receipts SET state=CASE WHEN d.state IN('SYNCED','FAILED') THEN 'RESOLVED' ELSE 'WAITING' END,
    reason='REDELIVERY_CONFIRMED',confirmed_message_id=p_message,lease_until=NULL,not_before=clock_timestamp()+interval '25 minutes',updated_at=clock_timestamp()
    WHERE work_unit_id=p_work AND canonical_attempt_number=p_attempt;
  RETURN jsonb_build_object('outcome','CONFIRMED');
END $$;

-- Replace v2 in place so the packaged adapter and existing callers use the repair.
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
  PERFORM pg_advisory_xact_lock(hashtextextended('MR-AWS-V0-RECOVERY|'||(p_envelope->>'workUnitId'),0));
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

  -- Receipt recovery is independent of queue visibility/dispatch expiry. Scope,
  -- fingerprint and the exact canonical attempt were checked above.
  IF v_dispatch.state='SENT' AND v_job.status='RUNNING'
    AND v_job.reserved_by_run_id=v_dispatch.scheduler_run_id THEN
    IF v_execution.state='SUCCEEDED' THEN
      RETURN jsonb_build_object('outcome','DEDUPLICATED','attemptCount',v_execution.attempt_count,'resultFingerprint',v_execution.result_fingerprint);
    ELSIF v_execution.state='FAILED_TERMINAL' THEN
      RETURN jsonb_build_object('outcome','TERMINAL','attemptCount',v_execution.attempt_count,'errorCode',v_execution.last_error_code);
    END IF;
  END IF;
  IF EXISTS(SELECT 1 FROM public.marketroute_aws_v0_recovery_receipts r WHERE
    r.work_unit_id=v_work.id AND r.canonical_attempt_number=v_dispatch.canonical_attempt_number
    AND r.state='REVIEW_REQUIRED') THEN
    RETURN jsonb_build_object('outcome','BUSY','recoveryRequired',true);
  END IF;
  IF v_execution.state='FAILED_RETRYABLE' AND EXISTS(SELECT 1 FROM public.marketroute_aws_v0_inference_attempts a
    WHERE a.work_unit_id=v_work.id AND a.canonical_attempt_number=v_dispatch.canonical_attempt_number
      AND a.state IN('RESERVED','UNKNOWN')) THEN
    RETURN jsonb_build_object('outcome','BUSY','recoveryRequired',true);
  END IF;
  IF v_execution.state='CLAIMED' AND
    (v_execution.lease_expires_at IS NULL OR v_execution.lease_expires_at<=p_at) THEN
    -- Only the bounded recovery routine can reconcile a crashed attempt. A
    -- repeat SQS delivery must not invent another paid invocation.
    RETURN jsonb_build_object('outcome','BUSY','recoveryRequired',true);
  END IF;
  -- Only new inference still requires live dispatch ownership.
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


-- AWS work is recovered without a new canonical attempt or budget allocation.
CREATE OR REPLACE FUNCTION public.marketroute_recover_abandoned_research_work_v1(p_scheduler_run_id uuid,p_at timestamp with time zone DEFAULT now()) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE v_row record; v_count integer:=0; v_terminal boolean;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF NOT EXISTS(SELECT 1 FROM public.scheduler_runs r JOIN public.scheduler_leases l ON l.owner_run_id=r.id AND l.lease_key='GENESIS_RESEARCH_V1' WHERE r.id=p_scheduler_run_id AND r.status='RUNNING' AND r.runner_key='GENESIS_RESEARCH_V1' AND l.expires_at>p_at) THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_SCHEDULER_LEASE_NOT_OWNED'; END IF;
  FOR v_row IN
    SELECT j.id job_id,j.attempt_count,j.max_attempts,j.reserved_by_run_id,w.id work_unit_id,w.organisation_id,w.campaign_id,w.cost_ceiling_usd
    FROM public.background_jobs j JOIN public.research_work_units w ON w.background_job_id=j.id
    WHERE j.job_type='GENESIS_RESEARCH_V1' AND j.status='RUNNING'
      AND (j.reserved_by_run_id IS NULL OR NOT EXISTS(SELECT 1 FROM public.scheduler_leases l WHERE l.owner_run_id=j.reserved_by_run_id AND l.lease_key='GENESIS_RESEARCH_V1' AND l.expires_at>p_at))
      AND NOT EXISTS(SELECT 1 FROM public.marketroute_aws_v0_research_dispatches d WHERE d.work_unit_id=w.id )
    ORDER BY j.reserved_at NULLS FIRST,j.id FOR UPDATE OF j SKIP LOCKED
  LOOP
    IF NOT EXISTS(SELECT 1 FROM public.research_budget_events e WHERE e.work_unit_id=v_row.work_unit_id AND e.attempt_number=v_row.attempt_count AND e.event_type IN('COMMIT','RELEASE')) THEN
      INSERT INTO public.research_budget_events(organisation_id,campaign_id,work_unit_id,scheduler_run_id,attempt_number,event_type,amount_usd,occurred_at,metadata_json)
      VALUES(v_row.organisation_id,v_row.campaign_id,v_row.work_unit_id,p_scheduler_run_id,v_row.attempt_count,'COMMIT',v_row.cost_ceiling_usd,p_at,jsonb_build_object('abandonedAttempt',true,'conservativeCharge',true,'recoveredWithoutLiveLease',true));
    END IF;
    v_terminal:=v_row.attempt_count>=v_row.max_attempts;
    UPDATE public.background_job_attempts SET status='ABORTED',completed_at=p_at,error_code='MARKETROUTE_RESEARCH_ABANDONED_ATTEMPT',telemetry_json=COALESCE(telemetry_json,'{}'::jsonb)||jsonb_build_object('recoveredByRunId',p_scheduler_run_id) WHERE job_id=v_row.job_id AND attempt_number=v_row.attempt_count AND status='RUNNING';
    UPDATE public.background_jobs SET status=CASE WHEN v_terminal THEN 'FAILED' ELSE 'PENDING' END,available_at=CASE WHEN v_terminal THEN available_at ELSE p_at END,reserved_by_run_id=NULL,reserved_at=NULL,last_error_code='MARKETROUTE_RESEARCH_ABANDONED_ATTEMPT',updated_at=p_at WHERE id=v_row.job_id;
    v_count:=v_count+1;
  END LOOP;
  UPDATE public.scheduler_runs r SET status='CANCELLED',completed_at=COALESCE(completed_at,p_at),metadata_json=COALESCE(metadata_json,'{}'::jsonb)||jsonb_build_object('leaseExpired',true,'recoveredByRunId',p_scheduler_run_id)
  WHERE r.runner_key='GENESIS_RESEARCH_V1' AND r.status='RUNNING' AND r.id<>p_scheduler_run_id
    AND NOT EXISTS(SELECT 1 FROM public.scheduler_leases l WHERE l.owner_run_id=r.id AND l.lease_key='GENESIS_RESEARCH_V1' AND l.expires_at>p_at);
  RETURN v_count;
END;
$$;


CREATE OR REPLACE FUNCTION public.marketroute_mark_aws_v0_research_dispatch_sent_v1(
    p_work_unit_id uuid,
    p_scheduler_run_id uuid,
    p_envelope_fingerprint text,
    p_sqs_message_id text,
    p_at timestamp with time zone DEFAULT now()
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE v_job public.background_jobs%ROWTYPE; v_dispatch public.marketroute_aws_v0_research_dispatches%ROWTYPE;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF p_at IS NULL OR abs(extract(epoch FROM(now()-p_at)))>300 OR COALESCE(p_envelope_fingerprint,'')!~'^[a-f0-9]{64}$' OR length(btrim(COALESCE(p_sqs_message_id,''))) NOT BETWEEN 1 AND 256 THEN
    RAISE EXCEPTION 'MARKETROUTE_AWS_V0_DISPATCH_SENT_INVALID';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('MR-AWS-V0-RECOVERY|'||p_work_unit_id::text,0));
  PERFORM 1 FROM public.marketroute_aws_v0_research_executions WHERE work_unit_id=p_work_unit_id FOR UPDATE;
  PERFORM 1 FROM public.marketroute_aws_v0_research_dispatches WHERE work_unit_id=p_work_unit_id ORDER BY canonical_attempt_number FOR UPDATE;
  SELECT j.* INTO v_job FROM public.background_jobs j JOIN public.research_work_units w ON w.background_job_id=j.id WHERE w.id=p_work_unit_id FOR UPDATE OF j;
  IF NOT FOUND OR v_job.status<>'RUNNING' OR v_job.reserved_by_run_id IS DISTINCT FROM p_scheduler_run_id THEN RAISE EXCEPTION 'MARKETROUTE_AWS_V0_DISPATCH_CANONICAL_OWNERSHIP_INVALID'; END IF;
  SELECT * INTO v_dispatch FROM public.marketroute_aws_v0_research_dispatches WHERE work_unit_id=p_work_unit_id AND canonical_attempt_number=v_job.attempt_count FOR UPDATE;
  IF NOT FOUND OR v_dispatch.scheduler_run_id IS DISTINCT FROM p_scheduler_run_id OR v_dispatch.state NOT IN('PREPARED','SENT') THEN RAISE EXCEPTION 'MARKETROUTE_AWS_V0_DISPATCH_NOT_PREPARED'; END IF;
  IF v_dispatch.state='SENT' AND v_dispatch.envelope_fingerprint IS DISTINCT FROM p_envelope_fingerprint THEN RAISE EXCEPTION 'MARKETROUTE_AWS_V0_DISPATCH_IDEMPOTENCY_COLLISION'; END IF;
  UPDATE public.marketroute_aws_v0_research_dispatches SET state='SENT',envelope_fingerprint=p_envelope_fingerprint,sqs_message_id=COALESCE(sqs_message_id,btrim(p_sqs_message_id)),ownership_expires_at=GREATEST(COALESCE(ownership_expires_at,p_at),p_at+interval '130 minutes'),sent_at=COALESCE(sent_at,p_at),updated_at=p_at
  WHERE work_unit_id=p_work_unit_id AND canonical_attempt_number=v_job.attempt_count;
END;
$$;


REVOKE ALL ON TABLE public.marketroute_aws_v0_recovery_control FROM PUBLIC;
REVOKE ALL ON TABLE public.marketroute_aws_v0_recovery_receipts FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_note_aws_v0_transport_failure_v1(jsonb,text,integer,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_list_aws_v0_recovery_candidates_v1(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_prepare_aws_v0_recovery_v1(jsonb,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_confirm_aws_v0_recovery_send_v1(uuid,integer,uuid,text,text,text) FROM PUBLIC;
COMMIT;
