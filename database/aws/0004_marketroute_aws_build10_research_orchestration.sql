-- MarketRoute AWS V0 Build 10
-- Planner/dispatcher/worker/synchronizer split with durable dispatch ownership.
-- Semantic artifacts are never Truth, R4/R5/R6 authority, or execution permission.

BEGIN;

ALTER TABLE public.research_work_units
  DROP CONSTRAINT research_work_units_action_check;
ALTER TABLE public.research_work_units
  ADD CONSTRAINT research_work_units_action_check CHECK (action = ANY (ARRAY[
    'ACQUIRE_CLAIM_EVIDENCE'::text,
    'SYNTHESIZE_COMPANY_UNDERSTANDING'::text,
    'DISCOVER_ROUTE_STRUCTURE'::text,
    'RESEARCH_CONTACT_BINDING'::text,
    'REVALIDATE_R4'::text,
    'REVALIDATE_R5'::text,
    'REVALIDATE_R6'::text
  ]));

CREATE TABLE public.marketroute_aws_v0_research_dispatches (
    work_unit_id uuid NOT NULL,
    canonical_attempt_number integer NOT NULL,
    scheduler_run_id uuid NOT NULL,
    dispatch_contract_version text DEFAULT 'MR-AWS-V0-RESEARCH-DISPATCH-1.0.0'::text NOT NULL,
    sync_contract_version text DEFAULT 'MR-AWS-V0-COMPANY-UNDERSTANDING-SYNC-1.0.0'::text NOT NULL,
    state text NOT NULL,
    envelope_json jsonb NOT NULL,
    envelope_fingerprint text,
    sqs_message_id text,
    ownership_expires_at timestamp with time zone,
    last_error_code text,
    prepared_at timestamp with time zone NOT NULL,
    sent_at timestamp with time zone,
    synced_at timestamp with time zone,
    updated_at timestamp with time zone NOT NULL,
    CONSTRAINT marketroute_aws_v0_research_dispatches_pkey PRIMARY KEY (work_unit_id, canonical_attempt_number),
    CONSTRAINT marketroute_aws_v0_research_dispatches_work_fkey FOREIGN KEY (work_unit_id) REFERENCES public.research_work_units(id) ON DELETE RESTRICT,
    CONSTRAINT marketroute_aws_v0_research_dispatches_run_fkey FOREIGN KEY (scheduler_run_id) REFERENCES public.scheduler_runs(id) ON DELETE RESTRICT,
    CONSTRAINT marketroute_aws_v0_research_dispatches_attempt_check CHECK (canonical_attempt_number > 0),
    CONSTRAINT marketroute_aws_v0_research_dispatches_dispatch_contract_check CHECK (dispatch_contract_version = 'MR-AWS-V0-RESEARCH-DISPATCH-1.0.0'::text),
    CONSTRAINT marketroute_aws_v0_research_dispatches_sync_contract_check CHECK (sync_contract_version = 'MR-AWS-V0-COMPANY-UNDERSTANDING-SYNC-1.0.0'::text),
    CONSTRAINT marketroute_aws_v0_research_dispatches_state_check CHECK (state = ANY (ARRAY['PREPARED'::text,'SENT'::text,'SYNCED'::text,'FAILED'::text])),
    CONSTRAINT marketroute_aws_v0_research_dispatches_envelope_check CHECK (jsonb_typeof(envelope_json) = 'object'::text),
    CONSTRAINT marketroute_aws_v0_research_dispatches_fingerprint_check CHECK (envelope_fingerprint IS NULL OR envelope_fingerprint ~ '^[a-f0-9]{64}$'::text),
    CONSTRAINT marketroute_aws_v0_research_dispatches_message_check CHECK (sqs_message_id IS NULL OR length(sqs_message_id) BETWEEN 1 AND 256)
);

CREATE UNIQUE INDEX marketroute_aws_v0_research_dispatches_envelope_unique
  ON public.marketroute_aws_v0_research_dispatches(envelope_fingerprint)
  WHERE envelope_fingerprint IS NOT NULL;
CREATE INDEX marketroute_aws_v0_research_dispatches_recovery_idx
  ON public.marketroute_aws_v0_research_dispatches(state,ownership_expires_at,updated_at);

