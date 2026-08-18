BEGIN;

-- MarketRoute V2 RC hardening: research execution recovery + diagnostics.
--
-- Production observations on 2026-08-18 showed research planning and opportunity
-- sync completing while claim returned NULL. This patch makes the scheduler recover
-- orphaned RUNNING jobs as soon as their owning lease is gone, preserves zero-cost
-- deterministic revalidation even when paid AI capacity is exhausted, and records
-- service-role-only queue diagnostics for zero-execution cycles.

CREATE OR REPLACE FUNCTION public.marketroute_recover_abandoned_research_work_v1(
  p_scheduler_run_id uuid,
  p_at timestamptz DEFAULT now()
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
DECLARE
  v_row record;
  v_count integer:=0;
  v_terminal boolean;
BEGIN
  IF NOT EXISTS(
    SELECT 1
    FROM public.scheduler_runs r
    JOIN public.scheduler_leases l
      ON l.owner_run_id=r.id
     AND l.lease_key='GENESIS_RESEARCH_V1'
    WHERE r.id=p_scheduler_run_id
      AND r.status='RUNNING'
      AND r.runner_key='GENESIS_RESEARCH_V1'
      AND l.expires_at>p_at
  ) THEN
    RAISE EXCEPTION 'MARKETROUTE_RESEARCH_SCHEDULER_LEASE_NOT_OWNED';
  END IF;

  FOR v_row IN
    SELECT j.id job_id,j.attempt_count,j.max_attempts,j.reserved_by_run_id,
           w.id work_unit_id,w.organisation_id,w.campaign_id,w.cost_ceiling_usd
    FROM public.background_jobs j
    JOIN public.research_work_units w ON w.background_job_id=j.id
    WHERE j.job_type='GENESIS_RESEARCH_V1'
      AND j.status='RUNNING'
      AND (
        j.reserved_by_run_id IS NULL
        OR NOT EXISTS(
          SELECT 1 FROM public.scheduler_leases l
          WHERE l.owner_run_id=j.reserved_by_run_id
            AND l.lease_key='GENESIS_RESEARCH_V1'
            AND l.expires_at>p_at
        )
      )
    ORDER BY j.reserved_at NULLS FIRST,j.id
    FOR UPDATE OF j SKIP LOCKED
  LOOP
    IF NOT EXISTS(
      SELECT 1 FROM public.research_budget_events e
      WHERE e.work_unit_id=v_row.work_unit_id
        AND e.attempt_number=v_row.attempt_count
        AND e.event_type IN('COMMIT','RELEASE')
    ) THEN
      INSERT INTO public.research_budget_events(
        organisation_id,campaign_id,work_unit_id,scheduler_run_id,attempt_number,
        event_type,amount_usd,occurred_at,metadata_json
      ) VALUES(
        v_row.organisation_id,v_row.campaign_id,v_row.work_unit_id,p_scheduler_run_id,
        v_row.attempt_count,'COMMIT',v_row.cost_ceiling_usd,p_at,
        jsonb_build_object('abandonedAttempt',true,'conservativeCharge',true,'recoveredWithoutLiveLease',true)
      );
    END IF;
    v_terminal:=v_row.attempt_count>=v_row.max_attempts;
    UPDATE public.background_job_attempts
    SET status='ABORTED',completed_at=p_at,error_code='MARKETROUTE_RESEARCH_ABANDONED_ATTEMPT',
        telemetry_json=COALESCE(telemetry_json,'{}'::jsonb)||jsonb_build_object('recoveredByRunId',p_scheduler_run_id)
    WHERE job_id=v_row.job_id AND attempt_number=v_row.attempt_count AND status='RUNNING';
    UPDATE public.background_jobs
    SET status=CASE WHEN v_terminal THEN 'FAILED' ELSE 'PENDING' END,
        available_at=CASE WHEN v_terminal THEN available_at ELSE p_at END,
        reserved_by_run_id=NULL,reserved_at=NULL,
        last_error_code='MARKETROUTE_RESEARCH_ABANDONED_ATTEMPT',updated_at=p_at
    WHERE id=v_row.job_id;
    v_count:=v_count+1;
  END LOOP;

  UPDATE public.scheduler_runs r
  SET status='CANCELLED',completed_at=COALESCE(completed_at,p_at),
      metadata_json=COALESCE(metadata_json,'{}'::jsonb)||jsonb_build_object('leaseExpired',true,'recoveredByRunId',p_scheduler_run_id)
  WHERE r.runner_key='GENESIS_RESEARCH_V1'
    AND r.status='RUNNING'
    AND r.id<>p_scheduler_run_id
    AND NOT EXISTS(
      SELECT 1 FROM public.scheduler_leases l
      WHERE l.owner_run_id=r.id
        AND l.lease_key='GENESIS_RESEARCH_V1'
        AND l.expires_at>p_at
    );
  RETURN v_count;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.marketroute_claim_research_work_v1(
  p_scheduler_run_id uuid,
  p_at timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_work public.research_work_units%ROWTYPE;
  v_job public.background_jobs%ROWTYPE;
  v_policy jsonb;
  v_budget jsonb;
  v_attempt integer;
  v_remaining numeric;
  v_anon_budget numeric;
  v_anon_expires timestamptz;
  v_anon_spent numeric := 0;
  v_anon_reserved numeric := 0;
  v_anon_remaining numeric;
  v_paid boolean := false;
  v_capacity jsonb;
  -- When every job in a campaign/organisation is temporarily blocked by the
  -- same scope-level gate, skip the rest of that scope for this claim call.
  -- Unit-specific budget checks still continue row-by-row so a zero-cost
  -- deterministic revalidation can run behind a paid AI work unit.
  v_skip_campaigns uuid[] := ARRAY[]::uuid[];
  v_skip_organisations uuid[] := ARRAY[]::uuid[];
  v_skip_work_units uuid[] := ARRAY[]::uuid[];
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.scheduler_runs AS r
    JOIN public.scheduler_leases AS l
      ON l.owner_run_id = r.id
     AND l.lease_key = 'GENESIS_RESEARCH_V1'
    WHERE r.id = p_scheduler_run_id
      AND r.status = 'RUNNING'
      AND r.runner_key = 'GENESIS_RESEARCH_V1'
      AND l.expires_at > p_at
  ) THEN
    RAISE EXCEPTION 'MARKETROUTE_RESEARCH_SCHEDULER_RUN_REQUIRED';
  END IF;

  -- Archived campaigns retain immutable research lineage, but their queued
  -- orchestration jobs are terminal. Clean them out so historical work cannot
  -- remain visible as live queue backlog forever. PAUSED work is deliberately
  -- retained for a later resume.
  UPDATE public.background_jobs AS j
  SET status = 'CANCELLED',
      reserved_by_run_id = NULL,
      reserved_at = NULL,
      last_error_code = COALESCE(j.last_error_code, 'MARKETROUTE_CAMPAIGN_ARCHIVED'),
      updated_at = p_at
  FROM public.research_work_units AS w
  JOIN public.campaigns AS c
    ON c.id = w.campaign_id
   AND c.organisation_id = w.organisation_id
  WHERE j.id = w.background_job_id
    AND j.job_type = 'GENESIS_RESEARCH_V1'
    AND j.status IN ('PENDING','DEFERRED')
    AND c.workflow_state = 'ARCHIVED';

  LOOP
    -- Select only work that belongs to an ACTIVE campaign. Explicitly disabled
    -- research policies are excluded before queue ordering so they cannot sit
    -- at the head of the global queue and be repeatedly deferred.
    SELECT w.*
    INTO v_work
    FROM public.research_work_units AS w
    JOIN public.background_jobs AS j
      ON j.id = w.background_job_id
    JOIN public.campaigns AS c
      ON c.id = w.campaign_id
     AND c.organisation_id = w.organisation_id
    WHERE j.job_type = 'GENESIS_RESEARCH_V1'
      AND j.status IN ('PENDING','DEFERRED')
      AND j.available_at <= p_at
      AND c.workflow_state = 'ACTIVE'
      AND COALESCE((
        SELECT p.enabled
        FROM public.research_budget_policies AS p
        WHERE p.organisation_id = w.organisation_id
          AND p.campaign_id = w.campaign_id
      ), true)
      AND NOT (w.campaign_id = ANY(v_skip_campaigns))
      AND NOT (w.organisation_id = ANY(v_skip_organisations))
      AND NOT (w.id = ANY(v_skip_work_units))
      AND NOT EXISTS (
        SELECT 1
        FROM public.anonymous_discovery_runs AS a
        WHERE a.organisation_id = w.organisation_id
          AND NOT public.marketroute_paid_entitlement_active_v1(w.organisation_id, p_at)
          AND (
            a.status NOT IN ('ACTIVE','CLAIMED')
            OR a.research_expires_at <= p_at
          )
      )
    ORDER BY j.priority, j.created_at, j.id
    FOR UPDATE OF j SKIP LOCKED
    LIMIT 1;

    -- NULL now means there is genuinely no eligible candidate left after all
    -- blocked scopes/units examined by this claim call have been skipped.
    IF NOT FOUND THEN
      RETURN NULL;
    END IF;

    SELECT *
    INTO v_job
    FROM public.background_jobs
    WHERE id = v_work.background_job_id
    FOR UPDATE;

    v_policy := public.marketroute_research_policy_v1(
      v_work.organisation_id,
      v_work.campaign_id
    );
    v_budget := public.marketroute_research_budget_snapshot_v1(
      v_work.organisation_id,
      v_work.campaign_id,
      p_at
    );

    -- Scope-level block: defer one representative job, skip the rest of the
    -- campaign in this call, and continue scanning other campaigns.
    IF COALESCE((v_policy->>'enabled')::boolean, true) = false
       OR (v_budget->>'activeJobs')::integer >=
          (v_policy->>'maxConcurrentJobs')::integer THEN
      UPDATE public.background_jobs
      SET status = 'DEFERRED',
          available_at = p_at + interval '5 minutes',
          last_error_code = 'MARKETROUTE_RESEARCH_CONCURRENCY_BLOCKED',
          updated_at = p_at
      WHERE id = v_job.id;

      IF NOT (v_work.campaign_id = ANY(v_skip_campaigns)) THEN
        v_skip_campaigns := array_append(v_skip_campaigns, v_work.campaign_id);
      END IF;
      CONTINUE;
    END IF;

    v_remaining :=
      (v_policy->>'dailyBudgetUsd')::numeric
      - (v_budget->>'spentTodayUsd')::numeric
      - (v_budget->>'reservedTodayUsd')::numeric;

    v_paid := public.marketroute_paid_entitlement_active_v1(
      v_work.organisation_id,
      p_at
    );

    -- Paid research capacity is organisation-scoped. If exhausted, defer one
    -- representative unit until the next period, skip the organisation for
    -- this call, and continue to a different runnable customer if one exists.
    IF v_paid AND v_work.cost_ceiling_usd > 0 THEN
      v_capacity := public.marketroute_research_capacity_snapshot_v1(
        v_work.organisation_id,
        p_at
      );
      IF COALESCE((v_capacity->>'available')::boolean, false) = false THEN
        UPDATE public.background_jobs
        SET status = 'DEFERRED',
            available_at = COALESCE(
              NULLIF(v_capacity->>'periodEnd','')::timestamptz,
              p_at + interval '1 day'
            ),
            last_error_code = 'MARKETROUTE_PLAN_RESEARCH_CAPACITY_EXHAUSTED',
            updated_at = p_at
        WHERE id = v_job.id;

        IF NOT (v_work.organisation_id = ANY(v_skip_organisations)) THEN
          v_skip_organisations := array_append(
            v_skip_organisations,
            v_work.organisation_id
          );
        END IF;
        CONTINUE;
      END IF;
    END IF;

    v_anon_budget := NULL;
    v_anon_expires := NULL;
    v_anon_spent := 0;
    v_anon_reserved := 0;
    v_anon_remaining := NULL;

    IF NOT v_paid THEN
      SELECT lifetime_budget_usd, research_expires_at
      INTO v_anon_budget, v_anon_expires
      FROM public.anonymous_discovery_runs
      WHERE organisation_id = v_work.organisation_id
        AND status IN ('ACTIVE','CLAIMED');
    END IF;

    IF v_anon_budget IS NOT NULL THEN
      IF v_anon_expires <= p_at THEN
        UPDATE public.background_jobs
        SET status = 'CANCELLED',
            last_error_code = 'MARKETROUTE_ANONYMOUS_RESEARCH_WINDOW_CLOSED',
            updated_at = p_at
        WHERE id = v_job.id;
        CONTINUE;
      END IF;

      SELECT COALESCE(sum(amount_usd), 0)
      INTO v_anon_spent
      FROM public.research_budget_events
      WHERE organisation_id = v_work.organisation_id
        AND campaign_id = v_work.campaign_id
        AND event_type = 'COMMIT';

      SELECT COALESCE(sum(r.amount_usd), 0)
      INTO v_anon_reserved
      FROM public.research_budget_events AS r
      WHERE r.organisation_id = v_work.organisation_id
        AND r.campaign_id = v_work.campaign_id
        AND r.event_type = 'RESERVE'
        AND NOT EXISTS (
          SELECT 1
          FROM public.research_budget_events AS x
          WHERE x.work_unit_id = r.work_unit_id
            AND x.attempt_number = r.attempt_number
            AND x.event_type IN ('COMMIT','RELEASE')
        );

      v_anon_remaining := greatest(
        0,
        v_anon_budget - v_anon_spent - v_anon_reserved
      );
      v_remaining := least(v_remaining, v_anon_remaining);
    END IF;

    -- This remains deliberately unit-specific. Do not skip the whole campaign:
    -- a zero-cost REVALIDATE_R4/R5/R6 unit may be runnable immediately behind
    -- an AI work unit that no longer fits today's remaining budget.
    IF v_work.cost_ceiling_usd > greatest(0, v_remaining)
       OR v_work.cost_ceiling_usd >
          (v_policy->>'maxJobCostUsd')::numeric THEN
      UPDATE public.background_jobs
      SET status = CASE
            WHEN v_anon_budget IS NOT NULL
             AND greatest(0, v_remaining) <= 0
              THEN 'CANCELLED'
            ELSE 'DEFERRED'
          END,
          available_at = CASE
            WHEN v_anon_budget IS NOT NULL
              THEN available_at
            ELSE
              (date_trunc('day', p_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC')
              + interval '1 day'
          END,
          last_error_code = CASE
            WHEN v_anon_budget IS NOT NULL
             AND greatest(0, v_remaining) <= 0
              THEN 'MARKETROUTE_ANONYMOUS_RESEARCH_BUDGET_EXHAUSTED'
            WHEN v_work.cost_ceiling_usd > (v_policy->>'maxJobCostUsd')::numeric
              THEN 'MARKETROUTE_RESEARCH_JOB_COST_LIMIT'
            ELSE 'MARKETROUTE_RESEARCH_DAILY_BUDGET_DEFERRED'
          END,
          updated_at = p_at
      WHERE id = v_job.id;
      IF NOT (v_work.id = ANY(v_skip_work_units)) THEN
        v_skip_work_units := array_append(v_skip_work_units, v_work.id);
      END IF;
      CONTINUE;
    END IF;

    v_attempt := v_job.attempt_count + 1;

    IF EXISTS (
      SELECT 1
      FROM public.research_budget_events
      WHERE work_unit_id = v_work.id
        AND attempt_number = v_attempt
        AND event_type = 'RESERVE'
    ) THEN
      RAISE EXCEPTION 'MARKETROUTE_RESEARCH_BUDGET_ALREADY_RESERVED';
    END IF;

    INSERT INTO public.research_budget_events(
      organisation_id,
      campaign_id,
      work_unit_id,
      scheduler_run_id,
      attempt_number,
      event_type,
      amount_usd,
      occurred_at
    ) VALUES (
      v_work.organisation_id,
      v_work.campaign_id,
      v_work.id,
      p_scheduler_run_id,
      v_attempt,
      'RESERVE',
      v_work.cost_ceiling_usd,
      p_at
    );

    UPDATE public.background_jobs
    SET status = 'RUNNING',
        reserved_by_run_id = p_scheduler_run_id,
        reserved_at = p_at,
        attempt_count = v_attempt,
        updated_at = p_at
    WHERE id = v_job.id;

    INSERT INTO public.background_job_attempts(
      job_id,
      scheduler_run_id,
      attempt_number,
      status,
      started_at
    ) VALUES (
      v_job.id,
      p_scheduler_run_id,
      v_attempt,
      'RUNNING',
      p_at
    );

    RETURN jsonb_build_object(
      'workUnitId', v_work.id,
      'jobId', v_job.id,
      'planId', v_work.plan_id,
      'organisationId', v_work.organisation_id,
      'campaignId', v_work.campaign_id,
      'companyId', v_work.company_id,
      'gapKey', v_work.gap_key,
      'layer', v_work.layer,
      'tier', v_work.tier,
      'action', v_work.action,
      'subjectType', v_work.subject_type,
      'subjectId', v_work.subject_id,
      'claimKey', v_work.claim_key,
      'reasonCode', v_work.reason_code,
      'queryHints', v_work.query_hints_json,
      'payload', v_work.payload_json || jsonb_build_object(
        'dedupeKey', v_work.dedupe_key,
        'researchOrigin', CASE
          WHEN v_paid THEN 'CUSTOMER_CAMPAIGN'
          WHEN v_anon_budget IS NULL THEN
            COALESCE(v_work.payload_json->>'researchOrigin','CUSTOMER_CAMPAIGN')
          ELSE 'ANONYMOUS_DISCOVERY'
        END
      ),
      'costCeilingUsd', v_work.cost_ceiling_usd,
      'attemptNumber', v_attempt
    );
  END LOOP;
END;
$fn$;


REVOKE ALL ON FUNCTION public.marketroute_claim_research_work_v1(uuid,timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_claim_research_work_v1(uuid,timestamptz) TO service_role;

CREATE OR REPLACE FUNCTION public.marketroute_research_queue_diagnostics_v1(p_at timestamptz DEFAULT now())
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
DECLARE
  v_available integer:=0;
  v_provider integer:=0;
  v_deterministic integer:=0;
  v_running integer:=0;
  v_orphaned integer:=0;
  v_deferred integer:=0;
  v_recent jsonb:='[]'::jsonb;
BEGIN
  PERFORM public.marketroute_require_service_role();

  SELECT count(*)::int,
         count(*) FILTER (WHERE w.cost_ceiling_usd>0)::int,
         count(*) FILTER (WHERE w.cost_ceiling_usd=0)::int,
         count(*) FILTER (WHERE j.status='DEFERRED')::int
  INTO v_available,v_provider,v_deterministic,v_deferred
  FROM public.research_work_units w
  JOIN public.background_jobs j ON j.id=w.background_job_id
  JOIN public.campaigns c ON c.id=w.campaign_id AND c.organisation_id=w.organisation_id
  WHERE j.job_type='GENESIS_RESEARCH_V1'
    AND j.status IN('PENDING','DEFERRED')
    AND j.available_at<=p_at
    AND c.workflow_state='ACTIVE';

  SELECT count(*)::int INTO v_running
  FROM public.research_work_units w
  JOIN public.background_jobs j ON j.id=w.background_job_id
  JOIN public.campaigns c ON c.id=w.campaign_id AND c.organisation_id=w.organisation_id
  WHERE j.job_type='GENESIS_RESEARCH_V1' AND j.status='RUNNING' AND c.workflow_state='ACTIVE';

  SELECT count(*)::int INTO v_orphaned
  FROM public.background_jobs j
  WHERE j.job_type='GENESIS_RESEARCH_V1' AND j.status='RUNNING'
    AND (j.reserved_by_run_id IS NULL OR NOT EXISTS(
      SELECT 1 FROM public.scheduler_leases l
      WHERE l.owner_run_id=j.reserved_by_run_id
        AND l.lease_key='GENESIS_RESEARCH_V1'
        AND l.expires_at>p_at
    ));

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'jobId',q.job_id,'workUnitId',q.work_unit_id,'campaignId',q.campaign_id,
    'layer',q.layer,'tier',q.tier,'action',q.action,'status',q.status,
    'priority',q.priority,'costCeilingUsd',q.cost_ceiling_usd,
    'attemptCount',q.attempt_count,'lastErrorCode',q.last_error_code,
    'availableAt',q.available_at
  ) ORDER BY q.priority,q.created_at,q.job_id),'[]'::jsonb)
  INTO v_recent
  FROM (
    SELECT j.id job_id,w.id work_unit_id,w.campaign_id,w.layer,w.tier,w.action,
           j.status,j.priority,w.cost_ceiling_usd,j.attempt_count,j.last_error_code,
           j.available_at,j.created_at
    FROM public.research_work_units w
    JOIN public.background_jobs j ON j.id=w.background_job_id
    JOIN public.campaigns c ON c.id=w.campaign_id AND c.organisation_id=w.organisation_id
    WHERE j.job_type='GENESIS_RESEARCH_V1'
      AND j.status IN('PENDING','DEFERRED','RUNNING')
      AND c.workflow_state='ACTIVE'
    ORDER BY j.priority,j.created_at,j.id
    LIMIT 8
  ) q;

  RETURN jsonb_build_object(
    'availableJobs',v_available,
    'providerBackedAvailableJobs',v_provider,
    'deterministicAvailableJobs',v_deterministic,
    'runningJobs',v_running,
    'orphanedRunningJobs',v_orphaned,
    'deferredAvailableJobs',v_deferred,
    'frontOfQueue',v_recent
  );
END;
$fn$;

REVOKE ALL ON FUNCTION public.marketroute_research_queue_diagnostics_v1(timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_research_queue_diagnostics_v1(timestamptz) TO service_role;

INSERT INTO public.marketroute_schema_releases(release_key,build_number,constitution_version,metadata_json)
VALUES(
  'MARKETROUTE_V2_RC_RESEARCH_EXECUTION_OBSERVABILITY_2026_08_18',
  26,
  'MRV2-CONSTITUTION-1.0.0',
  jsonb_build_object(
    'migration','0049_research_execution_recovery_observability.sql',
    'new_authority_writer',false,
    'authority_semantics_unchanged',true,
    'orphan_recovery_without_live_lease',true,
    'zero_cost_revalidation_capacity_bypass',true,
    'queue_diagnostics',true,
    'growth_reactivated',false,
    'delivery_enabled',false
  )
) ON CONFLICT(release_key) DO NOTHING;

NOTIFY pgrst,'reload schema';
COMMIT;
