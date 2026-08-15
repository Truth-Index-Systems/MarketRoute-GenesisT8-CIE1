BEGIN;

-- MarketRoute V2 campaign lifecycle controls 0.18.3.10.
--
-- User-facing "Delete campaign" is an audited archive operation. Historical
-- evidence, Truth, R4/R5/R6, opportunity and engagement lineage is retained.
-- This migration adds no commercial-authority writer.

CREATE TABLE public.campaign_workflow_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organisation_id uuid NOT NULL,
  campaign_id uuid NOT NULL,
  actor_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  action text NOT NULL CHECK (action IN ('PAUSE','RESUME','ARCHIVE')),
  prior_workflow_state text NOT NULL CHECK (prior_workflow_state IN ('DRAFT','ACTIVE','PAUSED','ARCHIVED')),
  resulting_workflow_state text NOT NULL CHECK (resulting_workflow_state IN ('ACTIVE','PAUSED','ARCHIVED')),
  metadata_json jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata_json) = 'object'),
  occurred_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT campaign_workflow_events_campaign_scope_fk
    FOREIGN KEY (organisation_id, campaign_id)
    REFERENCES public.campaigns(organisation_id, id)
    ON DELETE RESTRICT
);

CREATE INDEX campaign_workflow_events_campaign_idx
ON public.campaign_workflow_events(organisation_id, campaign_id, occurred_at DESC, id DESC);

CREATE TRIGGER campaign_workflow_events_append_only
BEFORE UPDATE OR DELETE ON public.campaign_workflow_events
FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

ALTER TABLE public.campaign_workflow_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.campaign_workflow_events FROM anon, authenticated, service_role;
GRANT SELECT ON public.campaign_workflow_events TO service_role;

