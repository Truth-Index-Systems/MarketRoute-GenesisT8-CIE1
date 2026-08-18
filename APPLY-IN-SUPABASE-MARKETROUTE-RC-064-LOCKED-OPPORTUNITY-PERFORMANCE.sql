BEGIN;

-- MarketRoute V2 RC: locked-opportunity projection + bootstrap performance hardening.
-- This migration removes expensive per-opportunity exact authority recomputation from
-- commercial list/entitlement/refill surfaces. It reuses the bounded materialised
-- opportunity projection introduced in migration 0058. Exact current authority remains
-- mandatory on company/opportunity detail and engagement execution paths.
-- No Truth/R4/R5/R6 authority writer is added or changed.

CREATE OR REPLACE FUNCTION public.marketroute_materialised_ready_opportunities_v1(
  p_organisation_id uuid,
  p_campaign_id uuid,
  p_limit integer DEFAULT 250,
  p_at timestamptz DEFAULT now()
)
RETURNS TABLE(
  opportunity_id uuid,
  company_id uuid,
  company_name text,
  canonical_domain text,
  discovered_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
WITH profiles AS MATERIALIZED (
  SELECT value AS profile
  FROM jsonb_array_elements(
    public.marketroute_application_materialised_profile_index_v1(
      p_organisation_id,
      p_campaign_id,
      true,
      greatest(1,least(COALESCE(p_limit,250),250)),
      0,
      COALESCE(p_at,now())
    )
  )
), ready AS MATERIALIZED (
  SELECT
    NULLIF(profile->>'opportunityId','')::uuid AS opportunity_id,
    NULLIF(profile->>'companyId','')::uuid AS company_id
  FROM profiles
  WHERE COALESCE((profile->>'authorityReady')::boolean,false)
    AND COALESCE((profile->>'materialisedSyncCurrent')::boolean,false)
    AND profile->>'workflowState' IN('REVIEWABLE','APPROVED','ENGAGED')
)
SELECT
  o.id,
  o.company_id,
  c.canonical_name,
  c.canonical_domain,
  o.created_at
FROM ready r
JOIN public.opportunities o
  ON o.id=r.opportunity_id
 AND o.organisation_id=p_organisation_id
 AND o.campaign_id=p_campaign_id
 AND o.company_id=r.company_id
JOIN public.companies c ON c.id=o.company_id
ORDER BY o.created_at,o.id
LIMIT greatest(1,least(COALESCE(p_limit,250),250));
$fn$;

REVOKE ALL ON FUNCTION public.marketroute_materialised_ready_opportunities_v1(uuid,uuid,integer,timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_materialised_ready_opportunities_v1(uuid,uuid,integer,timestamptz) TO service_role;

-- Refill orchestration only needs a bounded, already-materialised proof that the exact
-- authority engine previously emitted an authority-ready sync for the current persisted
-- R4/R5/R6 lineage. It must not recompute the full claim-universe graph for every row on
-- every bootstrap tick.
CREATE OR REPLACE FUNCTION public.marketroute_campaign_authority_ready_count_v1(
  p_organisation_id uuid,
  p_campaign_id uuid,
  p_at timestamptz DEFAULT now()
)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
  SELECT COALESCE(count(DISTINCT r.company_id),0)::int
  FROM public.marketroute_materialised_ready_opportunities_v1(
    p_organisation_id,p_campaign_id,250,COALESCE(p_at,now())
  ) r;
$fn$;

CREATE OR REPLACE FUNCTION public.marketroute_anonymous_discovery_ready_count_v1(
  p_run_id uuid,
  p_at timestamptz DEFAULT now()
)
RETURNS integer
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
DECLARE
  v_run public.anonymous_discovery_runs%ROWTYPE;
BEGIN
  SELECT * INTO v_run FROM public.anonymous_discovery_runs WHERE id=p_run_id;
  IF NOT FOUND OR v_run.original_campaign_id IS NULL THEN RETURN 0; END IF;
  RETURN public.marketroute_campaign_authority_ready_count_v1(
    v_run.organisation_id,v_run.original_campaign_id,COALESCE(p_at,now())
  );
END;
$fn$;

REVOKE ALL ON FUNCTION public.marketroute_campaign_authority_ready_count_v1(uuid,uuid,timestamptz) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_anonymous_discovery_ready_count_v1(uuid,timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_campaign_authority_ready_count_v1(uuid,uuid,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_anonymous_discovery_ready_count_v1(uuid,timestamptz) TO service_role;

-- Claimed Discovery remains permanently bound to its immutable original campaign.
-- Free slots are allocated from the bounded materialised current-sync projection, rather
-- than evaluating marketroute_authority_ready_v1 once per opportunity on every page read.
CREATE OR REPLACE FUNCTION public.marketroute_discovery_free_access_v1(p_organisation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
DECLARE
  v_run public.anonymous_discovery_runs%ROWTYPE;
  v_campaign uuid;
  v_count integer:=0;
  v_candidate record;
  v_opps jsonb:='[]'::jsonb;
  v_companies jsonb:='[]'::jsonb;
BEGIN
  PERFORM public.marketroute_require_service_role();

  SELECT * INTO v_run
  FROM public.anonymous_discovery_runs
  WHERE organisation_id=p_organisation_id AND status='CLAIMED'
  ORDER BY created_at DESC,id DESC
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('mode','FULL','freeLimit',8,'opportunityIds','[]'::jsonb,'companyIds','[]'::jsonb,'campaignId',NULL);
  END IF;

  v_campaign:=v_run.original_campaign_id;
  IF v_campaign IS NULL THEN
    SELECT c.id INTO v_campaign
    FROM public.campaigns c
    WHERE c.organisation_id=p_organisation_id AND c.workflow_state<>'ARCHIVED'
    ORDER BY c.created_at,c.id
    LIMIT 1;
  END IF;

  IF v_campaign IS NOT NULL THEN
    SELECT count(*)::int INTO v_count
    FROM public.anonymous_discovery_opportunity_unlocks
    WHERE run_id=v_run.id;

    IF v_count<8 THEN
      FOR v_candidate IN
        SELECT r.opportunity_id,r.company_id
        FROM public.marketroute_materialised_ready_opportunities_v1(
          p_organisation_id,v_campaign,250,now()
        ) r
        WHERE NOT EXISTS(
          SELECT 1
          FROM public.anonymous_discovery_opportunity_unlocks u
          WHERE u.run_id=v_run.id AND u.opportunity_id=r.opportunity_id
        )
        ORDER BY r.discovered_at,r.opportunity_id
        LIMIT greatest(0,8-v_count)
      LOOP
        BEGIN
          v_count:=v_count+1;
          INSERT INTO public.anonymous_discovery_opportunity_unlocks(run_id,opportunity_id,company_id,ordinal)
          VALUES(v_run.id,v_candidate.opportunity_id,v_candidate.company_id,v_count)
          ON CONFLICT DO NOTHING;
        EXCEPTION WHEN unique_violation THEN
          -- Concurrent entitlement reads may race on the next ordinal. Recount and let
          -- the next read fill any remaining slot; entitlement never exceeds eight.
          SELECT count(*)::int INTO v_count
          FROM public.anonymous_discovery_opportunity_unlocks
          WHERE run_id=v_run.id;
        END;
      END LOOP;
    END IF;
  END IF;

  SELECT
    COALESCE(jsonb_agg(u.opportunity_id::text ORDER BY u.ordinal),'[]'::jsonb),
    COALESCE(jsonb_agg(u.company_id::text ORDER BY u.ordinal),'[]'::jsonb)
  INTO v_opps,v_companies
  FROM public.anonymous_discovery_opportunity_unlocks u
  WHERE u.run_id=v_run.id;

  RETURN jsonb_build_object(
    'mode','DISCOVERY_FREE',
    'runId',v_run.id,
    'campaignId',v_campaign,
    'freeLimit',8,
    'opportunityIds',v_opps,
    'companyIds',v_companies
  );
END;
$fn$;

REVOKE ALL ON FUNCTION public.marketroute_discovery_free_access_v1(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_discovery_free_access_v1(uuid) TO service_role;

-- The browser Discovery refresh uses the same bounded current-sync projection. This is
-- a commercial allocation projection only; exact authority remains owned by R4/R5/R6.
CREATE OR REPLACE FUNCTION public.marketroute_anonymous_discovery_refresh_unlocks_v1(p_browser_key_hash text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
DECLARE
  v_run public.anonymous_discovery_runs%ROWTYPE;
  v_campaign uuid;
  v_count integer:=0;
  v_candidate record;
  v_result jsonb:='[]'::jsonb;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF COALESCE(p_browser_key_hash,'') !~ '^[a-f0-9]{64}$' THEN
    RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_HASH_INVALID';
  END IF;

  SELECT * INTO v_run
  FROM public.anonymous_discovery_runs
  WHERE browser_key_hash=p_browser_key_hash
  FOR UPDATE;

  IF NOT FOUND OR v_run.status='BLOCKED' THEN RETURN '[]'::jsonb; END IF;

  v_campaign:=v_run.original_campaign_id;
  IF v_campaign IS NULL THEN
    SELECT NULLIF(j.result_json->>'campaignId','')::uuid INTO v_campaign
    FROM public.workspace_activation_jobs j
    WHERE j.id=v_run.activation_job_id;
  END IF;
  IF v_campaign IS NULL THEN
    SELECT c.id INTO v_campaign
    FROM public.campaigns c
    WHERE c.organisation_id=v_run.organisation_id AND c.workflow_state<>'ARCHIVED'
    ORDER BY c.created_at,c.id
    LIMIT 1;
  END IF;
  IF v_campaign IS NULL THEN RETURN '[]'::jsonb; END IF;

  SELECT count(*)::int INTO v_count
  FROM public.anonymous_discovery_opportunity_unlocks
  WHERE run_id=v_run.id;

  IF v_count<8 THEN
    FOR v_candidate IN
      SELECT r.opportunity_id,r.company_id
      FROM public.marketroute_materialised_ready_opportunities_v1(
        v_run.organisation_id,v_campaign,250,now()
      ) r
      WHERE NOT EXISTS(
        SELECT 1 FROM public.anonymous_discovery_opportunity_unlocks u
        WHERE u.run_id=v_run.id AND u.opportunity_id=r.opportunity_id
      )
      ORDER BY r.discovered_at,r.opportunity_id
      LIMIT greatest(0,8-v_count)
    LOOP
      BEGIN
        v_count:=v_count+1;
        INSERT INTO public.anonymous_discovery_opportunity_unlocks(run_id,opportunity_id,company_id,ordinal)
        VALUES(v_run.id,v_candidate.opportunity_id,v_candidate.company_id,v_count)
        ON CONFLICT DO NOTHING;
      EXCEPTION WHEN unique_violation THEN
        SELECT count(*)::int INTO v_count
        FROM public.anonymous_discovery_opportunity_unlocks
        WHERE run_id=v_run.id;
      END;
    END LOOP;
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'ordinal',u.ordinal,
    'opportunityId',u.opportunity_id,
    'companyId',u.company_id,
    'unlockedAt',u.unlocked_at,
    'company',public.marketroute_application_company_read_v1(v_run.organisation_id,v_campaign,u.company_id,now()),
    'routes',public.marketroute_application_route_display_read_v1(v_run.organisation_id,v_campaign,u.company_id,now())
  ) ORDER BY u.ordinal),'[]'::jsonb)
  INTO v_result
  FROM public.anonymous_discovery_opportunity_unlocks u
  WHERE u.run_id=v_run.id;

  RETURN v_result;
END;
$fn$;

REVOKE ALL ON FUNCTION public.marketroute_anonymous_discovery_refresh_unlocks_v1(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_anonymous_discovery_refresh_unlocks_v1(text) TO service_role;

-- Commercial access is a list/entitlement surface. Locked teasers use the materialised
-- sync projection and are capped at two. No full company/route/contact payload is exposed.
CREATE OR REPLACE FUNCTION public.marketroute_workspace_commercial_access_v1(
  p_organisation_id uuid,
  p_at timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
DECLARE
  v_ent public.organisation_commercial_entitlements%ROWTYPE;
  v_plan public.marketroute_plan_catalog%ROWTYPE;
  v_run public.anonymous_discovery_runs%ROWTYPE;
  v_campaign uuid;
  v_access jsonb;
  v_locked jsonb:='[]'::jsonb;
  v_locked_count integer:=0;
  v_unlocked_count integer:=0;
  v_capacity jsonb;
BEGIN
  PERFORM public.marketroute_require_service_role();

  SELECT * INTO v_ent
  FROM public.organisation_commercial_entitlements e
  WHERE e.organisation_id=p_organisation_id AND e.status='ACTIVE'
    AND (e.current_period_start IS NULL OR e.current_period_start<=p_at)
    AND (e.current_period_end IS NULL OR e.current_period_end>p_at)
  LIMIT 1;

  IF FOUND AND v_ent.plan_code IN('STARTER','GROWTH','SCALE','LEGACY_FULL') THEN
    SELECT * INTO v_plan FROM public.marketroute_plan_catalog WHERE plan_code=v_ent.plan_code;
    SELECT c.id INTO v_campaign
    FROM public.campaigns c
    WHERE c.organisation_id=p_organisation_id AND c.workflow_state<>'ARCHIVED'
    ORDER BY c.created_at DESC,c.id DESC LIMIT 1;
    v_capacity:=public.marketroute_research_capacity_snapshot_v1(p_organisation_id,p_at);
    RETURN jsonb_build_object(
      'mode',CASE WHEN v_ent.plan_code='LEGACY_FULL' THEN 'FULL' ELSE 'PAID' END,
      'planCode',v_ent.plan_code,'planName',v_plan.display_name,'campaignId',v_campaign,
      'freeLimit',8,'unlockedCount',NULL,'lockedCount',0,
      'opportunityIds','[]'::jsonb,'companyIds','[]'::jsonb,'lockedOpportunities','[]'::jsonb,
      'researchCapacity',v_capacity
    );
  END IF;

  SELECT * INTO v_run
  FROM public.anonymous_discovery_runs a
  WHERE a.organisation_id=p_organisation_id AND a.status='CLAIMED'
  ORDER BY a.created_at DESC,a.id DESC
  LIMIT 1
  FOR UPDATE;

  IF FOUND THEN
    v_access:=public.marketroute_discovery_free_access_v1(p_organisation_id);
    v_campaign:=COALESCE(v_run.original_campaign_id,NULLIF(v_access->>'campaignId','')::uuid);

    SELECT count(*)::int INTO v_unlocked_count
    FROM public.anonymous_discovery_opportunity_unlocks u
    WHERE u.run_id=v_run.id;

    IF v_campaign IS NOT NULL THEN
      WITH locked AS MATERIALIZED (
        SELECT r.opportunity_id,r.company_id,r.company_name,r.canonical_domain,r.discovered_at
        FROM public.marketroute_materialised_ready_opportunities_v1(
          p_organisation_id,v_campaign,250,p_at
        ) r
        WHERE NOT EXISTS(
          SELECT 1
          FROM public.anonymous_discovery_opportunity_unlocks u
          WHERE u.run_id=v_run.id AND u.opportunity_id=r.opportunity_id
        )
        ORDER BY r.discovered_at,r.opportunity_id
        LIMIT 2
      )
      SELECT
        count(*)::int,
        COALESCE(jsonb_agg(jsonb_build_object(
          'opportunityId',l.opportunity_id,
          'companyId',l.company_id,
          'companyName',l.company_name,
          'canonicalDomain',l.canonical_domain,
          'discoveredAt',l.discovered_at,
          'state','READY_LOCKED'
        ) ORDER BY l.discovered_at,l.opportunity_id),'[]'::jsonb)
      INTO v_locked_count,v_locked
      FROM locked l;
    END IF;

    RETURN jsonb_build_object(
      'mode','DISCOVERY_FREE',
      'planCode','DISCOVERY',
      'planName','MarketRoute Discovery',
      'campaignId',v_campaign,
      'freeLimit',8,
      'unlockedCount',v_unlocked_count,
      'lockedCount',v_locked_count,
      'opportunityIds',COALESCE(v_access->'opportunityIds','[]'::jsonb),
      'companyIds',COALESCE(v_access->'companyIds','[]'::jsonb),
      'lockedOpportunities',v_locked,
      'researchCapacity',jsonb_build_object(
        'limitUnits',0,'usedUnits',0,'remainingUnits',0,'periodStart',NULL,'periodEnd',NULL
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'mode','UNENTITLED','planCode',NULL,'planName',NULL,'campaignId',NULL,
    'freeLimit',0,'unlockedCount',0,'lockedCount',0,
    'opportunityIds','[]'::jsonb,'companyIds','[]'::jsonb,'lockedOpportunities','[]'::jsonb,
    'researchCapacity',jsonb_build_object(
      'limitUnits',0,'usedUnits',0,'remainingUnits',0,'periodStart',NULL,'periodEnd',NULL
    )
  );
END;
$fn$;

REVOKE ALL ON FUNCTION public.marketroute_workspace_commercial_access_v1(uuid,timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_workspace_commercial_access_v1(uuid,timestamptz) TO service_role;

INSERT INTO public.marketroute_schema_releases(
  release_key,build_number,constitution_version,metadata_json
)
VALUES(
  'MARKETROUTE_V2_RC_LOCKED_OPPORTUNITY_PROJECTION_BOOTSTRAP_PERFORMANCE_HARDENING',
  63,
  'MRV2-CONSTITUTION-1.0.0',
  jsonb_build_object(
    'migration','0063_locked_opportunity_projection_bootstrap_performance_hardening.sql',
    'new_authority_writer',false,
    'authority_semantics_unchanged',true,
    'locked_teaser_limit',2,
    'locked_payload_server_redacted',true,
    'commercial_access_exact_per_row_authority_recomputation_removed',true,
    'anonymous_ready_count_materialised_sync_projection',true,
    'paid_ready_count_materialised_sync_projection',true,
    'free_unlock_bound_to_original_campaign',true,
    'list_projection_requires_materialised_sync_current',true,
    'detail_exact_authority_unchanged',true,
    'engagement_exact_authority_unchanged',true,
    'autonomous_delivery_enabled',false
  )
)
ON CONFLICT(release_key) DO UPDATE SET metadata_json=EXCLUDED.metadata_json;

NOTIFY pgrst,'reload schema';
COMMIT;
