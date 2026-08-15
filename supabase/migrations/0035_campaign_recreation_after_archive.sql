BEGIN;

-- MarketRoute V2 campaign recreation after archive 0.18.3.15.
--
-- An archived campaign remains immutable history. This migration adds a
-- guarded activation path for creating a fresh campaign in an existing
-- workspace once every prior campaign is archived. It creates no commercial
-- authority writer and never restores or deletes an archived campaign.

ALTER TABLE public.workspace_activation_jobs
  ADD COLUMN IF NOT EXISTS campaign_name text;

DO $do$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.workspace_activation_jobs'::regclass
      AND conname = 'workspace_activation_campaign_name_length'
  ) THEN
    ALTER TABLE public.workspace_activation_jobs
      ADD CONSTRAINT workspace_activation_campaign_name_length
      CHECK (campaign_name IS NULL OR length(btrim(campaign_name)) BETWEEN 3 AND 120);
  END IF;
END;
$do$;

CREATE OR REPLACE FUNCTION public.marketroute_submit_replacement_campaign_v1(
  p_organisation_id uuid,
  p_campaign_name text,
  p_seller_offering_text text,
  p_objective_text text,
  p_target_market_text text,
  p_hard_constraints_text text,
  p_no_hard_constraints boolean
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_user uuid := auth.uid();
  v_seller uuid;
  v_job uuid;
  v_name text := nullif(btrim(COALESCE(p_campaign_name, '')), '');
  v_offering text := nullif(btrim(COALESCE(p_seller_offering_text, '')), '');
  v_no_hard boolean := COALESCE(p_no_hard_constraints, false);
  v_hard text := nullif(btrim(COALESCE(p_hard_constraints_text, '')), '');
  v_existing_status text;
  v_existing_lease timestamptz;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'MARKETROUTE_AUTH_REQUIRED';
  END IF;
  IF NOT public.marketroute_is_org_admin(p_organisation_id) THEN
    RAISE EXCEPTION 'MARKETROUTE_CAMPAIGN_ADMIN_REQUIRED';
  END IF;
  IF v_name IS NULL OR length(v_name) NOT BETWEEN 3 AND 120 THEN
    RAISE EXCEPTION 'MARKETROUTE_CAMPAIGN_NAME_REQUIRED';
  END IF;
  IF v_offering IS NULL OR length(v_offering) < 8 THEN
    RAISE EXCEPTION 'MARKETROUTE_SETUP_OFFERING_REQUIRED';
  END IF;
  IF length(btrim(COALESCE(p_objective_text, ''))) < 8 THEN
    RAISE EXCEPTION 'MARKETROUTE_SETUP_OBJECTIVE_REQUIRED';
  END IF;
  IF length(btrim(COALESCE(p_target_market_text, ''))) < 3 THEN
    RAISE EXCEPTION 'MARKETROUTE_SETUP_TARGET_REQUIRED';
  END IF;
  IF v_no_hard AND v_hard IS NOT NULL THEN
    RAISE EXCEPTION 'MARKETROUTE_SETUP_CONSTRAINT_CONFLICT';
  END IF;
  IF NOT v_no_hard AND v_hard IS NULL THEN
    RAISE EXCEPTION 'MARKETROUTE_SETUP_CONSTRAINT_DECLARATION_REQUIRED';
  END IF;

  PERFORM 1
  FROM public.organisations
  WHERE id = p_organisation_id
    AND status = 'ACTIVE'
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'MARKETROUTE_WORKSPACE_NOT_ACTIVE';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.campaigns
    WHERE organisation_id = p_organisation_id
      AND workflow_state <> 'ARCHIVED'
  ) THEN
    RAISE EXCEPTION 'MARKETROUTE_LIVE_CAMPAIGN_ALREADY_EXISTS';
  END IF;

  SELECT status, lease_expires_at
  INTO v_existing_status, v_existing_lease
  FROM public.workspace_activation_jobs
  WHERE organisation_id = p_organisation_id;

  IF v_existing_status = 'RUNNING'
     AND COALESCE(v_existing_lease, now() + interval '1 minute') >= now() THEN
    RAISE EXCEPTION 'MARKETROUTE_CAMPAIGN_CREATION_ALREADY_PROCESSING';
  END IF;

  SELECT id
  INTO v_seller
  FROM public.seller_businesses
  WHERE organisation_id = p_organisation_id
    AND lifecycle_state = 'ACTIVE'
  ORDER BY created_at ASC
  LIMIT 1;
  IF v_seller IS NULL THEN
    RAISE EXCEPTION 'MARKETROUTE_SETUP_SELLER_NOT_FOUND';
  END IF;

  INSERT INTO public.workspace_activation_jobs(
    organisation_id,
    seller_business_id,
    campaign_name,
    seller_offering_text,
    objective_text,
    target_market_text,
    hard_constraints_text,
    no_hard_constraints,
    status,
    attempt_count,
    available_at,
    worker_id,
    lease_expires_at,
    last_error_code,
    result_json
  )
  VALUES(
    p_organisation_id,
    v_seller,
    v_name,
    v_offering,
    btrim(p_objective_text),
    btrim(p_target_market_text),
    CASE WHEN v_no_hard THEN NULL ELSE v_hard END,
    v_no_hard,
    'PENDING',
    0,
    now(),
    NULL,
    NULL,
    NULL,
    '{}'::jsonb
  )
  ON CONFLICT(organisation_id) DO UPDATE
  SET seller_business_id = EXCLUDED.seller_business_id,
      campaign_name = EXCLUDED.campaign_name,
      seller_offering_text = EXCLUDED.seller_offering_text,
      objective_text = EXCLUDED.objective_text,
      target_market_text = EXCLUDED.target_market_text,
      hard_constraints_text = EXCLUDED.hard_constraints_text,
      no_hard_constraints = EXCLUDED.no_hard_constraints,
      status = 'PENDING',
      attempt_count = 0,
      available_at = now(),
      worker_id = NULL,
      lease_expires_at = NULL,
      last_error_code = NULL,
      result_json = '{}'::jsonb
  RETURNING id INTO v_job;

  RETURN v_job;