CREATE TABLE public.marketroute_aws_v0_company_understanding_artifacts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    work_unit_id uuid NOT NULL,
    canonical_attempt_number integer NOT NULL,
    organisation_id uuid NOT NULL,
    campaign_id uuid NOT NULL,
    company_id uuid NOT NULL,
    result_json jsonb NOT NULL,
    result_fingerprint text NOT NULL,
    evidence_item_ids uuid[] NOT NULL,
    semantic_contract_version text DEFAULT 'MR-AWS-V0-COMPANY-UNDERSTANDING-1.0.0'::text NOT NULL,
    sync_contract_version text DEFAULT 'MR-AWS-V0-COMPANY-UNDERSTANDING-SYNC-1.0.0'::text NOT NULL,
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT marketroute_aws_v0_company_understanding_artifacts_pkey PRIMARY KEY (id),
    CONSTRAINT marketroute_aws_v0_company_understanding_artifacts_attempt_unique UNIQUE (work_unit_id, canonical_attempt_number),
    CONSTRAINT marketroute_aws_v0_company_understanding_artifacts_work_fkey FOREIGN KEY (work_unit_id) REFERENCES public.research_work_units(id) ON DELETE RESTRICT,
    CONSTRAINT marketroute_aws_v0_company_understanding_artifacts_org_fkey FOREIGN KEY (organisation_id) REFERENCES public.organisations(id) ON DELETE RESTRICT,
    CONSTRAINT marketroute_aws_v0_company_understanding_artifacts_campaign_scope_fkey FOREIGN KEY (organisation_id,campaign_id) REFERENCES public.campaigns(organisation_id,id) ON DELETE RESTRICT,
    CONSTRAINT marketroute_aws_v0_company_understanding_artifacts_company_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT,
    CONSTRAINT marketroute_aws_v0_company_understanding_artifacts_result_check CHECK (jsonb_typeof(result_json) = 'object'::text),
    CONSTRAINT marketroute_aws_v0_company_understanding_artifacts_result_fingerprint_check CHECK (result_fingerprint ~ '^[a-f0-9]{64}$'::text),
    CONSTRAINT marketroute_aws_v0_company_understanding_artifacts_evidence_check CHECK (cardinality(evidence_item_ids) BETWEEN 1 AND 40),
    CONSTRAINT marketroute_aws_v0_company_understanding_artifacts_semantic_contract_check CHECK (semantic_contract_version = 'MR-AWS-V0-COMPANY-UNDERSTANDING-1.0.0'::text),
    CONSTRAINT marketroute_aws_v0_company_understanding_artifacts_sync_contract_check CHECK (sync_contract_version = 'MR-AWS-V0-COMPANY-UNDERSTANDING-SYNC-1.0.0'::text)
);

COMMENT ON TABLE public.marketroute_aws_v0_company_understanding_artifacts IS
  'Evidence-grounded semantic artifacts only. Rows grant no Truth, R4/R5/R6 authority, ranking, scoring, viability, or execution permission.';

