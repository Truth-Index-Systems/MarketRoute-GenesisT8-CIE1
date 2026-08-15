BEGIN;

-- MarketRoute V2 persistent campaign activation progress 0.18.3.16.
--
-- Campaign preparation already persisted as workspace activation work, but the
-- application exposed only a transient query-string success message. These
-- fields make orchestration progress observable without creating or changing
-- any commercial authority writer.

ALTER TABLE public.workspace_activation_jobs
  ADD COLUMN IF NOT EXISTS activation_stage text NOT NULL DEFAULT 'QUEUED',
  ADD COLUMN IF NOT EXISTS activation_progress integer NOT NULL DEFAULT 5,
  ADD COLUMN IF NOT EXISTS activation_stage_detail_json jsonb NOT NULL DEFAULT '{}'::jsonb;

UPDATE public.workspace_activation_jobs
SET activation_stage = CASE status
      WHEN 'PENDING' THEN 'QUEUED'
      WHEN 'RUNNING' THEN 'ANALYSING_SELLER'
      WHEN 'SUCCEEDED' THEN 'READY'
      ELSE 'FAILED'
    END,
    activation_progress = CASE status
      WHEN 'PENDING' THEN 5
      WHEN 'RUNNING' THEN 15
      WHEN 'SUCCEEDED' THEN 100
      ELSE greatest(5, least(activation_progress, 95))
    END,
    activation_stage_detail_json = CASE
      WHEN status IN ('FAILED','NEEDS_INPUT')
        THEN jsonb_build_object('errorCode', last_error_code)
      ELSE COALESCE(activation_stage_detail_json, '{}'::jsonb)
    END;

DO $do$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.workspace_activation_jobs'::regclass
      AND conname = 'workspace_activation_stage_valid'
  ) THEN
    ALTER TABLE public.workspace_activation_jobs
      ADD CONSTRAINT workspace_activation_stage_valid CHECK (
        activation_stage IN (
          'QUEUED',
          'ANALYSING_SELLER',
          'SELLER_CONTEXT_READY',
          'CREATING_CAMPAIGN',
          'CAMPAIGN_CREATED',
          'SELECTING_TARGETS',
          'DISCOVERING_TARGETS',
          'LINKING_COMPANIES',
          'FINALISING',
          'READY',
          'FAILED'
        )
      );
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.workspace_activation_jobs'::regclass
      AND conname = 'workspace_activation_progress_valid'
  ) THEN
    ALTER TABLE public.workspace_activation_jobs
      ADD CONSTRAINT workspace_activation_progress_valid
      CHECK (activation_progress BETWEEN 0 AND 100);
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.workspace_activation_jobs'::regclass
      AND conname = 'workspace_activation_stage_detail_object'
  ) THEN
    ALTER TABLE public.workspace_activation_jobs
      ADD CONSTRAINT workspace_activation_stage_detail_object
      CHECK (jsonb_typeof(activation_stage_detail_json) = 'object');
  END IF;
END;
$do$;

CREATE OR REPLACE FUNCTION public.marketroute_workspace_activation_status_transition_v1()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $fn$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    CASE NEW.status
      WHEN 'PENDING' THEN
        NEW.activation_stage := 'QUEUED';
        NEW.activation_progress := 5;
        NEW.activation_stage_detail_json := jsonb_build_object('queuedAt', now());
      WHEN 'RUNNING' THEN
        NEW.activation_stage := 'ANALYSING_SELLER';
        NEW.activation_progress := 15;
        NEW.activation_stage_detail_json := jsonb_build_object('startedAt', now());
      WHEN 'SUCCEEDED' THEN
        NEW.activation_stage := 'READY';
        NEW.activation_progress := 100;
        NEW.activation_stage_detail_json := jsonb_build_object(
          'completedAt', now(),
          'targetCompanyCount', NEW.result_json->'targetCompanyCount',
          'discovery', COALESCE(NEW.result_json->'discovery', '{}'::jsonb)
        );
      WHEN 'FAILED' THEN
        NEW.activation_stage := 'FAILED';
        NEW.activation_progress := greatest(5, least(NEW.activation_progress, 95));
        NEW.activation_stage_detail_json := COALESCE(NEW.activation_stage_detail_json, '{}'::jsonb)
          || jsonb_build_object('failedAt', now(), 'errorCode', NEW.last_error_code, 'automaticRetry', true);
      WHEN 'NEEDS_INPUT' THEN
        NEW.activation_stage := 'FAILED';
        NEW.activation_progress := greatest(5, least(NEW.activation_progress, 95));
        NEW.activation_stage_detail_json := COALESCE(NEW.activation_stage_detail_json, '{}'::jsonb)
          || jsonb_build_object('failedAt', now(), 'errorCode', NEW.last_error_code, 'automaticRetry', false);
      ELSE
        NULL;
    END CASE;
  END IF;
  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS workspace_activation_status_transition ON public.workspace_activation_jobs;
CREATE TRIGGER workspace_activation_status_transition
BEFORE UPDATE OF status ON public.workspace_activation_jobs
FOR EACH ROW
EXECUTE FUNCTION public.marketroute_workspace_activation_status_transition_v1();