END;
$fn$;

REVOKE ALL ON FUNCTION public.marketroute_submit_replacement_campaign_v1(uuid,text,text,text,text,text,boolean)
FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_submit_replacement_campaign_v1(uuid,text,text,text,text,text,boolean)
TO authenticated;

-- V3 exposes the requested campaign name to the activation worker while V2
-- remains available during a migration-first production rollout.
CREATE OR REPLACE FUNCTION public.marketroute_claim_workspace_activation_v3(
  p_worker_id text,
  p_at timestamptz DEFAULT now()
)
RETURNS TABLE(
  job_id uuid,
  organisation_id uuid,
  seller_business_id uuid,
  seller_name text,
  canonical_domain text,
  website_url text,
  created_by_user_id uuid,
  campaign_name text,
  seller_offering_text text,
  objective_text text,
  target_market_text text,
  hard_constraints_text text,
  no_hard_constraints boolean,
  attempt_count integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_id uuid;
BEGIN
  PERFORM public.marketroute_require_service_role();

  SELECT j.id
  INTO v_id
  FROM public.workspace_activation_jobs AS j
  WHERE (
      (j.status IN ('PENDING','FAILED') AND j.available_at <= p_at)
      OR (j.status = 'RUNNING' AND j.lease_expires_at < p_at)
    )
    AND j.attempt_count < 5
    AND j.seller_offering_text IS NOT NULL
  ORDER BY j.available_at, j.created_at
  FOR UPDATE SKIP LOCKED
  LIMIT 1;

  IF v_id IS NULL THEN
    RETURN;
  END IF;

  UPDATE public.workspace_activation_jobs AS j
  SET status = 'RUNNING',
      attempt_count = j.attempt_count + 1,
      worker_id = left(btrim(p_worker_id), 200),
      lease_expires_at = p_at + interval '10 minutes',
      last_error_code = NULL
  WHERE j.id = v_id;

  RETURN QUERY
  SELECT
    j.id,
    j.organisation_id,
    j.seller_business_id,
    s.name,
    s.canonical_domain,
    s.website_url,
    o.created_by,
    j.campaign_name,
    j.seller_offering_text,
    j.objective_text,
    j.target_market_text,
    j.hard_constraints_text,
    j.no_hard_constraints,
    j.attempt_count
  FROM public.workspace_activation_jobs AS j
  JOIN public.seller_businesses AS s
    ON s.id = j.seller_business_id
   AND s.organisation_id = j.organisation_id
  JOIN public.organisations AS o ON o.id = j.organisation_id
  WHERE j.id = v_id;
END;
$fn$;

REVOKE ALL ON FUNCTION public.marketroute_claim_workspace_activation_v3(text,timestamptz)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_claim_workspace_activation_v3(text,timestamptz)
TO service_role;

-- V1 remains deployment compatible and now honours the name held on the job.
CREATE OR REPLACE FUNCTION public.marketroute_create_activation_campaign_v1(
  p_organisation_id uuid,
  p_seller_business_id uuid,
  p_objective_text text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_id uuid;
  v_user uuid;
  v_name text;
BEGIN
  PERFORM public.marketroute_require_service_role();

  SELECT created_by
  INTO v_user
  FROM public.organisations
  WHERE id = p_organisation_id
  FOR UPDATE;

  IF v_user IS NULL OR NOT EXISTS (
    SELECT 1
    FROM public.seller_businesses
    WHERE id = p_seller_business_id
      AND organisation_id = p_organisation_id
      AND lifecycle_state = 'ACTIVE'
  ) THEN
    RAISE EXCEPTION 'MARKETROUTE_ACTIVATION_SCOPE_INVALID';
  END IF;

  SELECT COALESCE(nullif(btrim(j.campaign_name), ''), 'Initial market research')
  INTO v_name
  FROM public.workspace_activation_jobs AS j
  WHERE j.organisation_id = p_organisation_id;
  v_name := COALESCE(v_name, 'Initial market research');

  SELECT id
  INTO v_id
  FROM public.campaigns
  WHERE organisation_id = p_organisation_id
    AND seller_business_id = p_seller_business_id
    AND workflow_state <> 'ARCHIVED'
  ORDER BY created_at
  LIMIT 1;

  IF v_id IS NULL THEN
    INSERT INTO public.campaigns(
      organisation_id,
      seller_business_id,
      name,
      workflow_state,
      objective_text,
      created_by
    )
    VALUES(
      p_organisation_id,
      p_seller_business_id,
      v_name,
      'ACTIVE',
      btrim(p_objective_text),
      v_user
    )
    RETURNING id INTO v_id;
  ELSE
    UPDATE public.campaigns
    SET name = v_name,
        workflow_state = 'ACTIVE',
        objective_text = btrim(p_objective_text),
        updated_at = now()
    WHERE id = v_id;
  END IF;

  RETURN v_id;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.marketroute_create_activation_campaign_v2(
  p_organisation_id uuid,
  p_seller_business_id uuid,
  p_campaign_name text,
  p_objective_text text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_id uuid;
  v_user uuid;
  v_name text := COALESCE(nullif(btrim(p_campaign_name), ''), 'Initial market research');
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF length(v_name) NOT BETWEEN 3 AND 120 THEN
    RAISE EXCEPTION 'MARKETROUTE_CAMPAIGN_NAME_REQUIRED';
  END IF;

  SELECT created_by
  INTO v_user
  FROM public.organisations
  WHERE id = p_organisation_id
  FOR UPDATE;

  IF v_user IS NULL OR NOT EXISTS (
    SELECT 1
    FROM public.seller_businesses
    WHERE id = p_seller_business_id
      AND organisation_id = p_organisation_id
      AND lifecycle_state = 'ACTIVE'
  ) THEN
    RAISE EXCEPTION 'MARKETROUTE_ACTIVATION_SCOPE_INVALID';
  END IF;

  SELECT id
  INTO v_id
  FROM public.campaigns
  WHERE organisation_id = p_organisation_id
    AND seller_business_id = p_seller_business_id
    AND workflow_state <> 'ARCHIVED'
  ORDER BY created_at
  LIMIT 1;

  IF v_id IS NULL THEN
    INSERT INTO public.campaigns(
      organisation_id,
      seller_business_id,
      name,
      workflow_state,
      objective_text,
      created_by
    )
    VALUES(
      p_organisation_id,
      p_seller_business_id,
      v_name,
      'ACTIVE',
      btrim(p_objective_text),
      v_user
    )
    RETURNING id INTO v_id;
  ELSE
    UPDATE public.campaigns
    SET name = v_name,
        workflow_state = 'ACTIVE',
        objective_text = btrim(p_objective_text),
        updated_at = now()
    WHERE id = v_id;
  END IF;

  RETURN v_id;
END;
$fn$;

REVOKE ALL ON FUNCTION public.marketroute_create_activation_campaign_v1(uuid,uuid,text)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_create_activation_campaign_v1(uuid,uuid,text)
TO service_role;

REVOKE ALL ON FUNCTION public.marketroute_create_activation_campaign_v2(uuid,uuid,text,text)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_create_activation_campaign_v2(uuid,uuid,text,text)
TO service_role;

INSERT INTO public.marketroute_schema_releases(
  release_key,
  build_number,
  constitution_version,
  metadata_json
)
VALUES(
  'MARKETROUTE_V2_CAMPAIGN_RECREATION_AFTER_ARCHIVE_0_18_3_15',
  18,
  'MRV2-CONSTITUTION-1.0.0',
  jsonb_build_object(
    'migration','0035_campaign_recreation_after_archive.sql',
    'new_authority_writer',false,
    'archived_campaigns_restored',false,
    'archived_campaigns_deleted',false,
    'requires_zero_live_campaigns',true,
    'typed_campaign_name',true,
    'migration_first_rollout_compatible',true
  )
)
ON CONFLICT(release_key) DO NOTHING;

NOTIFY pgrst,'reload schema';
COMMIT;