CREATE FUNCTION public.marketroute_prepare_aws_v0_research_dispatch_v1(
    p_work_unit_id uuid,
    p_scheduler_run_id uuid,
    p_at timestamp with time zone DEFAULT now()
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
  v_work public.research_work_units%ROWTYPE;
  v_job public.background_jobs%ROWTYPE;
  v_existing public.marketroute_aws_v0_research_dispatches%ROWTYPE;
  v_executor jsonb;
  v_origin text;
  v_envelope jsonb;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF p_at IS NULL OR abs(extract(epoch FROM(now()-p_at)))>300 THEN RAISE EXCEPTION 'MARKETROUTE_AWS_V0_DISPATCH_TIME_NOT_CURRENT'; END IF;
  SELECT * INTO v_work FROM public.research_work_units WHERE id=p_work_unit_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_AWS_V0_DISPATCH_WORK_NOT_FOUND'; END IF;
  SELECT * INTO v_job FROM public.background_jobs WHERE id=v_work.background_job_id FOR UPDATE;
  IF NOT FOUND OR v_job.status<>'RUNNING' OR v_job.reserved_by_run_id IS DISTINCT FROM p_scheduler_run_id THEN
    RAISE EXCEPTION 'MARKETROUTE_AWS_V0_DISPATCH_CANONICAL_OWNERSHIP_INVALID';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.scheduler_runs r WHERE r.id=p_scheduler_run_id AND r.runner_key='GENESIS_RESEARCH_V1') THEN
    RAISE EXCEPTION 'MARKETROUTE_AWS_V0_DISPATCH_RUN_INVALID';
  END IF;

  v_executor:=v_work.payload_json->'metadata'->'awsV0Executor';
  IF v_work.action<>'SYNTHESIZE_COMPANY_UNDERSTANDING'
     OR v_executor->>'contractVersion'<>'MR-AWS-V0-COMPANY-UNDERSTANDING-1.0.0'
     OR v_executor->>'operation'<>'ai.companyUnderstanding'
     OR v_work.payload_json->'metadata'->>'awsV0SyncContractVersion'<>'MR-AWS-V0-COMPANY-UNDERSTANDING-SYNC-1.0.0'
     OR jsonb_typeof(v_executor->'input'->'evidence') IS DISTINCT FROM 'array'
     OR jsonb_array_length(v_executor->'input'->'evidence') NOT BETWEEN 1 AND 40
     OR EXISTS(
       SELECT 1 FROM jsonb_array_elements(v_executor->'input'->'evidence') e
       WHERE COALESCE(e->>'evidenceId','') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
     ) THEN
    RAISE EXCEPTION 'MARKETROUTE_AWS_V0_DISPATCH_CAPABILITY_UNSUPPORTED';
  END IF;
  v_origin:=COALESCE(v_work.payload_json->>'researchOrigin','CUSTOMER_CAMPAIGN');
  IF v_origin NOT IN('CUSTOMER_CAMPAIGN','CUSTOMER_REFRESH','SYSTEM_RETRY') THEN RAISE EXCEPTION 'MARKETROUTE_AWS_V0_DISPATCH_ORIGIN_UNSUPPORTED'; END IF;

  SELECT * INTO v_existing FROM public.marketroute_aws_v0_research_dispatches
  WHERE work_unit_id=v_work.id AND canonical_attempt_number=v_job.attempt_count FOR UPDATE;
  IF FOUND THEN
    IF v_existing.scheduler_run_id IS DISTINCT FROM p_scheduler_run_id THEN RAISE EXCEPTION 'MARKETROUTE_AWS_V0_DISPATCH_IDEMPOTENCY_COLLISION'; END IF;
    RETURN v_existing.envelope_json;
  END IF;

  v_envelope:=jsonb_build_object(
    'schemaVersion','1','transport','AWS_SQS','workUnitId',v_work.id,'enqueuedAt',p_at,
    'organisationId',v_work.organisation_id,'campaignId',v_work.campaign_id,'companyId',v_work.company_id,
    'researchOrigin',v_origin,'dedupeKey',v_work.dedupe_key,
    'workUnit',jsonb_build_object(
      'ordinal',v_work.ordinal,'gapKey',v_work.gap_key,'layer',v_work.layer,'tier',v_work.tier,
      'action',v_work.action,'subjectType',v_work.subject_type,'subjectId',v_work.subject_id,
      'claimKey',v_work.claim_key,'reasonCode',v_work.reason_code,'queryHints',v_work.query_hints_json,
      'costCeilingUsd',v_work.cost_ceiling_usd,'dedupeKey',v_work.dedupe_key,'payload',v_work.payload_json
    )
  );

  INSERT INTO public.marketroute_aws_v0_research_dispatches(
    work_unit_id,canonical_attempt_number,scheduler_run_id,state,envelope_json,prepared_at,updated_at
  ) VALUES(v_work.id,v_job.attempt_count,p_scheduler_run_id,'PREPARED',v_envelope,p_at,p_at)
  ON CONFLICT DO NOTHING;
  SELECT * INTO v_existing FROM public.marketroute_aws_v0_research_dispatches
  WHERE work_unit_id=v_work.id AND canonical_attempt_number=v_job.attempt_count FOR UPDATE;
  IF NOT FOUND OR v_existing.scheduler_run_id IS DISTINCT FROM p_scheduler_run_id THEN
    RAISE EXCEPTION 'MARKETROUTE_AWS_V0_DISPATCH_IDEMPOTENCY_COLLISION';
  END IF;
  RETURN v_existing.envelope_json;
END;
$$;

