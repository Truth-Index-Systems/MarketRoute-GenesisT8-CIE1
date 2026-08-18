BEGIN;

-- MarketRoute RC: command-centre read performance hotfix.
-- The command centre is a summary projection. It must never recompute every
-- company authority profile across every campaign merely to render navigation
-- and aggregate counters. Detailed campaign/company reads remain canonical and
-- authority-current when the user opens those resources.

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
  v_campaign public.campaigns%ROWTYPE;
  v_seller public.seller_businesses%ROWTYPE;
  v_campaigns jsonb := '[]'::jsonb;
  v_policy jsonb;
  v_budget jsonb;
  v_engagement_policy text;
  v_scoped_count integer := 0;
  v_opportunity_count integer := 0;
  v_ready_count integer := 0;
  v_workflow_counts jsonb := '{}'::jsonb;
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
    v_seller := NULL;
    SELECT *
    INTO v_seller
    FROM public.seller_businesses
    WHERE id = v_campaign.seller_business_id
      AND organisation_id = p_organisation_id;

    SELECT count(*)::integer
    INTO v_scoped_count
    FROM public.organisation_company_scopes s
    WHERE s.organisation_id = p_organisation_id
      AND s.campaign_id = v_campaign.id
      AND s.scope_kind = 'CAMPAIGN';

    SELECT
      count(*)::integer,
      count(*) FILTER (
        WHERE o.workflow_state IN ('REVIEWABLE','APPROVED','ENGAGED')
      )::integer
    INTO v_opportunity_count, v_ready_count
    FROM public.opportunities o
    WHERE o.organisation_id = p_organisation_id
      AND o.campaign_id = v_campaign.id;

    SELECT COALESCE(jsonb_object_agg(workflow_state, cnt), '{}'::jsonb)
    INTO v_workflow_counts
    FROM (
      SELECT o.workflow_state, count(*)::integer AS cnt
      FROM public.opportunities o
      WHERE o.organisation_id = p_organisation_id
        AND o.campaign_id = v_campaign.id
      GROUP BY o.workflow_state
    ) w;

    -- These calls are campaign-level indexed aggregates only. They intentionally
    -- do not evaluate R4/R5/R6 per company. Detailed campaign reads still do.
    v_policy := public.marketroute_research_policy_v1(p_organisation_id, v_campaign.id);
    v_budget := public.marketroute_research_budget_snapshot_v1(p_organisation_id, v_campaign.id, p_at);
    v_engagement_policy := public.marketroute_current_engagement_policy_v1(p_organisation_id, v_campaign.id);

    v_campaigns := v_campaigns || jsonb_build_array(jsonb_build_object(
      'campaign', jsonb_build_object(
        'campaignId', v_campaign.id,
        'organisationId', v_campaign.organisation_id,
        'name', v_campaign.name,
        'workflowState', v_campaign.workflow_state,
        'objectiveText', v_campaign.objective_text,
        'createdAt', v_campaign.created_at,
        'updatedAt', v_campaign.updated_at
      ),
      'seller', CASE WHEN v_seller.id IS NULL THEN NULL ELSE jsonb_build_object(
        'sellerBusinessId', v_seller.id,
        'name', v_seller.name,
        'canonicalDomain', v_seller.canonical_domain,
        'websiteUrl', v_seller.website_url,
        'lifecycleState', v_seller.lifecycle_state
      ) END,
      'metrics', jsonb_build_object(
        'scopedCompanies', v_scoped_count,
        'materialisedOpportunities', v_opportunity_count,
        -- Command-centre readiness is the materialised workflow projection.
        -- It is not a new authority decision and never writes authority state.
        'lifecycleCounts', jsonb_build_object('AUTHORITY_READY', v_ready_count),
        'dispositionCounts', jsonb_build_object('ACTIONABLE', v_ready_count),
        'workflowCounts', v_workflow_counts
      ),
      'research', jsonb_build_object('policy', v_policy, 'budget', v_budget),
      'engagementPolicy', COALESCE(v_engagement_policy, 'HUMAN_ONLY')
    ));
  END LOOP;

  RETURN jsonb_build_object(
    'contractVersion', 'MRV2-APPLICATION-READ-1.0.0',
    'resourceType', 'COMMAND_CENTRE',
    'evaluatedAt', to_jsonb(p_at),
    'organisation', jsonb_build_object(
      'organisationId', v_org.id,
      'name', v_org.name,
      'slug', v_org.slug,
      'status', v_org.status
    ),
    'campaigns', v_campaigns
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
  'MARKETROUTE_V2_RC_COMMAND_CENTRE_READ_PERFORMANCE_HOTFIX',
  57,
  'MRV2-CONSTITUTION-1.0.0',
  jsonb_build_object(
    'migration','0057_command_centre_read_performance_hotfix.sql',
    'new_authority_writer',false,
    'authority_semantics_unchanged',true,
    'command_centre_summary_only',true,
    'full_campaign_read_removed_from_command_centre',true,
    'per_company_authority_recomputation_removed',true,
    'materialised_workflow_projection_used_for_summary_readiness',true,
    'detailed_campaign_read_unchanged',true,
    'autonomous_delivery_enabled',false
  )
)
ON CONFLICT(release_key) DO UPDATE
SET metadata_json = EXCLUDED.metadata_json;

NOTIFY pgrst, 'reload schema';
COMMIT;