CREATE OR REPLACE FUNCTION public.marketroute_manage_campaign_v1(
  p_organisation_id uuid,
  p_campaign_id uuid,
  p_action text,
  p_confirmation_name text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_user uuid := auth.uid();
  v_campaign public.campaigns%ROWTYPE;
  v_action text := upper(btrim(COALESCE(p_action, '')));
  v_resulting_state text;
  v_policy_was_enabled boolean := true;
  v_deduplicated boolean := false;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'MARKETROUTE_AUTH_REQUIRED';
  END IF;
  IF NOT public.marketroute_is_org_admin(p_organisation_id) THEN
    RAISE EXCEPTION 'MARKETROUTE_CAMPAIGN_ADMIN_REQUIRED';
  END IF;
  IF v_action NOT IN ('PAUSE','RESUME','ARCHIVE') THEN
    RAISE EXCEPTION 'MARKETROUTE_CAMPAIGN_ACTION_INVALID';
  END IF;

  SELECT c.*
  INTO v_campaign
  FROM public.campaigns AS c
  WHERE c.id = p_campaign_id
    AND c.organisation_id = p_organisation_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'MARKETROUTE_CAMPAIGN_NOT_FOUND';
  END IF;

  IF v_action = 'ARCHIVE'
     AND p_confirmation_name IS DISTINCT FROM v_campaign.name THEN
    RAISE EXCEPTION 'MARKETROUTE_CAMPAIGN_NAME_CONFIRMATION_MISMATCH';
  END IF;

  IF v_action = 'PAUSE' THEN
    IF v_campaign.workflow_state = 'PAUSED' THEN
      v_deduplicated := true;
      v_resulting_state := 'PAUSED';
    ELSIF v_campaign.workflow_state <> 'ACTIVE' THEN
      RAISE EXCEPTION 'MARKETROUTE_CAMPAIGN_PAUSE_STATE_INVALID';
    ELSE
      v_resulting_state := 'PAUSED';
      SELECT COALESCE(p.enabled, true)
      INTO v_policy_was_enabled
      FROM public.research_budget_policies AS p
      WHERE p.organisation_id = p_organisation_id
        AND p.campaign_id = p_campaign_id;
      v_policy_was_enabled := COALESCE(v_policy_was_enabled, true);
    END IF;
  ELSIF v_action = 'RESUME' THEN
    IF v_campaign.workflow_state = 'ACTIVE' THEN
      v_deduplicated := true;
      v_resulting_state := 'ACTIVE';
    ELSIF v_campaign.workflow_state <> 'PAUSED' THEN
      RAISE EXCEPTION 'MARKETROUTE_CAMPAIGN_RESUME_STATE_INVALID';
    ELSE
      v_resulting_state := 'ACTIVE';
      SELECT COALESCE((e.metadata_json->>'researchPolicyWasEnabled')::boolean, true)
      INTO v_policy_was_enabled
      FROM public.campaign_workflow_events AS e
      WHERE e.organisation_id = p_organisation_id
        AND e.campaign_id = p_campaign_id
        AND e.action = 'PAUSE'
      ORDER BY e.occurred_at DESC, e.id DESC
      LIMIT 1;
      v_policy_was_enabled := COALESCE(v_policy_was_enabled, true);
    END IF;
  ELSE
    IF v_campaign.workflow_state = 'ARCHIVED' THEN
      v_deduplicated := true;
      v_resulting_state := 'ARCHIVED';
    ELSE
      v_resulting_state := 'ARCHIVED';
    END IF;
  END IF;

  IF v_deduplicated THEN
    RETURN jsonb_build_object(
      'campaignId', v_campaign.id,
      'action', v_action,
      'workflowState', v_resulting_state,
      'deduplicated', true
    );
  END IF;

  IF v_action IN ('PAUSE','ARCHIVE') AND EXISTS (
    SELECT 1
    FROM public.engagement_delivery_jobs AS j
    JOIN public.engagement_queue_items AS q ON q.id = j.queue_item_id
    WHERE q.organisation_id = p_organisation_id
      AND q.campaign_id = p_campaign_id
      AND j.status = 'RUNNING'
  ) THEN
    RAISE EXCEPTION 'MARKETROUTE_CAMPAIGN_CHANGE_BLOCKED_DURING_DELIVERY';
  END IF;

  UPDATE public.campaigns
  SET workflow_state = v_resulting_state,
      updated_at = now()
  WHERE id = p_campaign_id
    AND organisation_id = p_organisation_id;

  IF v_action IN ('PAUSE','ARCHIVE') THEN
    UPDATE public.research_budget_policies
    SET enabled = false,
        updated_at = now()
    WHERE organisation_id = p_organisation_id
      AND campaign_id = p_campaign_id;
  ELSIF v_action = 'RESUME' THEN
    UPDATE public.research_budget_policies
    SET enabled = v_policy_was_enabled,
        updated_at = now()
    WHERE organisation_id = p_organisation_id
      AND campaign_id = p_campaign_id;
  END IF;

  INSERT INTO public.campaign_workflow_events(
    organisation_id,
    campaign_id,
    actor_user_id,
    action,
    prior_workflow_state,
    resulting_workflow_state,
    metadata_json
  )
  VALUES(
    p_organisation_id,
    p_campaign_id,
    v_user,
    v_action,
    v_campaign.workflow_state,
    v_resulting_state,
    CASE
      WHEN v_action = 'PAUSE'
        THEN jsonb_build_object('researchPolicyWasEnabled', v_policy_was_enabled)
      WHEN v_action = 'ARCHIVE'
        THEN jsonb_build_object('typedNameConfirmed', true, 'lineageRetained', true)
      ELSE '{}'::jsonb
    END
  );

  RETURN jsonb_build_object(
    'campaignId', v_campaign.id,
    'action', v_action,
    'workflowState', v_resulting_state,
    'deduplicated', false
  );
END;
$fn$;

REVOKE ALL ON FUNCTION public.marketroute_manage_campaign_v1(uuid,uuid,text,text)
FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_manage_campaign_v1(uuid,uuid,text,text)
TO authenticated;

-- Paused/archived campaigns and explicitly disabled policies must not be
-- selected and repeatedly deferred ahead of runnable campaigns.
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

  SELECT w.*
  INTO v_work
  FROM public.research_work_units AS w
  JOIN public.background_jobs AS j ON j.id = w.background_job_id
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
  ORDER BY j.priority, j.created_at, j.id
  FOR UPDATE OF j SKIP LOCKED
  LIMIT 1;

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

  IF COALESCE((v_policy->>'enabled')::boolean, true) = false
     OR (v_budget->>'activeJobs')::integer >=
        (v_policy->>'maxConcurrentJobs')::integer THEN
    UPDATE public.background_jobs
    SET status = 'DEFERRED',
        available_at = p_at + interval '5 minutes',
        updated_at = p_at
    WHERE id = v_job.id;
    RETURN NULL;
  END IF;

  v_remaining :=
    (v_policy->>'dailyBudgetUsd')::numeric
    - (v_budget->>'spentTodayUsd')::numeric
    - (v_budget->>'reservedTodayUsd')::numeric;

  IF v_work.cost_ceiling_usd > greatest(0, v_remaining)
     OR v_work.cost_ceiling_usd > (v_policy->>'maxJobCostUsd')::numeric THEN
    UPDATE public.background_jobs
    SET status = 'DEFERRED',
        available_at =
          (date_trunc('day', p_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC')
          + interval '1 day',
        updated_at = p_at
    WHERE id = v_job.id;
    RETURN NULL;
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
  )
  VALUES(
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
  )
  VALUES(
    v_job.id,
    p_scheduler_run_id,
    v_attempt,
    'RUNNING',
    p_at
  );

  RETURN jsonb_build_object(
    'workUnitId',v_work.id,
    'jobId',v_job.id,
    'planId',v_work.plan_id,
    'organisationId',v_work.organisation_id,
    'campaignId',v_work.campaign_id,
    'companyId',v_work.company_id,
    'gapKey',v_work.gap_key,
    'layer',v_work.layer,
    'tier',v_work.tier,
    'action',v_work.action,
    'subjectType',v_work.subject_type,
    'subjectId',v_work.subject_id,
    'claimKey',v_work.claim_key,
    'reasonCode',v_work.reason_code,
    'queryHints',v_work.query_hints_json,
    'payload',v_work.payload_json || jsonb_build_object('dedupeKey',v_work.dedupe_key),
    'costCeilingUsd',v_work.cost_ceiling_usd,
    'attemptNumber',v_attempt
  );
END;
$fn$;

REVOKE ALL ON FUNCTION public.marketroute_claim_research_work_v1(uuid,timestamptz)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_claim_research_work_v1(uuid,timestamptz)
TO service_role;

-- Archived campaigns disappear from normal product surfaces while remaining
-- directly auditable through service-role reads and retained lineage.
CREATE OR REPLACE FUNCTION public.marketroute_application_command_centre_read_v1(
  p_organisation_id uuid,
  p_at timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_org public.organisations%ROWTYPE;
  v_campaigns jsonb := '[]'::jsonb;
  v_campaign public.campaigns%ROWTYPE;
  v_read jsonb;
BEGIN
  PERFORM public.marketroute_require_service_role();
  PERFORM public.marketroute_application_require_current_read_time_v1(p_at);

  SELECT *
  INTO v_org
  FROM public.organisations
  WHERE id = p_organisation_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'MARKETROUTE_APPLICATION_ORGANISATION_NOT_FOUND';
  END IF;

  FOR v_campaign IN
    SELECT *
    FROM public.campaigns
    WHERE organisation_id = p_organisation_id
      AND workflow_state <> 'ARCHIVED'
    ORDER BY
      CASE workflow_state
        WHEN 'ACTIVE' THEN 0
        WHEN 'PAUSED' THEN 1
        WHEN 'DRAFT' THEN 2
        ELSE 3
      END,
      updated_at DESC,
      id
  LOOP
    v_read := public.marketroute_application_campaign_read_v1(
      p_organisation_id,
      v_campaign.id,
      p_at
    );
    v_campaigns := v_campaigns || jsonb_build_array(jsonb_build_object(
      'campaign',v_read->'campaign',
      'seller',v_read->'seller',
      'metrics',v_read->'metrics',
      'research',v_read->'research',
      'engagementPolicy',v_read->'engagementPolicy'
    ));
  END LOOP;

  RETURN jsonb_build_object(
    'contractVersion','MRV2-APPLICATION-READ-1.0.0',
    'resourceType','COMMAND_CENTRE',
    'evaluatedAt',to_jsonb(p_at),
    'organisation',jsonb_build_object(
      'organisationId',v_org.id,
      'name',v_org.name,
      'slug',v_org.slug,
      'status',v_org.status
    ),
    'campaigns',v_campaigns
  );
END;
$fn$;

REVOKE ALL ON FUNCTION public.marketroute_application_command_centre_read_v1(uuid,timestamptz)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_application_command_centre_read_v1(uuid,timestamptz)
TO service_role;

INSERT INTO public.marketroute_schema_releases(
  release_key,
  build_number,
  constitution_version,
  metadata_json
)
VALUES(
  'MARKETROUTE_V2_CAMPAIGN_LIFECYCLE_CONTROLS_0_18_3_10',
  18,
  'MRV2-CONSTITUTION-1.0.0',
  jsonb_build_object(
    'migration','0030_campaign_lifecycle_controls.sql',
    'new_authority_writer',false,
    'typed_archive_confirmation',true,
    'pause_resume',true,
    'append_only_campaign_audit',true,
    'archive_retains_lineage',true
  )
)
ON CONFLICT(release_key) DO NOTHING;

NOTIFY pgrst,'reload schema';
COMMIT;