CREATE FUNCTION public.marketroute_mark_aws_v0_research_dispatch_sent_v1(
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
  SELECT j.* INTO v_job FROM public.background_jobs j JOIN public.research_work_units w ON w.background_job_id=j.id WHERE w.id=p_work_unit_id FOR UPDATE OF j;
  IF NOT FOUND OR v_job.status<>'RUNNING' OR v_job.reserved_by_run_id IS DISTINCT FROM p_scheduler_run_id THEN RAISE EXCEPTION 'MARKETROUTE_AWS_V0_DISPATCH_CANONICAL_OWNERSHIP_INVALID'; END IF;
  SELECT * INTO v_dispatch FROM public.marketroute_aws_v0_research_dispatches WHERE work_unit_id=p_work_unit_id AND canonical_attempt_number=v_job.attempt_count FOR UPDATE;
  IF NOT FOUND OR v_dispatch.scheduler_run_id IS DISTINCT FROM p_scheduler_run_id OR v_dispatch.state NOT IN('PREPARED','SENT') THEN RAISE EXCEPTION 'MARKETROUTE_AWS_V0_DISPATCH_NOT_PREPARED'; END IF;
  IF v_dispatch.state='SENT' AND v_dispatch.envelope_fingerprint IS DISTINCT FROM p_envelope_fingerprint THEN RAISE EXCEPTION 'MARKETROUTE_AWS_V0_DISPATCH_IDEMPOTENCY_COLLISION'; END IF;
  UPDATE public.marketroute_aws_v0_research_dispatches SET state='SENT',envelope_fingerprint=p_envelope_fingerprint,sqs_message_id=COALESCE(sqs_message_id,btrim(p_sqs_message_id)),ownership_expires_at=GREATEST(COALESCE(ownership_expires_at,p_at),p_at+interval '130 minutes'),sent_at=COALESCE(sent_at,p_at),updated_at=p_at
  WHERE work_unit_id=p_work_unit_id AND canonical_attempt_number=v_job.attempt_count;
END;
$$;

CREATE FUNCTION public.marketroute_fail_aws_v0_research_dispatch_v1(
    p_work_unit_id uuid,
    p_scheduler_run_id uuid,
    p_error_code text,
    p_retryable boolean,
    p_at timestamp with time zone DEFAULT now()
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE v_attempt integer; v_dispatch_state text;
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT j.attempt_count INTO v_attempt FROM public.background_jobs j JOIN public.research_work_units w ON w.background_job_id=j.id
  WHERE w.id=p_work_unit_id AND j.status='RUNNING' AND j.reserved_by_run_id=p_scheduler_run_id FOR UPDATE OF j;
  IF v_attempt IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_AWS_V0_DISPATCH_CANONICAL_OWNERSHIP_INVALID'; END IF;
  SELECT state INTO v_dispatch_state FROM public.marketroute_aws_v0_research_dispatches WHERE work_unit_id=p_work_unit_id AND canonical_attempt_number=v_attempt FOR UPDATE;
  IF v_dispatch_state='SENT' THEN RETURN; END IF;
  UPDATE public.marketroute_aws_v0_research_dispatches SET state='FAILED',last_error_code=left(COALESCE(NULLIF(btrim(p_error_code),''),'MARKETROUTE_AWS_V0_DISPATCH_FAILED'),240),ownership_expires_at=NULL,updated_at=p_at
  WHERE work_unit_id=p_work_unit_id AND canonical_attempt_number=v_attempt AND state='PREPARED';
  PERFORM public.marketroute_fail_research_work_v1(p_work_unit_id,p_scheduler_run_id,left(COALESCE(NULLIF(btrim(p_error_code),''),'MARKETROUTE_AWS_V0_DISPATCH_FAILED'),200),0,COALESCE(p_retryable,true),p_at);
END;
$$;

CREATE FUNCTION public.marketroute_claim_aws_v0_research_execution_v2(
    p_envelope jsonb,
    p_envelope_fingerprint text,
    p_worker_id text,
    p_at timestamp with time zone DEFAULT now()
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
  v_work public.research_work_units%ROWTYPE;
  v_job public.background_jobs%ROWTYPE;
  v_dispatch public.marketroute_aws_v0_research_dispatches%ROWTYPE;
  v_execution public.marketroute_aws_v0_research_executions%ROWTYPE;
  v_worker text:=btrim(COALESCE(p_worker_id,''));
  v_inserted integer:=0;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF p_at IS NULL OR abs(extract(epoch FROM(now()-p_at)))>300 THEN RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RESEARCH_CLAIM_TIME_NOT_CURRENT'; END IF;
  IF jsonb_typeof(p_envelope) IS DISTINCT FROM 'object' OR COALESCE(p_envelope_fingerprint,'')!~'^[a-f0-9]{64}$' OR length(v_worker) NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RESEARCH_CLAIM_INVALID'; END IF;
  SELECT * INTO v_work FROM public.research_work_units WHERE id=(p_envelope->>'workUnitId')::uuid;
  IF NOT FOUND OR v_work.action<>'SYNTHESIZE_COMPANY_UNDERSTANDING' THEN RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RESEARCH_EXECUTOR_CAPABILITY_UNSUPPORTED'; END IF;
  SELECT * INTO v_job FROM public.background_jobs WHERE id=v_work.background_job_id;
  SELECT * INTO v_dispatch FROM public.marketroute_aws_v0_research_dispatches
  WHERE work_unit_id=v_work.id AND envelope_fingerprint=p_envelope_fingerprint;
  IF NOT FOUND OR v_dispatch.state<>'SENT' OR v_dispatch.ownership_expires_at<=p_at OR v_dispatch.envelope_json IS DISTINCT FROM p_envelope
     OR v_job.status<>'RUNNING' OR v_job.reserved_by_run_id IS DISTINCT FROM v_dispatch.scheduler_run_id
     OR v_job.attempt_count IS DISTINCT FROM v_dispatch.canonical_attempt_number THEN
    RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RESEARCH_DISPATCH_OWNERSHIP_INVALID';
  END IF;
  IF v_work.payload_json->'metadata'->'awsV0Executor'->>'contractVersion'<>'MR-AWS-V0-COMPANY-UNDERSTANDING-1.0.0'
     OR v_work.payload_json->'metadata'->'awsV0Executor'->>'operation'<>'ai.companyUnderstanding'
     OR v_work.payload_json->'metadata'->>'awsV0SyncContractVersion'<>'MR-AWS-V0-COMPANY-UNDERSTANDING-SYNC-1.0.0' THEN
    RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RESEARCH_EXECUTOR_CAPABILITY_UNSUPPORTED';
  END IF;

  INSERT INTO public.marketroute_aws_v0_research_executions(work_unit_id,dedupe_key,envelope_fingerprint,state,worker_id,attempt_count,lease_expires_at,created_at,updated_at)
  VALUES(v_work.id,v_work.dedupe_key,p_envelope_fingerprint,'CLAIMED',v_worker,1,p_at+interval '210 seconds',p_at,p_at)
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_inserted=ROW_COUNT;
  SELECT * INTO v_execution FROM public.marketroute_aws_v0_research_executions WHERE dedupe_key=v_work.dedupe_key FOR UPDATE;
  IF NOT FOUND OR v_execution.work_unit_id<>v_work.id OR v_execution.envelope_fingerprint<>p_envelope_fingerprint THEN RAISE EXCEPTION 'MARKETROUTE_AWS_V0_RESEARCH_IDEMPOTENCY_COLLISION'; END IF;
  IF v_inserted=1 THEN RETURN jsonb_build_object('outcome','CLAIMED','attemptCount',1,'leaseExpiresAt',v_execution.lease_expires_at); END IF;
  IF v_execution.state='SUCCEEDED' THEN RETURN jsonb_build_object('outcome','DEDUPLICATED','attemptCount',v_execution.attempt_count,'resultFingerprint',v_execution.result_fingerprint); END IF;
  IF v_execution.state='FAILED_TERMINAL' THEN RETURN jsonb_build_object('outcome','TERMINAL','attemptCount',v_execution.attempt_count,'errorCode',v_execution.last_error_code); END IF;
  IF v_execution.state='CLAIMED' AND v_execution.lease_expires_at>p_at THEN RETURN jsonb_build_object('outcome','BUSY','attemptCount',v_execution.attempt_count,'leaseExpiresAt',v_execution.lease_expires_at); END IF;
  IF v_execution.attempt_count>=3 THEN
    UPDATE public.marketroute_aws_v0_research_executions SET state='FAILED_TERMINAL',worker_id=NULL,lease_expires_at=NULL,last_error_code='MARKETROUTE_AWS_V0_RESEARCH_ATTEMPT_CEILING_REACHED',updated_at=p_at WHERE work_unit_id=v_work.id;
    RETURN jsonb_build_object('outcome','TERMINAL','attemptCount',v_execution.attempt_count,'errorCode','MARKETROUTE_AWS_V0_RESEARCH_ATTEMPT_CEILING_REACHED');
  END IF;
  UPDATE public.marketroute_aws_v0_research_executions SET state='CLAIMED',worker_id=v_worker,attempt_count=attempt_count+1,lease_expires_at=p_at+interval '210 seconds',last_error_code=NULL,updated_at=p_at WHERE work_unit_id=v_work.id RETURNING * INTO v_execution;
  RETURN jsonb_build_object('outcome','CLAIMED','attemptCount',v_execution.attempt_count,'leaseExpiresAt',v_execution.lease_expires_at);
END;
$$;

CREATE FUNCTION public.marketroute_sync_aws_v0_research_execution_v1(
    p_work_unit_id uuid,
    p_envelope_fingerprint text,
    p_result_fingerprint text,
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
  v_input jsonb;
  v_input_ids uuid[];
  v_cited_ids uuid[];
  v_cost numeric;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF p_at IS NULL OR abs(extract(epoch FROM(now()-p_at)))>300 THEN RAISE EXCEPTION 'MARKETROUTE_AWS_V0_SYNC_TIME_NOT_CURRENT'; END IF;
  SELECT * INTO v_work FROM public.research_work_units WHERE id=p_work_unit_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_AWS_V0_SYNC_WORK_NOT_FOUND'; END IF;
  IF v_work.action<>'SYNTHESIZE_COMPANY_UNDERSTANDING' THEN RETURN 'BLOCKED_CAPABILITY'; END IF;
  SELECT * INTO v_execution FROM public.marketroute_aws_v0_research_executions WHERE work_unit_id=v_work.id FOR UPDATE;
  IF NOT FOUND OR v_execution.state<>'SUCCEEDED' OR v_execution.envelope_fingerprint IS DISTINCT FROM p_envelope_fingerprint OR v_execution.result_fingerprint IS DISTINCT FROM p_result_fingerprint THEN RAISE EXCEPTION 'MARKETROUTE_AWS_V0_SYNC_EXECUTION_INVALID'; END IF;
  SELECT * INTO v_dispatch FROM public.marketroute_aws_v0_research_dispatches WHERE work_unit_id=v_work.id AND envelope_fingerprint=p_envelope_fingerprint FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_AWS_V0_SYNC_DISPATCH_NOT_FOUND'; END IF;
  IF v_dispatch.state='SYNCED' THEN RETURN 'ALREADY_SYNCED'; END IF;
  IF v_dispatch.state<>'SENT' THEN RAISE EXCEPTION 'MARKETROUTE_AWS_V0_SYNC_DISPATCH_INVALID'; END IF;
  SELECT * INTO v_job FROM public.background_jobs WHERE id=v_work.background_job_id FOR UPDATE;
  IF v_job.status<>'RUNNING' OR v_job.reserved_by_run_id IS DISTINCT FROM v_dispatch.scheduler_run_id OR v_job.attempt_count IS DISTINCT FROM v_dispatch.canonical_attempt_number THEN RAISE EXCEPTION 'MARKETROUTE_AWS_V0_SYNC_CANONICAL_OWNERSHIP_INVALID'; END IF;
  IF v_execution.result_json->>'contractVersion'<>'MR-AWS-V0-COMPANY-UNDERSTANDING-1.0.0'
     OR v_execution.result_json->>'operation'<>'ai.companyUnderstanding'
     OR COALESCE((v_execution.result_json->>'canonicalPersistenceAllowed')::boolean,true)
     OR COALESCE((v_execution.result_json->>'truthAuthorityGranted')::boolean,true)
     OR COALESCE((v_execution.result_json->>'deterministicCommercialAuthorityGranted')::boolean,true) THEN
    RAISE EXCEPTION 'MARKETROUTE_AWS_V0_SYNC_AUTHORITY_BOUNDARY_INVALID';
  END IF;

  v_input:=v_work.payload_json->'metadata'->'awsV0Executor'->'input';
  SELECT array_agg(DISTINCT (e->>'evidenceId')::uuid ORDER BY (e->>'evidenceId')::uuid) INTO v_input_ids FROM jsonb_array_elements(v_input->'evidence') e;
  SELECT array_agg(DISTINCT x.id ORDER BY x.id) INTO v_cited_ids FROM (
    SELECT jsonb_array_elements_text(v_execution.result_json#>'{value,overview,evidenceIds}')::uuid id
    UNION ALL SELECT jsonb_array_elements_text(s->'evidenceIds')::uuid FROM jsonb_array_elements(v_execution.result_json#>'{value,businessActivities}') s
    UNION ALL SELECT jsonb_array_elements_text(s->'evidenceIds')::uuid FROM jsonb_array_elements(v_execution.result_json#>'{value,offerings}') s
    UNION ALL SELECT jsonb_array_elements_text(s->'evidenceIds')::uuid FROM jsonb_array_elements(v_execution.result_json#>'{value,customerTypes}') s
    UNION ALL SELECT jsonb_array_elements_text(s->'evidenceIds')::uuid FROM jsonb_array_elements(v_execution.result_json#>'{value,operatingSignals}') s
  ) x;
  IF v_input_ids IS NULL OR v_cited_ids IS NULL OR NOT v_cited_ids <@ v_input_ids THEN RAISE EXCEPTION 'MARKETROUTE_AWS_V0_SYNC_EVIDENCE_CITATION_INVALID'; END IF;
  IF EXISTS(
    SELECT 1 FROM jsonb_array_elements(v_input->'evidence') supplied
    LEFT JOIN public.evidence_items e ON e.id=(supplied->>'evidenceId')::uuid
    LEFT JOIN public.source_acquisitions a ON a.id=e.acquisition_id
    LEFT JOIN public.source_records s ON s.id=a.source_id
    WHERE e.id IS NULL OR e.subject_type<>'COMPANY' OR e.subject_id<>v_work.company_id
      OR (e.tenant_scope_organisation_id IS NOT NULL AND e.tenant_scope_organisation_id<>v_work.organisation_id)
      OR supplied->>'statement' IS DISTINCT FROM e.excerpt_text
      OR NULLIF(supplied->>'observedAt','')::timestamptz IS DISTINCT FROM e.observed_at
      OR supplied->>'sourceType' IS DISTINCT FROM CASE s.source_kind WHEN 'WEB' THEN 'WEBSITE' WHEN 'REGISTRY' THEN 'REGISTRY' WHEN 'DOCUMENT' THEN 'DOCUMENT' ELSE 'OTHER' END
  ) THEN RAISE EXCEPTION 'MARKETROUTE_AWS_V0_SYNC_EVIDENCE_SCOPE_OR_CONTENT_INVALID'; END IF;
  BEGIN v_cost:=(v_execution.telemetry_json->>'estimatedEquivalentCostUsd')::numeric; EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'MARKETROUTE_AWS_V0_SYNC_COST_INVALID'; END;
  IF v_cost<0 OR v_cost>v_work.cost_ceiling_usd THEN RAISE EXCEPTION 'MARKETROUTE_AWS_V0_SYNC_COST_INVALID'; END IF;

  INSERT INTO public.marketroute_aws_v0_company_understanding_artifacts(work_unit_id,canonical_attempt_number,organisation_id,campaign_id,company_id,result_json,result_fingerprint,evidence_item_ids,created_at)
  VALUES(v_work.id,v_job.attempt_count,v_work.organisation_id,v_work.campaign_id,v_work.company_id,v_execution.result_json,v_execution.result_fingerprint,v_cited_ids,p_at)
  ON CONFLICT(work_unit_id,canonical_attempt_number) DO NOTHING;
  IF NOT EXISTS(SELECT 1 FROM public.marketroute_aws_v0_company_understanding_artifacts a WHERE a.work_unit_id=v_work.id AND a.canonical_attempt_number=v_job.attempt_count AND a.result_fingerprint=v_execution.result_fingerprint) THEN RAISE EXCEPTION 'MARKETROUTE_AWS_V0_SYNC_IDEMPOTENCY_COLLISION'; END IF;
  PERFORM public.marketroute_complete_research_work_v1(v_work.id,v_dispatch.scheduler_run_id,v_cost,jsonb_build_object('awsV0',true,'semanticArtifactOnly',true,'resultFingerprint',v_execution.result_fingerprint,'syncContractVersion','MR-AWS-V0-COMPANY-UNDERSTANDING-SYNC-1.0.0'),p_at);
  UPDATE public.marketroute_aws_v0_research_dispatches SET state='SYNCED',ownership_expires_at=NULL,synced_at=p_at,updated_at=p_at WHERE work_unit_id=v_work.id AND canonical_attempt_number=v_job.attempt_count;
  RETURN 'SYNCED';
END;
$$;

CREATE FUNCTION public.marketroute_sync_aws_v0_research_failure_v1(
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
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF p_at IS NULL OR abs(extract(epoch FROM(now()-p_at)))>300 THEN RAISE EXCEPTION 'MARKETROUTE_AWS_V0_SYNC_TIME_NOT_CURRENT'; END IF;
  SELECT * INTO v_work FROM public.research_work_units WHERE id=p_work_unit_id;
  IF NOT FOUND OR v_work.action<>'SYNTHESIZE_COMPANY_UNDERSTANDING' THEN RETURN 'BLOCKED_CAPABILITY'; END IF;
  SELECT * INTO v_dispatch FROM public.marketroute_aws_v0_research_dispatches WHERE work_unit_id=v_work.id AND envelope_fingerprint=p_envelope_fingerprint FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_AWS_V0_SYNC_DISPATCH_NOT_FOUND'; END IF;
  IF v_dispatch.state='FAILED' THEN RETURN 'ALREADY_FAILED'; END IF;
  SELECT * INTO v_execution FROM public.marketroute_aws_v0_research_executions WHERE work_unit_id=v_work.id FOR UPDATE;
  IF NOT FOUND OR v_execution.state<>'FAILED_TERMINAL' OR v_execution.envelope_fingerprint IS DISTINCT FROM p_envelope_fingerprint THEN RAISE EXCEPTION 'MARKETROUTE_AWS_V0_SYNC_FAILURE_INVALID'; END IF;
  SELECT * INTO v_job FROM public.background_jobs WHERE id=v_work.background_job_id FOR UPDATE;
  IF v_job.status<>'RUNNING' OR v_job.reserved_by_run_id IS DISTINCT FROM v_dispatch.scheduler_run_id OR v_job.attempt_count IS DISTINCT FROM v_dispatch.canonical_attempt_number THEN RAISE EXCEPTION 'MARKETROUTE_AWS_V0_SYNC_CANONICAL_OWNERSHIP_INVALID'; END IF;
  PERFORM public.marketroute_fail_research_work_v1(v_work.id,v_dispatch.scheduler_run_id,COALESCE(v_execution.last_error_code,'MARKETROUTE_AWS_V0_RESEARCH_EXECUTION_FAILED'),v_work.cost_ceiling_usd,false,p_at);
  UPDATE public.marketroute_aws_v0_research_dispatches SET state='FAILED',ownership_expires_at=NULL,last_error_code=COALESCE(v_execution.last_error_code,'MARKETROUTE_AWS_V0_RESEARCH_EXECUTION_FAILED'),updated_at=p_at WHERE work_unit_id=v_work.id AND canonical_attempt_number=v_job.attempt_count;
  RETURN 'FAILED_SYNCED';
END;
$$;

CREATE OR REPLACE FUNCTION public.marketroute_recover_abandoned_research_work_v1(p_scheduler_run_id uuid,p_at timestamp with time zone DEFAULT now()) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE v_row record; v_count integer:=0; v_terminal boolean;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.scheduler_runs r JOIN public.scheduler_leases l ON l.owner_run_id=r.id AND l.lease_key='GENESIS_RESEARCH_V1' WHERE r.id=p_scheduler_run_id AND r.status='RUNNING' AND r.runner_key='GENESIS_RESEARCH_V1' AND l.expires_at>p_at) THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_SCHEDULER_LEASE_NOT_OWNED'; END IF;
  FOR v_row IN
    SELECT j.id job_id,j.attempt_count,j.max_attempts,j.reserved_by_run_id,w.id work_unit_id,w.organisation_id,w.campaign_id,w.cost_ceiling_usd
    FROM public.background_jobs j JOIN public.research_work_units w ON w.background_job_id=j.id
    WHERE j.job_type='GENESIS_RESEARCH_V1' AND j.status='RUNNING'
      AND (j.reserved_by_run_id IS NULL OR NOT EXISTS(SELECT 1 FROM public.scheduler_leases l WHERE l.owner_run_id=j.reserved_by_run_id AND l.lease_key='GENESIS_RESEARCH_V1' AND l.expires_at>p_at))
      AND NOT EXISTS(SELECT 1 FROM public.marketroute_aws_v0_research_dispatches d WHERE d.work_unit_id=w.id AND d.canonical_attempt_number=j.attempt_count AND d.state='SENT' AND d.ownership_expires_at>p_at)
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

REVOKE ALL ON TABLE public.marketroute_aws_v0_research_dispatches FROM PUBLIC;
REVOKE ALL ON TABLE public.marketroute_aws_v0_company_understanding_artifacts FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_prepare_aws_v0_research_dispatch_v1(uuid,uuid,timestamp with time zone) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_mark_aws_v0_research_dispatch_sent_v1(uuid,uuid,text,text,timestamp with time zone) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_fail_aws_v0_research_dispatch_v1(uuid,uuid,text,boolean,timestamp with time zone) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_claim_aws_v0_research_execution_v2(jsonb,text,text,timestamp with time zone) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_sync_aws_v0_research_execution_v1(uuid,text,text,timestamp with time zone) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_sync_aws_v0_research_failure_v1(uuid,text,timestamp with time zone) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_recover_abandoned_research_work_v1(uuid,timestamp with time zone) FROM PUBLIC;

COMMIT;
