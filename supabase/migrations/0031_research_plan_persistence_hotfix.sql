BEGIN;

-- MarketRoute V2 research-plan persistence hotfix 0.18.3.11.
--
-- PostgreSQL serialises timestamptz values in JSONB with a numeric UTC offset,
-- while JavaScript Date#toISOString emits the same instant with a trailing Z.
-- The original work-unit fingerprint recomputation compared those different
-- textual forms. The table-return columns also shadowed unqualified table
-- columns in the plan deduplication queries. Both failures occur before any
-- research provider call and add no commercial-authority writer.

CREATE OR REPLACE FUNCTION public.marketroute_persist_research_plan_v1(
  p_context jsonb,
  p_planner_version text,
  p_semantics_version text,
  p_gap_set_fingerprint text,
  p_work_units jsonb
)
RETURNS TABLE(
  plan_id uuid,
  created_work_units integer,
  plan_fingerprint text,
  deduplicated boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_expected jsonb;
  v_policy jsonb;
  v_budget jsonb;
  v_plan uuid;
  v_existing public.research_plan_runs%ROWTYPE;
  v_item jsonb;
  v_candidate jsonb;
  v_count integer := 0;
  v_expected_fp text;
  v_gap_fp text;
  v_sum numeric := 0;
  v_expected_count integer;
  v_expected_ceiling numeric;
  v_expected_dedupe text;
  v_max_units integer;
  v_slots integer;
  v_daily numeric;
  v_job numeric;
  v_spent numeric;
  v_reserved numeric;
  v_active integer;
  v_job_id uuid;
  v_ord integer := 0;
  v_remaining_plan numeric;
  v_reference_iso text;
BEGIN
  IF p_planner_version <> 'MRV2-RESEARCH-PLANNER-1.0.0'
     OR p_semantics_version <> 'MRV2-RESEARCH-SEMANTICS-1.0.0' THEN
    RAISE EXCEPTION 'MARKETROUTE_RESEARCH_VERSION_MISMATCH';
  END IF;
  IF jsonb_typeof(p_context) <> 'object'
     OR jsonb_typeof(p_work_units) <> 'array' THEN
    RAISE EXCEPTION 'MARKETROUTE_RESEARCH_PLAN_PAYLOAD_INVALID';
  END IF;
  IF abs(extract(epoch FROM (
    ((p_context->>'referenceTime')::timestamptz) - now()
  ))) > 300 THEN
    RAISE EXCEPTION 'MARKETROUTE_RESEARCH_PLAN_REFERENCE_TIME_NOT_CURRENT';
  END IF;

  v_expected := public.marketroute_research_gap_context_v1(
    (p_context->>'organisationId')::uuid,
    (p_context->>'campaignId')::uuid,
    (p_context->>'companyId')::uuid,
    (p_context->>'referenceTime')::timestamptz
  );
  IF v_expected <> p_context THEN
    RAISE EXCEPTION 'MARKETROUTE_RESEARCH_CONTEXT_STALE_OR_TAMPERED';
  END IF;

  v_gap_fp := v_expected->>'gapSetFingerprint';
  IF v_gap_fp <> p_gap_set_fingerprint THEN
    RAISE EXCEPTION 'MARKETROUTE_RESEARCH_GAP_FINGERPRINT_MISMATCH';
  END IF;

  -- Exact cross-runtime timestamp canonicalisation used by Date#toISOString.
  v_reference_iso := to_char(
    (v_expected->>'referenceTime')::timestamptz AT TIME ZONE 'UTC',
    'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'
  );

  v_policy := v_expected->'policy';
  v_budget := v_expected->'budget';
  v_daily := (v_policy->>'dailyBudgetUsd')::numeric;
  v_job := (v_policy->>'maxJobCostUsd')::numeric;
  v_spent := (v_budget->>'spentTodayUsd')::numeric;
  v_reserved := (v_budget->>'reservedTodayUsd')::numeric;
  v_active := (v_budget->>'activeJobs')::integer;
  v_slots := greatest(0, (v_policy->>'maxConcurrentJobs')::integer - v_active);
  v_max_units := least((v_policy->>'maxWorkUnitsPerPlan')::integer, v_slots);

  IF jsonb_array_length(p_work_units) > v_max_units THEN
    RAISE EXCEPTION 'MARKETROUTE_RESEARCH_CONCURRENCY_OR_PLAN_LIMIT_EXCEEDED';
  END IF;

  v_expected_count := 0;
  v_remaining_plan := greatest(0, v_daily - v_spent - v_reserved);
  FOR v_candidate IN
    SELECT value
    FROM jsonb_array_elements(v_expected->'candidates')
      WITH ORDINALITY AS x(value, ord)
    ORDER BY ord
  LOOP
    EXIT WHEN v_expected_count >= v_max_units;
    IF v_candidate->>'action' IN (
      'REVALIDATE_R4','REVALIDATE_R5','REVALIDATE_R6'
    ) THEN
      v_expected_count := v_expected_count + 1;
    ELSIF v_remaining_plan > 0 AND v_job > 0 THEN
      v_expected_count := v_expected_count + 1;
      v_remaining_plan := greatest(
        0,
        v_remaining_plan - least(v_job, v_remaining_plan)
      );
    ELSE
      EXIT;
    END IF;
  END LOOP;

  IF jsonb_array_length(p_work_units) <> v_expected_count THEN
    RAISE EXCEPTION 'MARKETROUTE_RESEARCH_REQUIRED_WORK_SET_INCOMPLETE';
  END IF;

  FOR v_item IN
    SELECT value
    FROM jsonb_array_elements(p_work_units) AS x(value)
    ORDER BY (value->>'ordinal')::integer
  LOOP
    v_ord := v_ord + 1;
    IF (v_item->>'ordinal')::integer <> v_ord THEN
      RAISE EXCEPTION 'MARKETROUTE_RESEARCH_WORK_ORDER_INVALID';
    END IF;

    SELECT x.value
    INTO v_candidate
    FROM jsonb_array_elements(v_expected->'candidates')
      WITH ORDINALITY AS x(value, ord)
    WHERE x.ord = v_ord;

    IF v_candidate IS NULL
       OR v_candidate->>'gapKey' <> v_item->>'gapKey' THEN
      RAISE EXCEPTION 'MARKETROUTE_RESEARCH_WORK_GAP_NOT_CURRENT_OR_REORDERED';
    END IF;
    IF v_item->>'layer' <> v_candidate->>'layer'
       OR v_item->>'tier' <> v_candidate->>'tier'
       OR v_item->>'action' <> v_candidate->>'action'
       OR v_item->>'subjectType' <> v_candidate->>'subjectType'
       OR v_item->>'subjectId' <> v_candidate->>'subjectId'
       OR COALESCE(v_item->>'claimKey','') <> COALESCE(v_candidate->>'claimKey','')
       OR v_item->>'reasonCode' <> v_candidate->>'reasonCode' THEN
      RAISE EXCEPTION 'MARKETROUTE_RESEARCH_WORK_PREMISE_MISMATCH';
    END IF;

    v_expected_ceiling := CASE
      WHEN v_candidate->>'action' IN (
        'REVALIDATE_R4','REVALIDATE_R5','REVALIDATE_R6'
      ) THEN 0
      ELSE least(v_job, greatest(0, v_daily - v_spent - v_reserved - v_sum))
    END;
    IF (v_item->>'costCeilingUsd')::numeric <> v_expected_ceiling THEN
      RAISE EXCEPTION 'MARKETROUTE_RESEARCH_JOB_BUDGET_ALLOCATION_MISMATCH';
    END IF;

    v_expected_dedupe := encode(extensions.digest(concat_ws(
      '|',
      'MRV2-RESEARCH-WORK-1.0.0',
      v_expected->>'organisationId',
      v_expected->>'campaignId',
      v_expected->>'companyId',
      p_gap_set_fingerprint,
      v_reference_iso,
      v_item->>'gapKey',
      v_item->>'costCeilingUsd'
    ), 'sha256'), 'hex');
    IF v_item->>'dedupeKey' <> v_expected_dedupe THEN
      RAISE EXCEPTION 'MARKETROUTE_RESEARCH_WORK_DEDUPE_MISMATCH';
    END IF;
    v_sum := v_sum + v_expected_ceiling;
  END LOOP;

  IF v_sum > greatest(0, v_daily - v_spent - v_reserved) THEN
    RAISE EXCEPTION 'MARKETROUTE_RESEARCH_DAILY_BUDGET_EXCEEDED';
  END IF;

  v_expected_fp := encode(extensions.digest(
    'MRV2-RESEARCH-PLAN-1.0.0|' || jsonb_build_object(
      'organisationId',v_expected->>'organisationId',
      'campaignId',v_expected->>'campaignId',
      'companyId',v_expected->>'companyId',
      'referenceTime',to_jsonb((v_expected->>'referenceTime')::timestamptz),
      'lifecycleState',v_expected->>'lifecycleState',
      'authorityEnvelopeFingerprint',v_expected->>'authorityEnvelopeFingerprint',
      'gapSetFingerprint',p_gap_set_fingerprint,
      'workUnits',p_work_units
    )::text,
    'sha256'
  ), 'hex');

  SELECT p.*
  INTO v_existing
  FROM public.research_plan_runs AS p
  WHERE p.plan_fingerprint = v_expected_fp;
  IF FOUND THEN
    RETURN QUERY
    SELECT
      v_existing.id,
      (
        SELECT count(*)::integer
        FROM public.research_work_units AS w
        WHERE w.plan_id = v_existing.id
      ),
      v_existing.plan_fingerprint,
      true;
    RETURN;
  END IF;

  INSERT INTO public.research_plan_runs(
    organisation_id,
    campaign_id,
    company_id,
    reference_time,
    lifecycle_state,
    authority_envelope_fingerprint,
    planner_version,
    semantics_version,
    gap_set_fingerprint,
    gap_context_json,
    work_units_json,
    budget_policy_snapshot_json,
    budget_snapshot_json,
    plan_fingerprint
  )
  VALUES(
    (v_expected->>'organisationId')::uuid,
    (v_expected->>'campaignId')::uuid,
    (v_expected->>'companyId')::uuid,
    (v_expected->>'referenceTime')::timestamptz,
    v_expected->>'lifecycleState',
    v_expected->>'authorityEnvelopeFingerprint',
    p_planner_version,
    p_semantics_version,
    p_gap_set_fingerprint,
    v_expected,
    p_work_units,
    v_policy,
    v_budget,
    v_expected_fp
  )
  ON CONFLICT ON CONSTRAINT research_plan_runs_plan_fingerprint_key DO NOTHING
  RETURNING id INTO v_plan;

  IF v_plan IS NULL THEN
    SELECT p.id
    INTO v_plan
    FROM public.research_plan_runs AS p
    WHERE p.plan_fingerprint = v_expected_fp;
    RETURN QUERY
    SELECT
      v_plan,
      (
        SELECT count(*)::integer
        FROM public.research_work_units AS w
        WHERE w.plan_id = v_plan
      ),
      v_expected_fp,
      true;
    RETURN;
  END IF;

  FOR v_item IN
    SELECT value
    FROM jsonb_array_elements(p_work_units) AS x(value)
    ORDER BY (value->>'ordinal')::integer
  LOOP
    INSERT INTO public.background_jobs(
      organisation_id,
      campaign_id,
      job_type,
      dedupe_key,
      status,
      priority,
      payload_json,
      max_attempts
    )
    VALUES(
      (v_expected->>'organisationId')::uuid,
      (v_expected->>'campaignId')::uuid,
      'GENESIS_RESEARCH_V1',
      v_item->>'dedupeKey',
      'PENDING',
      CASE v_item->>'tier'
        WHEN 'DECISION_BLOCKER' THEN 10
        WHEN 'CURRENTNESS_REPAIR' THEN 20
        WHEN 'EXPIRING_SOON' THEN 30
        ELSE 40
      END,
      jsonb_build_object(
        'planFingerprint',v_expected_fp,
        'gapKey',v_item->>'gapKey',
        'action',v_item->>'action'
      ),
      5
    )
    RETURNING id INTO v_job_id;

    INSERT INTO public.research_work_units(
      plan_id,
      organisation_id,
      campaign_id,
      company_id,
      ordinal,
      gap_key,
      layer,
      tier,
      action,
      subject_type,
      subject_id,
      claim_key,
      reason_code,
      query_hints_json,
      payload_json,
      cost_ceiling_usd,
      dedupe_key,
      background_job_id
    )
    VALUES(
      v_plan,
      (v_expected->>'organisationId')::uuid,
      (v_expected->>'campaignId')::uuid,
      (v_expected->>'companyId')::uuid,
      (v_item->>'ordinal')::integer,
      v_item->>'gapKey',
      v_item->>'layer',
      v_item->>'tier',
      v_item->>'action',
      v_item->>'subjectType',
      v_item->>'subjectId',
      NULLIF(v_item->>'claimKey',''),
      v_item->>'reasonCode',
      COALESCE(v_item->'queryHints','[]'::jsonb),
      COALESCE(v_item->'payload','{}'::jsonb),
      (v_item->>'costCeilingUsd')::numeric,
      v_item->>'dedupeKey',
      v_job_id
    );
    v_count := v_count + 1;
  END LOOP;

  RETURN QUERY SELECT v_plan, v_count, v_expected_fp, false;
END;
$fn$;

REVOKE ALL ON FUNCTION public.marketroute_persist_research_plan_v1(
  jsonb,text,text,text,jsonb
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_persist_research_plan_v1(
  jsonb,text,text,text,jsonb
) TO service_role;

INSERT INTO public.marketroute_schema_releases(
  release_key,
  build_number,
  constitution_version,
  metadata_json
)
VALUES(
  'MARKETROUTE_V2_RESEARCH_PLAN_PERSISTENCE_HOTFIX_0_18_3_11',
  18,
  'MRV2-CONSTITUTION-1.0.0',
  jsonb_build_object(
    'migration','0031_research_plan_persistence_hotfix.sql',
    'new_authority_writer',false,
    'timestamp_fingerprint_canonicalisation','UTC_ISO_8601_MILLISECONDS_Z',
    'qualified_plan_deduplication_columns',true,
    'failed_before_provider_cost',true
  )
)
ON CONFLICT(release_key) DO NOTHING;

NOTIFY pgrst,'reload schema';
COMMIT;