CREATE OR REPLACE FUNCTION public.marketroute_set_workspace_activation_stage_v1(
  p_job_id uuid,
  p_worker_id text,
  p_stage text,
  p_progress integer,
  p_detail_json jsonb DEFAULT '{}'::jsonb,
  p_at timestamptz DEFAULT now()
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_stage text := upper(btrim(COALESCE(p_stage, '')));
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF v_stage NOT IN (
    'ANALYSING_SELLER',
    'SELLER_CONTEXT_READY',
    'CREATING_CAMPAIGN',
    'CAMPAIGN_CREATED',
    'SELECTING_TARGETS',
    'DISCOVERING_TARGETS',
    'LINKING_COMPANIES',
    'FINALISING'
  ) THEN
    RAISE EXCEPTION 'MARKETROUTE_ACTIVATION_STAGE_INVALID';
  END IF;
  IF p_progress NOT BETWEEN 10 AND 99 THEN
    RAISE EXCEPTION 'MARKETROUTE_ACTIVATION_PROGRESS_INVALID';
  END IF;
  IF p_detail_json IS NULL OR jsonb_typeof(p_detail_json) <> 'object' THEN
    RAISE EXCEPTION 'MARKETROUTE_ACTIVATION_STAGE_DETAIL_INVALID';
  END IF;

  UPDATE public.workspace_activation_jobs
  SET activation_stage = v_stage,
      activation_progress = greatest(activation_progress, p_progress),
      activation_stage_detail_json = p_detail_json || jsonb_build_object('recordedAt', p_at)
  WHERE id = p_job_id
    AND status = 'RUNNING'
    AND worker_id = p_worker_id
    AND lease_expires_at > p_at;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'MARKETROUTE_ACTIVATION_LEASE_MISMATCH';
  END IF;
END;
$fn$;

REVOKE ALL ON FUNCTION public.marketroute_set_workspace_activation_stage_v1(uuid,text,text,integer,jsonb,timestamptz)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_set_workspace_activation_stage_v1(uuid,text,text,integer,jsonb,timestamptz)
TO service_role;

CREATE OR REPLACE FUNCTION public.marketroute_workspace_activation_status_v2(
  p_organisation_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_job public.workspace_activation_jobs%ROWTYPE;
  v_campaign_id uuid;
  v_campaign_name text;
BEGIN
  IF auth.uid() IS NULL OR NOT public.marketroute_is_org_member(p_organisation_id) THEN
    RAISE EXCEPTION 'MARKETROUTE_WORKSPACE_ACCESS_DENIED';
  END IF;

  SELECT *
  INTO v_job
  FROM public.workspace_activation_jobs
  WHERE organisation_id = p_organisation_id;

  IF NOT FOUND THEN
    SELECT id, name
    INTO v_campaign_id, v_campaign_name
    FROM public.campaigns
    WHERE organisation_id = p_organisation_id
      AND workflow_state <> 'ARCHIVED'
    ORDER BY updated_at DESC, id
    LIMIT 1;

    IF v_campaign_id IS NOT NULL THEN
      RETURN jsonb_build_object(
        'status','NOT_REQUIRED',
        'lastErrorCode',NULL,
        'campaignId',v_campaign_id,
        'campaignName',v_campaign_name,
        'stage','READY',
        'progress',100,
        'stageDetail','{}'::jsonb,
        'updatedAt',NULL
      );
    END IF;

    RETURN jsonb_build_object(
      'status','NOT_SUBMITTED',
      'lastErrorCode',NULL,
      'campaignId',NULL,
      'campaignName',NULL,
      'stage','QUEUED',
      'progress',0,
      'stageDetail','{}'::jsonb,
      'updatedAt',NULL
    );
  END IF;

  IF nullif(v_job.result_json->>'campaignId', '') IS NOT NULL THEN
    v_campaign_id := (v_job.result_json->>'campaignId')::uuid;
  END IF;
  v_campaign_name := nullif(btrim(v_job.campaign_name), '');

  IF v_campaign_id IS NOT NULL AND v_campaign_name IS NULL THEN
    SELECT name
    INTO v_campaign_name
    FROM public.campaigns
    WHERE id = v_campaign_id
      AND organisation_id = p_organisation_id;
  END IF;

  RETURN jsonb_build_object(
    'status',v_job.status,
    'lastErrorCode',v_job.last_error_code,
    'campaignId',v_campaign_id,
    'campaignName',v_campaign_name,
    'stage',v_job.activation_stage,
    'progress',v_job.activation_progress,
    'stageDetail',v_job.activation_stage_detail_json,
    'updatedAt',v_job.updated_at
  );
END;
$fn$;

REVOKE ALL ON FUNCTION public.marketroute_workspace_activation_status_v2(uuid)
FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_workspace_activation_status_v2(uuid)
TO authenticated;

INSERT INTO public.marketroute_schema_releases(
  release_key,
  build_number,
  constitution_version,
  metadata_json
)
VALUES(
  'MARKETROUTE_V2_CAMPAIGN_ACTIVATION_PROGRESS_UI_0_18_3_16',
  18,
  'MRV2-CONSTITUTION-1.0.0',
  jsonb_build_object(
    'migration','0036_campaign_activation_progress_ui.sql',
    'new_authority_writer',false,
    'persistent_activation_progress',true,
    'authenticated_status_read',true,
    'lease_owned_stage_updates',true,
    'archived_lineage_unchanged',true
  )
)
ON CONFLICT(release_key) DO NOTHING;

NOTIFY pgrst,'reload schema';
COMMIT;
