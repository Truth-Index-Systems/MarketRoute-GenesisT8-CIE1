-- AWS-V0 Build 3 canonical baseline candidate
-- Fresh data. Final logic. Clean provenance.
-- DO NOT APPLY TO AURORA YET. SECOND DISPOSABLE POSTGRESQL 16 VALIDATION REQUIRED.

--
-- PostgreSQL database dump
--

\restrict H6oion6irRscKYY6yIc16BK2Fblj2c5ajYd4s2c05hb6HmTNdecG436YImEwPZ3

-- Dumped from database version 16.15 (Debian 16.15-1.pgdg13+2)
-- Dumped by pg_dump version 16.15 (Ubuntu 16.15-1.pgdg24.04+2)

SET statement_timeout = 0;

SET lock_timeout = 0;

SET idle_in_transaction_session_timeout = 0;

SET client_encoding = 'UTF8';

SET standard_conforming_strings = on;

SELECT pg_catalog.set_config('search_path', '', false);

SET check_function_bodies = false;

SET xmloption = content;

SET client_min_messages = warning;

SET row_security = off;

--
-- Name: extensions; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA extensions;

--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';

--
-- Name: marketroute_activation_bank_candidates_v1(text[], text[], integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_activation_bank_candidates_v1(p_industry_keys text[], p_country_codes text[] DEFAULT '{}'::text[], p_limit integer DEFAULT 12) RETURNS TABLE(company_id uuid, name text, canonical_domain text, website_url text, country_code text, industry_key text, core_complete boolean, profile_complete boolean, routes_complete boolean, contacts_complete boolean)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF COALESCE(cardinality(p_industry_keys),0)=0 THEN RETURN; END IF;

  RETURN QUERY
  WITH eligible AS (
    SELECT
      c.id AS company_id,
      c.canonical_name AS company_name,
      c.canonical_domain,
      COALESCE(c.website_url,'https://'||c.canonical_domain) AS website_url,
      c.country_code,
      min(m.industry_key) AS industry_key,
      bool_or(COALESCE(p.core_complete_at IS NOT NULL,false)) AS core_complete,
      bool_or(COALESCE(p.profile_complete_at IS NOT NULL,false)) AS profile_complete,
      bool_or(COALESCE(p.routes_complete_at IS NOT NULL,false)) AS routes_complete,
      bool_or(COALESCE(p.contacts_complete_at IS NOT NULL,false)) AS contacts_complete,
      max(p.last_researched_at) AS last_researched_at,
      max(
        20
        + CASE WHEN p.core_complete_at IS NOT NULL THEN 20 ELSE 0 END
        + CASE WHEN p.profile_complete_at IS NOT NULL THEN 20 ELSE 0 END
        + CASE WHEN p.routes_complete_at IS NOT NULL THEN 20 ELSE 0 END
        + CASE WHEN p.contacts_complete_at IS NOT NULL THEN 20 ELSE 0 END
      ) AS density_percent
    FROM public.genesis_growth_company_memberships m
    JOIN public.genesis_growth_industries i ON i.industry_key=m.industry_key AND i.enabled=true
    JOIN public.companies c ON c.id=m.company_id AND c.lifecycle_state='ACTIVE'
    LEFT JOIN public.genesis_growth_company_progress p ON p.company_id=c.id
    WHERE m.industry_key=ANY(p_industry_keys)
      AND c.canonical_domain IS NOT NULL
      AND (
        COALESCE(cardinality(p_country_codes),0)=0
        OR upper(COALESCE(c.country_code,''))=ANY(ARRAY(SELECT upper(x) FROM unnest(p_country_codes) x))
      )
    GROUP BY c.id,c.canonical_name,c.canonical_domain,c.website_url,c.country_code
  )
  SELECT e.company_id,e.company_name,e.canonical_domain,e.website_url,e.country_code,e.industry_key,
         e.core_complete,e.profile_complete,e.routes_complete,e.contacts_complete
  FROM eligible e
  ORDER BY e.density_percent DESC,e.last_researched_at DESC NULLS LAST,e.canonical_domain,e.company_id
  LIMIT greatest(1,least(COALESCE(p_limit,12),25));
END;
$$;

--
-- Name: marketroute_anonymous_discovery_budget_state_v1(uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_anonymous_discovery_budget_state_v1(p_run_id uuid, p_at timestamp with time zone DEFAULT now()) RETURNS TABLE(budget_state text, remaining_usd numeric, active_research_jobs integer, zero_cost_waiting integer, minimum_positive_waiting_cost_usd numeric)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  WITH run_scope AS (
    SELECT r.id,r.organisation_id,r.original_campaign_id,r.lifetime_budget_usd,r.research_expires_at
    FROM public.anonymous_discovery_runs r
    WHERE r.id=p_run_id
  ),
  committed AS (
    SELECT COALESCE(sum(e.amount_usd),0)::numeric AS amount
    FROM run_scope r
    LEFT JOIN public.research_budget_events e
      ON e.organisation_id=r.organisation_id
     AND e.campaign_id=r.original_campaign_id
     AND e.event_type='COMMIT'
  ),
  reserved AS (
    SELECT COALESCE(sum(e.amount_usd),0)::numeric AS amount
    FROM run_scope r
    LEFT JOIN public.research_budget_events e
      ON e.organisation_id=r.organisation_id
     AND e.campaign_id=r.original_campaign_id
     AND e.event_type='RESERVE'
     AND NOT EXISTS(
       SELECT 1
       FROM public.research_budget_events x
       WHERE x.work_unit_id=e.work_unit_id
         AND x.attempt_number=e.attempt_number
         AND x.event_type IN('COMMIT','RELEASE')
     )
  ),
  queue AS (
    SELECT
      count(*) FILTER (WHERE j.status IN('RESERVED','RUNNING'))::int AS active_jobs,
      count(*) FILTER (WHERE j.status IN('PENDING','DEFERRED') AND w.cost_ceiling_usd=0)::int AS zero_waiting,
      min(w.cost_ceiling_usd) FILTER (WHERE j.status IN('PENDING','DEFERRED') AND w.cost_ceiling_usd>0) AS min_positive,
      bool_or(j.status='CANCELLED' AND j.last_error_code='MARKETROUTE_ANONYMOUS_RESEARCH_BUDGET_EXHAUSTED') AS budget_cancel_seen
    FROM run_scope r
    LEFT JOIN public.research_work_units w
      ON w.organisation_id=r.organisation_id
     AND w.campaign_id=r.original_campaign_id
    LEFT JOIN public.background_jobs j ON j.id=w.background_job_id
  ),
  state AS (
    SELECT
      r.*,
      GREATEST(0,r.lifetime_budget_usd-(SELECT amount FROM committed)-(SELECT amount FROM reserved))::numeric AS remaining,
      COALESCE(q.active_jobs,0)::int AS active_jobs,
      COALESCE(q.zero_waiting,0)::int AS zero_waiting,
      q.min_positive,
      COALESCE(q.budget_cancel_seen,false) AS budget_cancel_seen
    FROM run_scope r
    CROSS JOIN queue q
  )
  SELECT
    CASE
      WHEN s.research_expires_at<=COALESCE(p_at,now()) THEN 'WINDOW_CLOSED'
      WHEN s.active_jobs>0 OR s.zero_waiting>0 THEN 'AVAILABLE'
      WHEN s.remaining<=0 AND (s.budget_cancel_seen OR s.min_positive IS NOT NULL) THEN 'EXHAUSTED'
      WHEN s.remaining>0 AND s.min_positive IS NOT NULL AND s.min_positive>s.remaining THEN 'INSUFFICIENT_FOR_WAITING_WORK'
      ELSE 'AVAILABLE'
    END,
    s.remaining,
    s.active_jobs,
    s.zero_waiting,
    s.min_positive
  FROM state s;
$$;

--
-- Name: marketroute_anonymous_discovery_budget_terminal_v1(uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_anonymous_discovery_budget_terminal_v1(p_run_id uuid, p_at timestamp with time zone DEFAULT now()) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  SELECT COALESCE((
    SELECT b.budget_state IN('WINDOW_CLOSED','EXHAUSTED','INSUFFICIENT_FOR_WAITING_WORK')
    FROM public.marketroute_anonymous_discovery_budget_state_v1(p_run_id,p_at) b
  ),false);
$$;

--
-- Name: marketroute_anonymous_discovery_policy_for_activation_v1(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_anonymous_discovery_policy_for_activation_v1(p_organisation_id uuid, p_activation_job_id uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_run public.anonymous_discovery_runs%ROWTYPE;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF NOT EXISTS(
    SELECT 1 FROM public.workspace_activation_jobs j
    WHERE j.id=p_activation_job_id AND j.organisation_id=p_organisation_id AND j.activation_kind='ANONYMOUS_DISCOVERY'
  ) THEN RETURN NULL; END IF;
  IF public.marketroute_paid_entitlement_active_v1(p_organisation_id,now()) THEN RETURN NULL; END IF;
  SELECT * INTO v_run
  FROM public.anonymous_discovery_runs r
  WHERE r.organisation_id=p_organisation_id
    AND r.activation_job_id=p_activation_job_id
    AND r.status IN('ACTIVE','CLAIMED')
    AND r.research_expires_at>now();
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN jsonb_build_object(
    'runId',v_run.id,'lifetimeBudgetUsd',v_run.lifetime_budget_usd,
    'researchExpiresAt',v_run.research_expires_at,'targetCount',v_run.target_count,
    'originalCampaignId',v_run.original_campaign_id
  );
END;
$$;

--
-- Name: marketroute_anonymous_discovery_policy_v1(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_anonymous_discovery_policy_v1(p_organisation_id uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_run public.anonymous_discovery_runs%ROWTYPE;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF public.marketroute_paid_entitlement_active_v1(p_organisation_id,now()) THEN RETURN NULL; END IF;
  IF EXISTS(
    SELECT 1 FROM public.workspace_activation_jobs j
    WHERE j.organisation_id=p_organisation_id
      AND j.status='RUNNING'
      AND j.activation_kind<>'ANONYMOUS_DISCOVERY'
  ) THEN RETURN NULL; END IF;
  SELECT * INTO v_run
  FROM public.anonymous_discovery_runs r
  JOIN public.workspace_activation_jobs j ON j.id=r.activation_job_id
  WHERE r.organisation_id=p_organisation_id
    AND j.activation_kind='ANONYMOUS_DISCOVERY'
    AND r.status IN('ACTIVE','CLAIMED')
    AND r.research_expires_at>now();
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN jsonb_build_object(
    'runId',v_run.id,'lifetimeBudgetUsd',v_run.lifetime_budget_usd,
    'researchExpiresAt',v_run.research_expires_at,'targetCount',v_run.target_count,
    'originalCampaignId',v_run.original_campaign_id
  );
END;
$$;

--
-- Name: marketroute_anonymous_discovery_ready_count_v1(uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_anonymous_discovery_ready_count_v1(p_run_id uuid, p_at timestamp with time zone DEFAULT now()) RETURNS integer
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_run public.anonymous_discovery_runs%ROWTYPE;
BEGIN
  SELECT * INTO v_run FROM public.anonymous_discovery_runs WHERE id=p_run_id;
  IF NOT FOUND OR v_run.original_campaign_id IS NULL THEN RETURN 0; END IF;
  RETURN public.marketroute_campaign_authority_ready_count_v1(
    v_run.organisation_id,v_run.original_campaign_id,COALESCE(p_at,now())
  );
END;
$$;

--
-- Name: marketroute_anonymous_discovery_refresh_unlocks_v1(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_anonymous_discovery_refresh_unlocks_v1(p_browser_key_hash text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
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
$_$;

--
-- Name: marketroute_anonymous_discovery_research_cycle_ready_v1(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_anonymous_discovery_research_cycle_ready_v1(p_run_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  SELECT COALESCE((
    SELECT r.original_campaign_id IS NOT NULL
      AND NOT EXISTS(
        SELECT 1
        FROM public.organisation_company_scopes s
        WHERE s.organisation_id=r.organisation_id
          AND s.campaign_id=r.original_campaign_id
          AND s.scope_kind='CAMPAIGN'
          AND NOT EXISTS(
            SELECT 1
            FROM public.truth_entity_snapshots t
            WHERE t.subject_type='COMPANY'
              AND t.subject_id=s.company_id
              AND t.profile_key='COMPANY_CORE_V1'
              AND (
                t.tenant_scope_organisation_id IS NULL
                OR t.tenant_scope_organisation_id=r.organisation_id
              )
          )
      )
    FROM public.anonymous_discovery_runs r
    WHERE r.id=p_run_id
  ),false);
$$;

--
-- Name: marketroute_anonymous_discovery_status_v1(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_anonymous_discovery_status_v1(p_browser_key_hash text) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_run public.anonymous_discovery_runs%ROWTYPE;v_job public.workspace_activation_jobs%ROWTYPE;v_campaign uuid;
  v_scoped int:=0;v_researched int:=0;v_work_total int:=0;v_work_done int:=0;v_opps int:=0;v_r5 int:=0;v_r6 int:=0;v_free int:=0;
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT * INTO v_run FROM public.anonymous_discovery_runs WHERE browser_key_hash=p_browser_key_hash; IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT * INTO v_job FROM public.workspace_activation_jobs WHERE id=v_run.activation_job_id;
  v_campaign:=v_run.original_campaign_id;
  IF v_campaign IS NOT NULL THEN
    SELECT count(*)::int INTO v_scoped FROM public.organisation_company_scopes WHERE organisation_id=v_run.organisation_id AND campaign_id=v_campaign AND scope_kind='CAMPAIGN';
    SELECT count(DISTINCT s.company_id)::int INTO v_researched FROM public.organisation_company_scopes s WHERE s.organisation_id=v_run.organisation_id AND s.campaign_id=v_campaign AND s.scope_kind='CAMPAIGN' AND EXISTS(SELECT 1 FROM public.truth_entity_snapshots t WHERE t.subject_type='COMPANY' AND t.subject_id=s.company_id AND t.profile_key='COMPANY_CORE_V1' AND (t.tenant_scope_organisation_id IS NULL OR t.tenant_scope_organisation_id=v_run.organisation_id));
    SELECT count(*)::int,count(*) FILTER(WHERE j.status='SUCCEEDED')::int INTO v_work_total,v_work_done FROM public.research_work_units w JOIN public.background_jobs j ON j.id=w.background_job_id WHERE w.organisation_id=v_run.organisation_id AND w.campaign_id=v_campaign;
    SELECT count(*)::int INTO v_opps FROM public.opportunities WHERE organisation_id=v_run.organisation_id AND campaign_id=v_campaign;
    SELECT count(DISTINCT company_id)::int INTO v_r5 FROM public.route_authority_r5_records r WHERE r.organisation_id=v_run.organisation_id AND r.campaign_id=v_campaign AND r.decision_code='ROUTE_STRUCTURALLY_OPEN' AND public.marketroute_r5_authority_current_v1(r.authority_record_id,now());
    SELECT count(DISTINCT company_id)::int INTO v_r6 FROM public.contact_authority_r6_records r WHERE r.organisation_id=v_run.organisation_id AND r.campaign_id=v_campaign AND r.decision_code='CONTACT_AUTHORISED' AND public.marketroute_r6_authority_current_v1(r.authority_record_id,now());
  END IF;
  SELECT count(*)::int INTO v_free FROM public.anonymous_discovery_opportunity_unlocks WHERE run_id=v_run.id;
  RETURN jsonb_build_object(
    'runId',v_run.id,'companyName',v_run.company_name,'websiteUrl',v_run.website_url,
    'runStatus',CASE WHEN v_run.status='ACTIVE' AND v_run.research_expires_at<=now() THEN 'EXPIRED' ELSE v_run.status END,
    'activation',jsonb_build_object('status',COALESCE(v_job.status,'PENDING'),'stage',COALESCE(v_job.activation_stage,'QUEUED'),'progress',COALESCE(v_job.activation_progress,0),'lastErrorCode',v_job.last_error_code,'updatedAt',v_job.updated_at,'stageDetail',COALESCE(v_job.activation_stage_detail_json,'{}'::jsonb)),
    'metrics',jsonb_build_object('scopedCompanies',v_scoped,'researchedCompanies',v_researched,'researchWorkTotal',v_work_total,'researchWorkCompleted',v_work_done,'opportunities',v_opps,'structuralRoutes',v_r5,'authorisedRoutes',v_r6,'freeUnlocked',v_free)
  );
END;
$$;

--
-- Name: marketroute_application_campaign_read_v1(uuid, uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_application_campaign_read_v1(p_organisation_id uuid, p_campaign_id uuid, p_at timestamp with time zone DEFAULT now()) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_campaign public.campaigns%ROWTYPE; v_seller public.seller_businesses%ROWTYPE; v_seller_context jsonb; v_profiles jsonb;
  v_policy jsonb; v_budget jsonb; v_engagement_policy text; v_scoped_count int:=0; v_opportunity_count int:=0;
  v_lifecycle_counts jsonb:='{}'::jsonb; v_disposition_counts jsonb:='{}'::jsonb; v_workflow_counts jsonb:='{}'::jsonb;
BEGIN
  PERFORM public.marketroute_require_service_role();
  PERFORM public.marketroute_application_require_current_read_time_v1(p_at);
  SELECT * INTO v_campaign FROM public.campaigns WHERE id=p_campaign_id AND organisation_id=p_organisation_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_APPLICATION_CAMPAIGN_NOT_FOUND'; END IF;
  SELECT * INTO v_seller FROM public.seller_businesses WHERE id=v_campaign.seller_business_id AND organisation_id=p_organisation_id;
  v_seller_context:=public.marketroute_get_current_campaign_seller_context_v1(p_organisation_id,p_campaign_id);
  v_policy:=public.marketroute_research_policy_v1(p_organisation_id,p_campaign_id);
  v_budget:=public.marketroute_research_budget_snapshot_v1(p_organisation_id,p_campaign_id,p_at);
  v_engagement_policy:=public.marketroute_current_engagement_policy_v1(p_organisation_id,p_campaign_id);
  SELECT count(*)::int INTO v_scoped_count FROM public.organisation_company_scopes s WHERE s.organisation_id=p_organisation_id AND s.campaign_id=p_campaign_id AND s.scope_kind='CAMPAIGN';
  SELECT count(*)::int INTO v_opportunity_count FROM public.opportunities o WHERE o.organisation_id=p_organisation_id AND o.campaign_id=p_campaign_id;
  v_profiles:=public.marketroute_list_opportunity_profiles_v1(p_organisation_id,p_campaign_id,p_at);

  WITH scoped_profiles AS MATERIALIZED (
    SELECT public.marketroute_opportunity_profile_v1(s.organisation_id,s.campaign_id,s.company_id,p_at) AS profile
    FROM public.organisation_company_scopes s
    WHERE s.organisation_id=p_organisation_id AND s.campaign_id=p_campaign_id AND s.scope_kind='CAMPAIGN'
  )
  SELECT
    COALESCE((SELECT jsonb_object_agg(lifecycle_state,cnt) FROM (SELECT profile->>'lifecycleState' lifecycle_state,count(*)::int cnt FROM scoped_profiles GROUP BY profile->>'lifecycleState') x),'{}'::jsonb),
    COALESCE((SELECT jsonb_object_agg(disposition,cnt) FROM (SELECT profile->>'disposition' disposition,count(*)::int cnt FROM scoped_profiles GROUP BY profile->>'disposition') y),'{}'::jsonb)
  INTO v_lifecycle_counts,v_disposition_counts;
  SELECT COALESCE(jsonb_object_agg(workflow_state,cnt),'{}'::jsonb) INTO v_workflow_counts FROM (
    SELECT workflow_state,count(*)::int cnt FROM public.opportunities WHERE organisation_id=p_organisation_id AND campaign_id=p_campaign_id GROUP BY workflow_state
  ) w;

  RETURN jsonb_build_object(
    'contractVersion','MRV2-APPLICATION-READ-1.0.0','resourceType','CAMPAIGN','evaluatedAt',to_jsonb(p_at),
    'campaign',jsonb_build_object('campaignId',v_campaign.id,'organisationId',v_campaign.organisation_id,'name',v_campaign.name,'workflowState',v_campaign.workflow_state,'objectiveText',v_campaign.objective_text,'createdAt',v_campaign.created_at,'updatedAt',v_campaign.updated_at),
    'seller',CASE WHEN v_seller.id IS NULL THEN NULL ELSE jsonb_build_object('sellerBusinessId',v_seller.id,'name',v_seller.name,'canonicalDomain',v_seller.canonical_domain,'websiteUrl',v_seller.website_url,'lifecycleState',v_seller.lifecycle_state) END,
    'sellerContext',CASE WHEN v_seller_context IS NULL THEN NULL ELSE jsonb_build_object(
      'selectionId',v_seller_context->'selectionId','genomeSnapshotId',v_seller_context->'genomeSnapshotId','objectiveKey',v_seller_context->'objectiveKey',
      'semanticFingerprint',v_seller_context->'semanticFingerprint','contentFingerprint',v_seller_context->'contentFingerprint'
    ) END,
    'metrics',jsonb_build_object('scopedCompanies',v_scoped_count,'materialisedOpportunities',v_opportunity_count,'lifecycleCounts',v_lifecycle_counts,'dispositionCounts',v_disposition_counts,'workflowCounts',v_workflow_counts),
    'research',jsonb_build_object('policy',v_policy,'budget',v_budget),
    'engagementPolicy',COALESCE(v_engagement_policy,'HUMAN_ONLY'),
    'opportunities',COALESCE(v_profiles,'[]'::jsonb)
  );
END $$;

--
-- Name: marketroute_application_claim_provenance_read_v1(uuid, uuid, uuid, uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_application_claim_provenance_read_v1(p_organisation_id uuid, p_campaign_id uuid, p_company_id uuid, p_claim_snapshot_id uuid, p_at timestamp with time zone DEFAULT now()) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_snapshot public.truth_claim_snapshots%ROWTYPE;
  v_claim public.claims%ROWTYPE;
  v_evidence jsonb:='[]'::jsonb;
  v_total int:=0;
BEGIN
  PERFORM public.marketroute_require_service_role();
  PERFORM public.marketroute_application_require_current_read_time_v1(p_at);
  IF NOT public.marketroute_application_claim_snapshot_in_current_lineage_v1(p_organisation_id,p_campaign_id,p_company_id,p_claim_snapshot_id,p_at) THEN
    RAISE EXCEPTION 'MARKETROUTE_APPLICATION_PROVENANCE_NOT_IN_CURRENT_LINEAGE';
  END IF;
  SELECT * INTO v_snapshot FROM public.truth_claim_snapshots WHERE id=p_claim_snapshot_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_APPLICATION_PROVENANCE_SNAPSHOT_NOT_FOUND'; END IF;
  SELECT * INTO v_claim FROM public.claims WHERE id=v_snapshot.claim_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_APPLICATION_PROVENANCE_CLAIM_NOT_FOUND'; END IF;

  IF v_claim.tenant_scope_organisation_id IS NOT NULL AND v_claim.tenant_scope_organisation_id<>p_organisation_id THEN
    RAISE EXCEPTION 'MARKETROUTE_APPLICATION_PROVENANCE_TENANT_MISMATCH';
  END IF;

  SELECT count(*)::int INTO v_total FROM public.claim_evidence_links l WHERE l.claim_id=v_claim.id;
  SELECT COALESCE(jsonb_agg(row_payload ORDER BY observed_at DESC,evidence_id DESC),'[]'::jsonb) INTO v_evidence FROM (
    SELECT e.observed_at,e.id evidence_id,jsonb_build_object(
      'evidenceId',e.id,
      'polarity',l.polarity,
      'dependenceFamilyKey',l.dependence_family_key,
      'evidenceKind',e.evidence_kind,
      'excerpt',e.excerpt_text,
      'structuredValue',e.structured_value_json,
      'observedAt',e.observed_at,
      'originPublishedAt',e.origin_published_at,
      'extractionMethod',e.extraction_method,
      'extractionVersion',e.extraction_version,
      'evidenceFingerprint',e.evidence_fingerprint,
      'temporalAnomalyAtSnapshot',(e.observed_at>v_snapshot.reference_time+interval '5 minutes' OR COALESCE(e.origin_published_at,s.published_at,e.observed_at)>v_snapshot.reference_time+interval '5 minutes'),
      'source',jsonb_build_object(
        'sourceId',s.id,'sourceKind',s.source_kind,'canonicalUrl',s.canonical_url,'publisherDomain',s.publisher_domain,
        'title',s.title,'publishedAt',s.published_at,'acquisitionId',a.id,'acquiredAt',a.acquired_at,'acquisitionMethod',a.acquisition_method
      )
    ) row_payload
    FROM public.claim_evidence_links l
    JOIN public.evidence_items e ON e.id=l.evidence_item_id
    JOIN public.source_acquisitions a ON a.id=e.acquisition_id
    JOIN public.source_records s ON s.id=a.source_id
    WHERE l.claim_id=v_claim.id
    ORDER BY e.observed_at DESC,e.id DESC
    LIMIT 50
  ) q;

  RETURN jsonb_build_object(
    'contractVersion','MRV2-APPLICATION-READ-1.0.0','resourceType','CLAIM_PROVENANCE','evaluatedAt',to_jsonb(p_at),
    'scope',jsonb_build_object('organisationId',p_organisation_id,'campaignId',p_campaign_id,'companyId',p_company_id),
    'truthSnapshot',jsonb_build_object(
      'snapshotId',v_snapshot.id,'snapshotFingerprint',v_snapshot.snapshot_fingerprint,'claimId',v_snapshot.claim_id,
      'claimKey',v_snapshot.claim_key,'truthState',v_snapshot.truth_state,'evidenceSufficiency',v_snapshot.evidence_sufficiency,
      'supportFamilyCount',v_snapshot.current_support_family_count,'contradictionFamilyCount',v_snapshot.current_contradiction_family_count,
      'staleFamilyCount',v_snapshot.stale_family_count,'temporalAnomalyCount',v_snapshot.temporal_anomaly_count,
      'freshnessCoverage',v_snapshot.freshness_coverage,'probabilityState',v_snapshot.probability_state,
      'referenceTime',v_snapshot.reference_time,'nextRevalidationAt',v_snapshot.next_revalidation_at
    ),
    'claim',jsonb_build_object(
      'claimId',v_claim.id,'subjectType',v_claim.subject_type,'subjectId',v_claim.subject_id,'claimKey',v_claim.claim_key,
      'predicate',v_claim.predicate,'canonicalValue',v_claim.canonical_value_text,'object',v_claim.object_json,
      'propositionFingerprint',v_snapshot.proposition_fingerprint
    ),
    'evidence',v_evidence,
    'evidenceCount',v_total,
    'returnedEvidenceCount',jsonb_array_length(v_evidence),
    'truncated',v_total>jsonb_array_length(v_evidence)
  );
END $$;

--
-- Name: marketroute_application_claim_snapshot_in_current_lineage_v1(uuid, uuid, uuid, uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_application_claim_snapshot_in_current_lineage_v1(p_organisation_id uuid, p_campaign_id uuid, p_company_id uuid, p_claim_snapshot_id uuid, p_at timestamp with time zone DEFAULT now()) RETURNS boolean
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_env jsonb;
  v_r4 public.commercial_reality_r4_records%ROWTYPE;
  v_r5 public.route_authority_r5_records%ROWTYPE;
  v_r6 public.contact_authority_r6_records%ROWTYPE;
  v_entity public.truth_entity_snapshots%ROWTYPE;
BEGIN
  PERFORM public.marketroute_require_service_role();
  PERFORM public.marketroute_application_require_current_read_time_v1(p_at);
  v_env:=public.marketroute_authority_envelope_v1(p_organisation_id,p_campaign_id,p_company_id,p_at);

  IF NULLIF(v_env->'r4'->>'authorityRecordId','') IS NOT NULL THEN
    SELECT * INTO v_r4 FROM public.commercial_reality_r4_records WHERE authority_record_id=(v_env->'r4'->>'authorityRecordId')::uuid;
    IF v_r4.id IS NOT NULL THEN
      SELECT * INTO v_entity FROM public.truth_entity_snapshots WHERE id=v_r4.target_truth_entity_snapshot_id;
      IF v_entity.id IS NOT NULL AND EXISTS(
        SELECT 1 FROM jsonb_each(v_entity.claim_snapshot_map) kv
        CROSS JOIN LATERAL jsonb_array_elements_text(kv.value) sid(value)
        WHERE sid.value=p_claim_snapshot_id::text
      ) THEN RETURN true; END IF;
      IF EXISTS(
        SELECT 1 FROM jsonb_each(v_r4.constraint_truth_snapshot_map) kv
        CROSS JOIN LATERAL jsonb_array_elements_text(kv.value) sid(value)
        WHERE sid.value=p_claim_snapshot_id::text
      ) THEN RETURN true; END IF;
    END IF;
  END IF;

  IF NULLIF(v_env->'r5'->>'authorityRecordId','') IS NOT NULL THEN
    SELECT * INTO v_r5 FROM public.route_authority_r5_records WHERE authority_record_id=(v_env->'r5'->>'authorityRecordId')::uuid;
    IF v_r5.id IS NOT NULL AND EXISTS(
      SELECT 1 FROM jsonb_each_text(v_r5.relationship_truth_snapshot_map) kv(key,value)
      WHERE kv.value=p_claim_snapshot_id::text
    ) THEN RETURN true; END IF;
  END IF;

  IF NULLIF(v_env->'r6'->>'authorityRecordId','') IS NOT NULL THEN
    SELECT * INTO v_r6 FROM public.contact_authority_r6_records WHERE authority_record_id=(v_env->'r6'->>'authorityRecordId')::uuid;
    IF v_r6.id IS NOT NULL AND EXISTS(
      SELECT 1 FROM jsonb_each_text(v_r6.contact_truth_snapshot_map) kv(key,value)
      WHERE kv.value=p_claim_snapshot_id::text
    ) THEN RETURN true; END IF;
  END IF;

  RETURN false;
END $$;

--
-- Name: marketroute_application_command_centre_read_v1(uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_application_command_centre_read_v1(p_organisation_id uuid, p_at timestamp with time zone DEFAULT now()) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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
$$;

--
-- Name: marketroute_application_company_index_read_v1(uuid, uuid, integer, integer, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_application_company_index_read_v1(p_organisation_id uuid, p_campaign_id uuid, p_limit integer DEFAULT 100, p_offset integer DEFAULT 0, p_at timestamp with time zone DEFAULT now()) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_limit integer := greatest(1,least(COALESCE(p_limit,100),250));
  v_offset integer := greatest(0,COALESCE(p_offset,0));
  v_total integer := 0;
  v_rows jsonb := '[]'::jsonb;
BEGIN
  PERFORM public.marketroute_require_service_role();
  PERFORM public.marketroute_application_require_current_read_time_v1(p_at);
  IF NOT EXISTS(SELECT 1 FROM public.campaigns c WHERE c.id=p_campaign_id AND c.organisation_id=p_organisation_id) THEN
    RAISE EXCEPTION 'MARKETROUTE_APPLICATION_COMPANY_INDEX_CAMPAIGN_NOT_FOUND';
  END IF;

  SELECT count(*)::integer INTO v_total
  FROM public.organisation_company_scopes s
  WHERE s.organisation_id=p_organisation_id AND s.campaign_id=p_campaign_id AND s.scope_kind='CAMPAIGN';

  v_rows := public.marketroute_application_materialised_profile_index_v1(
    p_organisation_id,p_campaign_id,false,v_limit,v_offset,p_at
  );

  RETURN jsonb_build_object(
    'contractVersion','MRV2-APPLICATION-READ-1.0.0',
    'resourceType','COMPANY_INDEX',
    'evaluatedAt',to_jsonb(p_at),
    'projectionKind','MATERIALISED_LIST_SUMMARY',
    'organisationId',p_organisation_id,
    'campaignId',p_campaign_id,
    'totalCount',v_total,
    'offset',v_offset,
    'limit',v_limit,
    'returnedCount',jsonb_array_length(v_rows),
    'companies',v_rows
  );
END;
$$;

--
-- Name: marketroute_application_company_read_v1(uuid, uuid, uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_application_company_read_v1(p_organisation_id uuid, p_campaign_id uuid, p_company_id uuid, p_at timestamp with time zone DEFAULT now()) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_profile jsonb; v_env jsonb; v_gap jsonb; v_opp public.opportunities%ROWTYPE;
  v_r4 public.commercial_reality_r4_records%ROWTYPE; v_a4 public.authority_records%ROWTYPE;
  v_r5 public.route_authority_r5_records%ROWTYPE; v_a5 public.authority_records%ROWTYPE;
  v_r6 public.contact_authority_r6_records%ROWTYPE; v_a6 public.authority_records%ROWTYPE;
  v_truth public.truth_entity_snapshots%ROWTYPE;
  v_workflow_events jsonb:='[]'::jsonb; v_reviews jsonb:='[]'::jsonb; v_sync_events jsonb:='[]'::jsonb;
  v_engagement jsonb:=NULL;
BEGIN
  PERFORM public.marketroute_require_service_role();
  PERFORM public.marketroute_application_require_current_read_time_v1(p_at);
  v_profile:=public.marketroute_opportunity_profile_v1(p_organisation_id,p_campaign_id,p_company_id,p_at);
  v_env:=v_profile->'authorityEnvelope';
  v_gap:=public.marketroute_research_gap_context_v1(p_organisation_id,p_campaign_id,p_company_id,p_at);
  SELECT * INTO v_opp FROM public.opportunities WHERE organisation_id=p_organisation_id AND campaign_id=p_campaign_id AND company_id=p_company_id LIMIT 1;

  IF NULLIF(v_env->'r4'->>'authorityRecordId','') IS NOT NULL THEN
    SELECT * INTO v_a4 FROM public.authority_records WHERE id=(v_env->'r4'->>'authorityRecordId')::uuid;
    SELECT * INTO v_r4 FROM public.commercial_reality_r4_records WHERE authority_record_id=v_a4.id;
    IF v_r4.id IS NOT NULL THEN SELECT * INTO v_truth FROM public.truth_entity_snapshots WHERE id=v_r4.target_truth_entity_snapshot_id; END IF;
  END IF;
  IF NULLIF(v_env->'r5'->>'authorityRecordId','') IS NOT NULL THEN
    SELECT * INTO v_a5 FROM public.authority_records WHERE id=(v_env->'r5'->>'authorityRecordId')::uuid;
    SELECT * INTO v_r5 FROM public.route_authority_r5_records WHERE authority_record_id=v_a5.id;
  END IF;
  IF NULLIF(v_env->'r6'->>'authorityRecordId','') IS NOT NULL THEN
    SELECT * INTO v_a6 FROM public.authority_records WHERE id=(v_env->'r6'->>'authorityRecordId')::uuid;
    SELECT * INTO v_r6 FROM public.contact_authority_r6_records WHERE authority_record_id=v_a6.id;
  END IF;

  IF v_opp.id IS NOT NULL THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'eventId',e.id,'eventType',e.event_type,'priorWorkflowState',e.prior_workflow_state,'resultingWorkflowState',e.resulting_workflow_state,
      'actorUserId',e.actor_user_id,'reasonCode',e.reason_code,'authorityEnvelopeFingerprint',e.authority_envelope_fingerprint,'occurredAt',e.occurred_at
    ) ORDER BY e.occurred_at DESC,e.id DESC),'[]'::jsonb) INTO v_workflow_events
    FROM (SELECT * FROM public.opportunity_workflow_events WHERE opportunity_id=v_opp.id ORDER BY occurred_at DESC,id DESC LIMIT 50) e;
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'reviewId',r.id,'decision',r.decision,'note',r.note,'reviewerUserId',r.reviewer_user_id,'priorWorkflowState',r.prior_workflow_state,
      'resultingWorkflowState',r.resulting_workflow_state,'authorityEnvelopeFingerprint',r.authority_envelope_fingerprint,'createdAt',r.created_at
    ) ORDER BY r.created_at DESC,r.id DESC),'[]'::jsonb) INTO v_reviews
    FROM (SELECT * FROM public.opportunity_human_reviews WHERE opportunity_id=v_opp.id ORDER BY created_at DESC,id DESC LIMIT 25) r;
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'syncEventId',s.id,'outcomeCode',s.outcome_code,'priorWorkflowState',s.prior_workflow_state,'resultingWorkflowState',s.resulting_workflow_state,
      'authorityEnvelopeFingerprint',s.authority_envelope_fingerprint,'occurredAt',s.occurred_at
    ) ORDER BY s.occurred_at DESC,s.id DESC),'[]'::jsonb) INTO v_sync_events
    FROM (SELECT * FROM public.opportunity_sync_events WHERE opportunity_id=v_opp.id ORDER BY occurred_at DESC,id DESC LIMIT 25) s;
    v_engagement:=public.marketroute_application_engagement_read_v1(v_opp.id,p_at);
  END IF;

  RETURN jsonb_build_object(
    'contractVersion','MRV2-APPLICATION-READ-1.0.0','resourceType','COMPANY_INTELLIGENCE','evaluatedAt',to_jsonb(p_at),
    'profile',v_profile - 'authorityEnvelope',
    'authority',jsonb_build_object(
      'envelope',v_env,'envelopeFingerprint',public.marketroute_authority_envelope_fingerprint_v1(v_env),
      'r4',CASE WHEN v_r4.id IS NULL THEN NULL ELSE jsonb_build_object(
        'recordId',v_r4.id,'authorityRecordId',v_r4.authority_record_id,'decision',v_r4.decision_code,'realityClass',v_r4.reality_class,
        'constitutionKey',v_r4.boundary_constitution_key,'constitutionVersion',v_r4.boundary_constitution_version,
        'boundaries',v_r4.boundaries_json,'inputFingerprint',v_r4.input_fingerprint,'authorityFingerprint',v_r4.authority_fingerprint,
        'referenceTime',v_r4.reference_time,'nextRevalidationAt',v_r4.next_revalidation_at,'validUntil',v_a4.valid_until
      ) END,
      'r5',CASE WHEN v_r5.id IS NULL THEN NULL ELSE jsonb_build_object(
        'recordId',v_r5.id,'authorityRecordId',v_r5.authority_record_id,'parentR4AuthorityRecordId',v_r5.parent_r4_authority_record_id,
        'decision',v_r5.decision_code,'paths',v_r5.paths_json,'openAccessPointIds',v_r5.open_access_point_ids,
        'contactTruthRequiredAccessPointIds',v_r5.contact_truth_required_access_point_ids,'distinctAccessPointCount',v_r5.distinct_access_point_count,
        'relationshipUniverseFingerprint',v_r5.relationship_universe_fingerprint,'inputFingerprint',v_r5.input_fingerprint,'authorityFingerprint',v_r5.authority_fingerprint,
        'referenceTime',v_r5.reference_time,'nextRevalidationAt',v_r5.next_revalidation_at,'validUntil',v_a5.valid_until
      ) END,
      'r6',CASE WHEN v_r6.id IS NULL THEN NULL ELSE jsonb_build_object(
        'recordId',v_r6.id,'authorityRecordId',v_r6.authority_record_id,'parentR5AuthorityRecordId',v_r6.parent_r5_authority_record_id,
        'decision',v_r6.decision_code,'bindings',v_r6.bindings_json,'authorisedPathFingerprints',v_r6.authorised_path_fingerprints,
        'authorisedAccessPointIds',v_r6.authorised_access_point_ids,'researchRequiredAccessPointIds',v_r6.research_required_access_point_ids,
        'distinctAuthorisedAccessPointCount',v_r6.distinct_authorised_access_point_count,'contactClaimUniverseFingerprint',v_r6.contact_claim_universe_fingerprint,
        'inputFingerprint',v_r6.input_fingerprint,'authorityFingerprint',v_r6.authority_fingerprint,
        'referenceTime',v_r6.reference_time,'nextRevalidationAt',v_r6.next_revalidation_at,'validUntil',v_a6.valid_until
      ) END
    ),
    'truth',CASE WHEN v_truth.id IS NULL THEN NULL ELSE jsonb_build_object(
      'snapshotId',v_truth.id,'snapshotFingerprint',v_truth.snapshot_fingerprint,'profileKey',v_truth.profile_key,'profileVersion',v_truth.profile_version,
      'entityState',v_truth.entity_state,'requiredClaimCount',v_truth.required_claim_count,'knownClaimCount',v_truth.known_claim_count,
      'supportedClaimCount',v_truth.supported_claim_count,'contradictedClaimCount',v_truth.contradicted_claim_count,'staleClaimCount',v_truth.stale_claim_count,
      'unresolvedClaimCount',v_truth.unresolved_claim_count,'coverage',v_truth.coverage,'currentCoverage',v_truth.current_coverage,
      'evidenceSufficiency',v_truth.evidence_sufficiency,'freshnessCoverage',v_truth.freshness_coverage,'coherence',v_truth.coherence,
      'truthIndex',v_truth.truth_index,'probabilityState',v_truth.probability_state,'referenceTime',v_truth.reference_time,'nextRevalidationAt',v_truth.next_revalidation_at
    ) END,
    'research',jsonb_build_object(
      'lifecycleState',v_gap->>'lifecycleState','gapSetFingerprint',v_gap->>'gapSetFingerprint','candidates',COALESCE(v_gap->'candidates','[]'::jsonb),
      'policy',COALESCE(v_gap->'policy','{}'::jsonb),'budget',COALESCE(v_gap->'budget','{}'::jsonb)
    ),
    'workflow',jsonb_build_object('opportunityId',v_opp.id,'state',v_opp.workflow_state,'events',v_workflow_events,'humanReviews',v_reviews,'syncEvents',v_sync_events),
    'engagement',v_engagement,
    'actions',jsonb_build_object(
      'canReview',COALESCE((v_profile->>'reviewableNow')::boolean,false),
      'canGenerateEngagement',COALESCE((v_profile->>'executableNow')::boolean,false),
      'canExecute',COALESCE((v_profile->>'executableNow')::boolean,false),
      'requiresResearch',COALESCE(v_profile->>'disposition','') IN ('RESEARCH_REQUIRED','REVALIDATION_REQUIRED')
    )
  );
END $$;

--
-- Name: marketroute_application_engagement_index_read_v1(uuid, uuid, integer, integer, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_application_engagement_index_read_v1(p_organisation_id uuid, p_campaign_id uuid, p_limit integer DEFAULT 100, p_offset integer DEFAULT 0, p_at timestamp with time zone DEFAULT now()) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_limit integer:=greatest(1,least(COALESCE(p_limit,100),250));
  v_offset integer:=greatest(0,COALESCE(p_offset,0));
  v_total integer:=0;
  v_rows jsonb:='[]'::jsonb;
  v_policy text;
BEGIN
  PERFORM public.marketroute_require_service_role();
  PERFORM public.marketroute_application_require_current_read_time_v1(p_at);
  IF NOT EXISTS(SELECT 1 FROM public.campaigns c WHERE c.id=p_campaign_id AND c.organisation_id=p_organisation_id) THEN
    RAISE EXCEPTION 'MARKETROUTE_APPLICATION_ENGAGEMENT_INDEX_CAMPAIGN_NOT_FOUND';
  END IF;
  v_policy:=public.marketroute_current_engagement_policy_v1(p_organisation_id,p_campaign_id);
  SELECT count(*)::int INTO v_total FROM public.opportunities o WHERE o.organisation_id=p_organisation_id AND o.campaign_id=p_campaign_id;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'opportunityId',q.opportunity_id,'companyId',q.company_id,'companyName',q.company_name,'canonicalDomain',q.canonical_domain,
    'workflowState',q.workflow_state,'engagement',q.engagement
  ) ORDER BY q.company_name,q.opportunity_id),'[]'::jsonb) INTO v_rows
  FROM (
    SELECT o.id opportunity_id,o.company_id,c.canonical_name company_name,c.canonical_domain,o.workflow_state,
      public.marketroute_application_engagement_read_v1(o.id,p_at) engagement
    FROM public.opportunities o
    JOIN public.companies c ON c.id=o.company_id
    WHERE o.organisation_id=p_organisation_id AND o.campaign_id=p_campaign_id
    ORDER BY c.canonical_name,o.id
    LIMIT v_limit OFFSET v_offset
  ) q;

  RETURN jsonb_build_object(
    'contractVersion','MRV2-APPLICATION-READ-1.0.0','resourceType','ENGAGEMENT_INDEX','evaluatedAt',to_jsonb(p_at),
    'organisationId',p_organisation_id,'campaignId',p_campaign_id,'policyMode',COALESCE(v_policy,'HUMAN_ONLY'),
    'totalCount',v_total,'offset',v_offset,'limit',v_limit,'returnedCount',jsonb_array_length(v_rows),'items',v_rows
  );
END $$;

--
-- Name: marketroute_application_engagement_read_v1(uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_application_engagement_read_v1(p_opportunity_id uuid, p_at timestamp with time zone DEFAULT now()) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_opp public.opportunities%ROWTYPE;
  v_policy text;
  v_strategy public.engagement_strategies%ROWTYPE;
  v_message public.engagement_messages%ROWTYPE;
  v_review public.engagement_ai_reviews%ROWTYPE;
  v_approval public.engagement_message_approvals%ROWTYPE;
  v_queue public.engagement_queue_items%ROWTYPE;
  v_job public.engagement_delivery_jobs%ROWTYPE;
  v_last_delivery public.engagement_delivery_events%ROWTYPE;
  v_manual public.engagement_manual_actions%ROWTYPE;
  v_strategy_current boolean:=false;
  v_executable boolean:=false;
BEGIN
  PERFORM public.marketroute_require_service_role();
  PERFORM public.marketroute_application_require_current_read_time_v1(p_at);
  SELECT * INTO v_opp FROM public.opportunities WHERE id=p_opportunity_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_APPLICATION_ENGAGEMENT_OPPORTUNITY_NOT_FOUND'; END IF;
  v_policy:=public.marketroute_current_engagement_policy_v1(v_opp.organisation_id,v_opp.campaign_id);
  v_executable:=public.marketroute_opportunity_executable_now_v1(v_opp.id,p_at);

  SELECT * INTO v_strategy FROM public.engagement_strategies WHERE opportunity_id=v_opp.id ORDER BY created_at DESC,id DESC LIMIT 1;
  IF v_strategy.id IS NOT NULL THEN
    v_strategy_current:=public.marketroute_engagement_strategy_current_v1(v_strategy.id,p_at);
    SELECT * INTO v_message FROM public.engagement_messages WHERE strategy_id=v_strategy.id ORDER BY rewrite_ordinal DESC,created_at DESC,id DESC LIMIT 1;
  END IF;
  IF v_message.id IS NOT NULL THEN
    SELECT * INTO v_review FROM public.engagement_ai_reviews WHERE message_id=v_message.id ORDER BY created_at DESC,id DESC LIMIT 1;
    SELECT * INTO v_approval FROM public.engagement_message_approvals WHERE message_id=v_message.id ORDER BY created_at DESC,id DESC LIMIT 1;
    SELECT * INTO v_queue FROM public.engagement_queue_items WHERE message_id=v_message.id ORDER BY queued_at DESC,id DESC LIMIT 1;
  END IF;
  IF v_queue.id IS NOT NULL THEN
    SELECT * INTO v_job FROM public.engagement_delivery_jobs WHERE queue_item_id=v_queue.id;
    SELECT * INTO v_last_delivery FROM public.engagement_delivery_events WHERE queue_item_id=v_queue.id ORDER BY occurred_at DESC,id DESC LIMIT 1;
  END IF;
  SELECT * INTO v_manual FROM public.engagement_manual_actions WHERE opportunity_id=v_opp.id ORDER BY occurred_at DESC,id DESC LIMIT 1;

  RETURN jsonb_build_object(
    'contractVersion','MRV2-APPLICATION-READ-1.0.0',
    'evaluatedAt',to_jsonb(p_at),
    'policyMode','HUMAN_ONLY',
    'engagementMode','ASSISTED_ONLY',
    'opportunityExecutableNow',v_executable,
    'strategy',CASE WHEN v_strategy.id IS NULL THEN NULL ELSE jsonb_build_object(
      'strategyId',v_strategy.id,'strategyFingerprint',v_strategy.strategy_fingerprint,'strategyVersion',v_strategy.strategy_version,
      'pathFingerprint',v_strategy.path_fingerprint,'channel',v_strategy.channel_kind,'routeMode',v_strategy.route_mode,
      'accessPointId',v_strategy.access_point_id,'accessPointKind',v_strategy.access_point_kind,'accessPointValue',v_strategy.access_point_value,
      'personId',v_strategy.person_id,'authorityEnvelopeFingerprint',v_strategy.authority_envelope_fingerprint,
      'r6AuthorityRecordId',v_strategy.r6_authority_record_id,'r6AuthorityFingerprint',v_strategy.r6_authority_fingerprint,
      'current',v_strategy_current,'createdAt',v_strategy.created_at
    ) END,
    'message',CASE WHEN v_message.id IS NULL THEN NULL ELSE jsonb_build_object(
      'messageId',v_message.id,'rewriteOrdinal',v_message.rewrite_ordinal,'generationContractVersion',v_message.generation_contract_version,
      'generatorVersion',v_message.generator_version,'subjectText',v_message.subject_text,'bodyText',v_message.body_text,
      'messageFingerprint',v_message.message_fingerprint,'createdAt',v_message.created_at
    ) END,
    'aiReview',CASE WHEN v_review.id IS NULL THEN NULL ELSE jsonb_build_object(
      'reviewId',v_review.id,'reviewContractVersion',v_review.review_contract_version,'reviewerVersion',v_review.reviewer_version,
      'verdict',v_review.verdict,'reasonCodes',to_jsonb(v_review.reason_codes),'diagnostics',v_review.diagnostics_json,
      'reviewFingerprint',v_review.review_fingerprint,'createdAt',v_review.created_at
    ) END,
    'approval',CASE WHEN v_approval.id IS NULL THEN NULL ELSE jsonb_build_object(
      'approvalId',v_approval.id,'mode',v_approval.approval_mode,'decision',v_approval.decision,'actorUserId',v_approval.actor_user_id,
      'authorityEnvelopeFingerprint',v_approval.authority_envelope_fingerprint,'createdAt',v_approval.created_at
    ) END,
    'manualAction',CASE WHEN v_manual.id IS NULL THEN NULL ELSE jsonb_build_object(
      'manualActionId',v_manual.id,'actorUserId',v_manual.actor_user_id,'channel',v_manual.channel_kind,
      'pathFingerprint',v_manual.path_fingerprint,'messageId',v_manual.message_id,
      'authorityEnvelopeFingerprint',v_manual.authority_envelope_fingerprint,'note',v_manual.note,'occurredAt',v_manual.occurred_at
    ) END,
    'queue',CASE WHEN v_queue.id IS NULL THEN NULL ELSE jsonb_build_object(
      'queueItemId',v_queue.id,'approvalMode',v_queue.approval_mode,'authorityEnvelopeFingerprint',v_queue.authority_envelope_fingerprint,'queuedAt',v_queue.queued_at
    ) END,
    'delivery',CASE WHEN v_job.id IS NULL THEN NULL ELSE jsonb_build_object(
      'jobId',v_job.id,'status',v_job.status,'attemptNumber',v_job.attempt_number,'claimedAt',v_job.claimed_at,
      'sendGateFingerprint',v_job.send_gate_fingerprint,'lastErrorCode',v_job.last_error_code,'finishedAt',v_job.finished_at,
      'lastEvent',CASE WHEN v_last_delivery.id IS NULL THEN NULL ELSE jsonb_build_object(
        'eventType',v_last_delivery.event_type,'providerMessageId',v_last_delivery.provider_message_id,
        'sendGateFingerprint',v_last_delivery.send_gate_fingerprint,'occurredAt',v_last_delivery.occurred_at
      ) END
    ) END,
    'actions',jsonb_build_object(
      'canGenerateDraft',v_opp.workflow_state IN('REVIEWABLE','APPROVED') AND v_executable,
      'canApproveMessage',v_message.id IS NOT NULL AND COALESCE(v_review.verdict,'')='PASS' AND v_executable AND v_strategy_current,
      'canQueue',false,
      'canMarkContacted',v_manual.id IS NULL AND v_message.id IS NOT NULL AND COALESCE(v_review.verdict,'')='PASS'
        AND COALESCE(v_approval.decision,'')='APPROVE' AND COALESCE(v_approval.approval_mode,'')='HUMAN'
        AND v_executable AND v_strategy_current,
      'deliveryNeedsReconciliation',COALESCE(v_job.status,'')='RECONCILIATION_REQUIRED'
    )
  );
END $$;

--
-- Name: marketroute_application_materialised_profile_index_v1(uuid, uuid, boolean, integer, integer, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_application_materialised_profile_index_v1(p_organisation_id uuid, p_campaign_id uuid, p_opportunities_only boolean DEFAULT false, p_limit integer DEFAULT 100, p_offset integer DEFAULT 0, p_at timestamp with time zone DEFAULT now()) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
WITH
seller_ctx AS (
  SELECT s.id
  FROM public.campaign_seller_context_selections s
  WHERE s.organisation_id = p_organisation_id
    AND s.campaign_id = p_campaign_id
  ORDER BY s.created_at DESC, s.id DESC
  LIMIT 1
),
base AS MATERIALIZED (
  SELECT
    s.organisation_id,
    s.campaign_id,
    s.company_id,
    c.canonical_name,
    c.canonical_domain,
    o.id AS opportunity_id,
    o.workflow_state
  FROM public.organisation_company_scopes s
  JOIN public.companies c ON c.id = s.company_id
  LEFT JOIN public.opportunities o
    ON o.organisation_id = s.organisation_id
   AND o.campaign_id = s.campaign_id
   AND o.company_id = s.company_id
  WHERE s.organisation_id = p_organisation_id
    AND s.campaign_id = p_campaign_id
    AND s.scope_kind = 'CAMPAIGN'
    AND (NOT COALESCE(p_opportunities_only, false) OR o.id IS NOT NULL)
  ORDER BY c.canonical_name, c.id
  LIMIT greatest(1, least(COALESCE(p_limit,100),250))
  OFFSET greatest(0, COALESCE(p_offset,0))
),
joined AS MATERIALIZED (
  SELECT
    b.*,
    r4.id AS r4_id,
    r4.authority_record_id AS r4_authority_record_id,
    r4.seller_context_selection_id,
    r4.target_truth_entity_snapshot_id,
    r4.decision_code AS r4_decision,
    r4.authority_fingerprint AS r4_fingerprint,
    r4.next_revalidation_at AS r4_next_revalidation_at,
    a4.valid_from AS a4_valid_from,
    a4.valid_until AS a4_valid_until,
    a4.payload_json AS a4_payload,
    t.entity_state AS truth_entity_state,
    t.current_coverage AS truth_current_coverage,
    t.evidence_sufficiency AS truth_evidence_sufficiency,
    t.freshness_coverage AS truth_freshness_coverage,
    t.coherence AS truth_coherence,
    t.truth_index AS truth_index,
    t.probability_state AS truth_probability_state,
    t.snapshot_fingerprint AS truth_snapshot_fingerprint,
    r5.id AS r5_id,
    r5.authority_record_id AS r5_authority_record_id,
    r5.parent_r4_authority_record_id,
    r5.parent_r4_authority_fingerprint,
    r5.decision_code AS r5_decision,
    r5.distinct_access_point_count AS structural_routes,
    r5.authority_fingerprint AS r5_fingerprint,
    r5.next_revalidation_at AS r5_next_revalidation_at,
    a5.valid_from AS a5_valid_from,
    a5.valid_until AS a5_valid_until,
    r6.id AS r6_id,
    r6.authority_record_id AS r6_authority_record_id,
    r6.parent_r5_authority_record_id,
    r6.parent_r5_authority_fingerprint,
    r6.decision_code AS r6_decision,
    r6.distinct_authorised_access_point_count AS authorised_routes,
    r6.authority_fingerprint AS r6_fingerprint,
    r6.next_revalidation_at AS r6_next_revalidation_at,
    a6.valid_from AS a6_valid_from,
    a6.valid_until AS a6_valid_until,
    sc.id AS current_seller_context_id,
    sync_event.authority_envelope_json AS sync_envelope,
    sync_event.occurred_at AS sync_occurred_at
  FROM base b
  LEFT JOIN seller_ctx sc ON true
  LEFT JOIN LATERAL (
    SELECT r.*
    FROM public.commercial_reality_r4_records r
    WHERE r.organisation_id = b.organisation_id
      AND r.campaign_id = b.campaign_id
      AND r.company_id = b.company_id
    ORDER BY r.created_at DESC, r.id DESC
    LIMIT 1
  ) r4 ON true
  LEFT JOIN public.authority_records a4 ON a4.id = r4.authority_record_id
  LEFT JOIN public.truth_entity_snapshots t ON t.id = r4.target_truth_entity_snapshot_id
  LEFT JOIN LATERAL (
    SELECT r.*
    FROM public.route_authority_r5_records r
    WHERE r.organisation_id = b.organisation_id
      AND r.campaign_id = b.campaign_id
      AND r.company_id = b.company_id
    ORDER BY r.created_at DESC, r.id DESC
    LIMIT 1
  ) r5 ON true
  LEFT JOIN public.authority_records a5 ON a5.id = r5.authority_record_id
  LEFT JOIN LATERAL (
    SELECT r.*
    FROM public.contact_authority_r6_records r
    WHERE r.organisation_id = b.organisation_id
      AND r.campaign_id = b.campaign_id
      AND r.company_id = b.company_id
    ORDER BY r.created_at DESC, r.id DESC
    LIMIT 1
  ) r6 ON true
  LEFT JOIN public.authority_records a6 ON a6.id = r6.authority_record_id
  LEFT JOIN LATERAL (
    SELECT e.authority_envelope_json, e.occurred_at
    FROM public.opportunity_sync_events e
    WHERE e.organisation_id = b.organisation_id
      AND e.campaign_id = b.campaign_id
      AND e.company_id = b.company_id
    ORDER BY e.occurred_at DESC, e.id DESC
    LIMIT 1
  ) sync_event ON true
),
flags_r4 AS MATERIALIZED (
  SELECT j.*,
    (
      j.r4_id IS NOT NULL
      AND j.a4_valid_from <= p_at
      AND p_at < j.a4_valid_until
      AND j.r4_next_revalidation_at > p_at
      AND j.current_seller_context_id IS NOT NULL
      AND j.seller_context_selection_id = j.current_seller_context_id
      AND j.truth_snapshot_fingerprint = j.a4_payload->>'targetTruthEntitySnapshotFingerprint'
      AND NOT EXISTS (
        SELECT 1 FROM public.authority_events e
        WHERE e.authority_record_id = j.r4_authority_record_id
          AND e.event_type IN ('SUPERSEDED','INVALIDATED','REVOKED')
          AND e.occurred_at <= p_at
      )
    ) AS r4_projection_current
  FROM joined j
),
flags_r5 AS MATERIALIZED (
  SELECT f.*,
    (
      f.r4_projection_current
      AND f.r5_id IS NOT NULL
      AND f.a5_valid_from <= p_at
      AND p_at < f.a5_valid_until
      AND f.r5_next_revalidation_at > p_at
      AND f.parent_r4_authority_record_id = f.r4_authority_record_id
      AND f.parent_r4_authority_fingerprint = f.r4_fingerprint
      AND NOT EXISTS (
        SELECT 1 FROM public.authority_events e
        WHERE e.authority_record_id = f.r5_authority_record_id
          AND e.event_type IN ('SUPERSEDED','INVALIDATED','REVOKED')
          AND e.occurred_at <= p_at
      )
    ) AS r5_projection_current
  FROM flags_r4 f
),
flags_r6 AS MATERIALIZED (
  SELECT f.*,
    (
      f.r5_projection_current
      AND f.r6_id IS NOT NULL
      AND f.a6_valid_from <= p_at
      AND p_at < f.a6_valid_until
      AND f.r6_next_revalidation_at > p_at
      AND f.parent_r5_authority_record_id = f.r5_authority_record_id
      AND f.parent_r5_authority_fingerprint = f.r5_fingerprint
      AND NOT EXISTS (
        SELECT 1 FROM public.authority_events e
        WHERE e.authority_record_id = f.r6_authority_record_id
          AND e.event_type IN ('SUPERSEDED','INVALIDATED','REVOKED')
          AND e.occurred_at <= p_at
      )
    ) AS r6_projection_current
  FROM flags_r5 f
),
states AS MATERIALIZED (
  SELECT f.*,
    CASE
      WHEN NOT f.r4_projection_current THEN 'R4_REVALIDATION_REQUIRED'
      WHEN f.r4_decision = 'NOT_ADMISSIBLE' THEN 'NOT_ADMISSIBLE'
      WHEN f.r4_decision = 'RESEARCH_REQUIRED' THEN 'COMMERCIAL_RESEARCH_REQUIRED'
      WHEN NOT f.r5_projection_current THEN 'R5_REVALIDATION_REQUIRED'
      WHEN f.r5_decision = 'ROUTE_NOT_APPLICABLE' THEN 'ROUTE_NOT_APPLICABLE'
      WHEN f.r5_decision = 'ROUTE_RESEARCH_REQUIRED' THEN 'ROUTE_RESEARCH_REQUIRED'
      WHEN NOT f.r6_projection_current THEN 'R6_REVALIDATION_REQUIRED'
      WHEN f.r6_decision = 'CONTACT_NOT_APPLICABLE' THEN 'CONTACT_NOT_APPLICABLE'
      WHEN f.r6_decision = 'CONTACT_RESEARCH_REQUIRED' THEN 'CONTACT_RESEARCH_REQUIRED'
      WHEN f.r6_decision = 'CONTACT_AUTHORISED' THEN 'AUTHORITY_READY'
      ELSE 'R6_REVALIDATION_REQUIRED'
    END AS lifecycle_state,
    (
      f.sync_envelope IS NOT NULL
      AND COALESCE((f.sync_envelope->>'authorityReady')::boolean, false)
      AND NULLIF(f.sync_envelope->'r4'->>'authorityRecordId','')::uuid = f.r4_authority_record_id
      AND NULLIF(f.sync_envelope->'r5'->>'authorityRecordId','')::uuid = f.r5_authority_record_id
      AND NULLIF(f.sync_envelope->'r6'->>'authorityRecordId','')::uuid = f.r6_authority_record_id
      AND f.r6_projection_current
      AND NULLIF(f.sync_envelope->>'nextRevalidationAt','')::timestamptz > p_at
    ) AS sync_snapshot_ready
  FROM flags_r6 f
),
profiles AS (
  SELECT
    s.canonical_name,
    s.company_id,
    jsonb_build_object(
      'engineVersion','MRV2-APPLICATION-MATERIALISED-LIST-1.0.0',
      'semanticsVersion','MRV2-APPLICATION-MATERIALISED-LIST-1.0.0',
      'projectionKind','MATERIALISED_LIST_SUMMARY',
      'organisationId',s.organisation_id::text,
      'campaignId',s.campaign_id::text,
      'companyId',s.company_id::text,
      'opportunityId',s.opportunity_id,
      'companyName',s.canonical_name,
      'canonicalDomain',s.canonical_domain,
      'evaluatedAt',to_jsonb(p_at),
      'workflowState',s.workflow_state,
      'lifecycleState',s.lifecycle_state,
      'disposition',public.marketroute_opportunity_disposition_v1(s.lifecycle_state),
      'researchPressure',public.marketroute_opportunity_research_pressure_v1(s.lifecycle_state),
      'authorityReady',s.lifecycle_state = 'AUTHORITY_READY',
      'reviewableNow',COALESCE(s.workflow_state = 'REVIEWABLE' AND s.sync_snapshot_ready, false),
      'executableNow',COALESCE(s.workflow_state IN ('REVIEWABLE','APPROVED') AND s.sync_snapshot_ready, false),
      'reasonCode',CASE s.lifecycle_state
        WHEN 'R4_REVALIDATION_REQUIRED' THEN 'CURRENT_R4_REQUIRED'
        WHEN 'NOT_ADMISSIBLE' THEN 'R4_NOT_ADMISSIBLE'
        WHEN 'COMMERCIAL_RESEARCH_REQUIRED' THEN 'R4_RESEARCH_REQUIRED'
        WHEN 'R5_REVALIDATION_REQUIRED' THEN 'CURRENT_R5_REQUIRED'
        WHEN 'ROUTE_NOT_APPLICABLE' THEN 'R5_ROUTE_NOT_APPLICABLE'
        WHEN 'ROUTE_RESEARCH_REQUIRED' THEN 'R5_RESEARCH_REQUIRED'
        WHEN 'R6_REVALIDATION_REQUIRED' THEN 'CURRENT_R6_REQUIRED'
        WHEN 'CONTACT_NOT_APPLICABLE' THEN 'R6_CONTACT_NOT_APPLICABLE'
        WHEN 'CONTACT_RESEARCH_REQUIRED' THEN 'R6_RESEARCH_REQUIRED'
        ELSE 'R4_R5_R6_CURRENT_AND_AUTHORISED'
      END,
      'nextRevalidationAt',CASE
        WHEN s.lifecycle_state IN ('R4_REVALIDATION_REQUIRED','NOT_ADMISSIBLE','COMMERCIAL_RESEARCH_REQUIRED') THEN s.a4_valid_until
        WHEN s.lifecycle_state IN ('R5_REVALIDATION_REQUIRED','ROUTE_NOT_APPLICABLE','ROUTE_RESEARCH_REQUIRED') THEN LEAST(s.a4_valid_until,s.a5_valid_until)
        ELSE LEAST(s.a4_valid_until,s.a5_valid_until,s.a6_valid_until)
      END,
      'commercialReality',CASE WHEN s.r4_projection_current THEN s.r4_decision ELSE 'NO_CURRENT_R4' END,
      'routeAuthority',CASE WHEN s.r5_projection_current THEN s.r5_decision ELSE 'NO_CURRENT_R5' END,
      'contactAuthority',CASE WHEN s.r6_projection_current THEN s.r6_decision ELSE 'NO_CURRENT_R6' END,
      'truth',jsonb_build_object(
        'entityState',CASE WHEN s.r4_projection_current THEN s.truth_entity_state ELSE NULL END,
        'currentCoverage',CASE WHEN s.r4_projection_current THEN s.truth_current_coverage ELSE NULL END,
        'evidenceSufficiency',CASE WHEN s.r4_projection_current THEN s.truth_evidence_sufficiency ELSE NULL END,
        'freshnessCoverage',CASE WHEN s.r4_projection_current THEN s.truth_freshness_coverage ELSE NULL END,
        'coherence',CASE WHEN s.r4_projection_current THEN s.truth_coherence ELSE NULL END,
        'truthIndex',CASE WHEN s.r4_projection_current THEN s.truth_index ELSE NULL END,
        'probabilityState',CASE WHEN s.r4_projection_current THEN s.truth_probability_state ELSE NULL END
      ),
      'structurallyOpenAccessPointCount',CASE WHEN s.r5_projection_current THEN COALESCE(s.structural_routes,0) ELSE 0 END,
      'authorisedAccessPointCount',CASE WHEN s.r6_projection_current THEN COALESCE(s.authorised_routes,0) ELSE 0 END,
      'routeRedundancy',CASE
        WHEN NOT s.r6_projection_current OR COALESCE(s.authorised_routes,0)=0 THEN 'NONE'
        WHEN s.authorised_routes=1 THEN 'SINGLE'
        ELSE 'MULTIPLE'
      END,
      'materialisedSyncAt',s.sync_occurred_at,
      'materialisedSyncCurrent',s.sync_snapshot_ready
    ) AS profile
  FROM states s
)
SELECT COALESCE(jsonb_agg(p.profile ORDER BY p.canonical_name,p.company_id),'[]'::jsonb)
FROM profiles p;
$$;

--
-- Name: marketroute_application_opportunity_index_read_v1(uuid, uuid, integer, integer, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_application_opportunity_index_read_v1(p_organisation_id uuid, p_campaign_id uuid, p_limit integer DEFAULT 100, p_offset integer DEFAULT 0, p_at timestamp with time zone DEFAULT now()) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_limit integer := greatest(1,least(COALESCE(p_limit,100),250));
  v_offset integer := greatest(0,COALESCE(p_offset,0));
  v_total integer := 0;
  v_rows jsonb := '[]'::jsonb;
BEGIN
  PERFORM public.marketroute_require_service_role();
  PERFORM public.marketroute_application_require_current_read_time_v1(p_at);
  IF NOT EXISTS(SELECT 1 FROM public.campaigns c WHERE c.id=p_campaign_id AND c.organisation_id=p_organisation_id) THEN
    RAISE EXCEPTION 'MARKETROUTE_APPLICATION_OPPORTUNITY_INDEX_CAMPAIGN_NOT_FOUND';
  END IF;

  SELECT count(*)::integer INTO v_total
  FROM public.opportunities o
  WHERE o.organisation_id=p_organisation_id AND o.campaign_id=p_campaign_id;

  v_rows := public.marketroute_application_materialised_profile_index_v1(
    p_organisation_id,p_campaign_id,true,v_limit,v_offset,p_at
  );

  RETURN jsonb_build_object(
    'contractVersion','MRV2-APPLICATION-READ-1.0.0',
    'resourceType','OPPORTUNITY_INDEX',
    'evaluatedAt',to_jsonb(p_at),
    'projectionKind','MATERIALISED_LIST_SUMMARY',
    'organisationId',p_organisation_id,
    'campaignId',p_campaign_id,
    'totalCount',v_total,
    'offset',v_offset,
    'limit',v_limit,
    'returnedCount',jsonb_array_length(v_rows),
    'opportunities',v_rows
  );
END;
$$;

--
-- Name: marketroute_application_provenance_claim_index_v1(uuid, uuid, uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_application_provenance_claim_index_v1(p_organisation_id uuid, p_campaign_id uuid, p_company_id uuid, p_at timestamp with time zone DEFAULT now()) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_env jsonb;
  v_r4 public.commercial_reality_r4_records%ROWTYPE;
  v_r5 public.route_authority_r5_records%ROWTYPE;
  v_r6 public.contact_authority_r6_records%ROWTYPE;
  v_entity public.truth_entity_snapshots%ROWTYPE;
  v_claims jsonb:='[]'::jsonb;
BEGIN
  PERFORM public.marketroute_require_service_role();
  PERFORM public.marketroute_application_require_current_read_time_v1(p_at);
  v_env:=public.marketroute_authority_envelope_v1(p_organisation_id,p_campaign_id,p_company_id,p_at);
  IF NULLIF(v_env->'r4'->>'authorityRecordId','') IS NOT NULL THEN
    SELECT * INTO v_r4 FROM public.commercial_reality_r4_records WHERE authority_record_id=(v_env->'r4'->>'authorityRecordId')::uuid;
    IF v_r4.id IS NOT NULL THEN SELECT * INTO v_entity FROM public.truth_entity_snapshots WHERE id=v_r4.target_truth_entity_snapshot_id; END IF;
  END IF;
  IF NULLIF(v_env->'r5'->>'authorityRecordId','') IS NOT NULL THEN
    SELECT * INTO v_r5 FROM public.route_authority_r5_records WHERE authority_record_id=(v_env->'r5'->>'authorityRecordId')::uuid;
  END IF;
  IF NULLIF(v_env->'r6'->>'authorityRecordId','') IS NOT NULL THEN
    SELECT * INTO v_r6 FROM public.contact_authority_r6_records WHERE authority_record_id=(v_env->'r6'->>'authorityRecordId')::uuid;
  END IF;

  WITH snapshot_refs AS (
    SELECT 'R4_CORE'::text layer,sid.value::uuid snapshot_id
    FROM jsonb_each(COALESCE(v_entity.claim_snapshot_map,'{}'::jsonb)) kv
    CROSS JOIN LATERAL jsonb_array_elements_text(kv.value) sid(value)
    UNION ALL
    SELECT 'R4_CONSTRAINT',sid.value::uuid
    FROM jsonb_each(COALESCE(v_r4.constraint_truth_snapshot_map,'{}'::jsonb)) kv
    CROSS JOIN LATERAL jsonb_array_elements_text(kv.value) sid(value)
    UNION ALL
    SELECT 'R5_RELATIONSHIP',kv.value::uuid
    FROM jsonb_each_text(COALESCE(v_r5.relationship_truth_snapshot_map,'{}'::jsonb)) kv
    UNION ALL
    SELECT 'R6_CONTACT',kv.value::uuid
    FROM jsonb_each_text(COALESCE(v_r6.contact_truth_snapshot_map,'{}'::jsonb)) kv
  ), grouped AS (
    SELECT snapshot_id,jsonb_agg(DISTINCT layer ORDER BY layer) layers FROM snapshot_refs GROUP BY snapshot_id
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'snapshotId',s.id,'claimId',s.claim_id,'claimKey',s.claim_key,'truthState',s.truth_state,
    'evidenceSufficiency',s.evidence_sufficiency,'freshnessCoverage',s.freshness_coverage,'probabilityState',s.probability_state,
    'referenceTime',s.reference_time,'nextRevalidationAt',s.next_revalidation_at,'snapshotFingerprint',s.snapshot_fingerprint,
    'propositionFingerprint',s.proposition_fingerprint,'predicate',c.predicate,'canonicalValue',c.canonical_value_text,
    'subjectType',c.subject_type,'subjectId',c.subject_id,'layers',g.layers
  ) ORDER BY s.claim_key,s.id),'[]'::jsonb) INTO v_claims
  FROM grouped g JOIN public.truth_claim_snapshots s ON s.id=g.snapshot_id JOIN public.claims c ON c.id=s.claim_id;

  RETURN jsonb_build_object(
    'contractVersion','MRV2-APPLICATION-READ-1.0.0','resourceType','PROVENANCE_CLAIM_INDEX','evaluatedAt',to_jsonb(p_at),
    'organisationId',p_organisation_id,'campaignId',p_campaign_id,'companyId',p_company_id,'claims',v_claims
  );
END $$;

--
-- Name: marketroute_application_require_current_read_time_v1(timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_application_require_current_read_time_v1(p_at timestamp with time zone) RETURNS void
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
  IF p_at IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_APPLICATION_READ_TIME_REQUIRED'; END IF;
  IF abs(extract(epoch FROM (now()-p_at))) > 300 THEN RAISE EXCEPTION 'MARKETROUTE_APPLICATION_READ_TIME_NOT_CURRENT'; END IF;
END $$;

--
-- Name: marketroute_application_research_activity_read_v1(uuid, uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_application_research_activity_read_v1(p_organisation_id uuid, p_campaign_id uuid, p_at timestamp with time zone DEFAULT now()) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_policy jsonb;
  v_budget jsonb;
  v_plans jsonb:='[]'::jsonb;
  v_work jsonb:='[]'::jsonb;
  v_runs jsonb:='[]'::jsonb;
BEGIN
  PERFORM public.marketroute_require_service_role();
  PERFORM public.marketroute_application_require_current_read_time_v1(p_at);
  IF NOT EXISTS(SELECT 1 FROM public.campaigns c WHERE c.id=p_campaign_id AND c.organisation_id=p_organisation_id) THEN
    RAISE EXCEPTION 'MARKETROUTE_APPLICATION_RESEARCH_CAMPAIGN_NOT_FOUND';
  END IF;
  v_policy:=public.marketroute_research_policy_v1(p_organisation_id,p_campaign_id);
  v_budget:=public.marketroute_research_budget_snapshot_v1(p_organisation_id,p_campaign_id,p_at);

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'planId',p.id,'companyId',p.company_id,'referenceTime',p.reference_time,'lifecycleState',p.lifecycle_state,
    'plannerVersion',p.planner_version,'semanticsVersion',p.semantics_version,'gapSetFingerprint',p.gap_set_fingerprint,
    'planFingerprint',p.plan_fingerprint,'workUnitCount',jsonb_array_length(p.work_units_json),'createdAt',p.created_at
  ) ORDER BY p.created_at DESC,p.id DESC),'[]'::jsonb) INTO v_plans
  FROM (SELECT * FROM public.research_plan_runs WHERE organisation_id=p_organisation_id AND campaign_id=p_campaign_id ORDER BY created_at DESC,id DESC LIMIT 30) p;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'workUnitId',w.id,'planId',w.plan_id,'companyId',w.company_id,'ordinal',w.ordinal,'gapKey',w.gap_key,
    'layer',w.layer,'tier',w.tier,'action',w.action,'subjectType',w.subject_type,'subjectId',w.subject_id,
    'claimKey',w.claim_key,'reasonCode',w.reason_code,'costCeilingUsd',w.cost_ceiling_usd,'createdAt',w.created_at,
    'job',CASE WHEN j.id IS NULL THEN NULL ELSE jsonb_build_object(
      'jobId',j.id,'status',j.status,'priority',j.priority,'attemptCount',j.attempt_count,'maxAttempts',j.max_attempts,
      'availableAt',j.available_at,'lastErrorCode',j.last_error_code,'updatedAt',j.updated_at,
      'latestAttempt',CASE WHEN a.id IS NULL THEN NULL ELSE jsonb_build_object(
        'attemptNumber',a.attempt_number,'status',a.status,'startedAt',a.started_at,'completedAt',a.completed_at,'errorCode',a.error_code
      ) END
    ) END
  ) ORDER BY w.created_at DESC,w.id DESC),'[]'::jsonb) INTO v_work
  FROM (SELECT * FROM public.research_work_units WHERE organisation_id=p_organisation_id AND campaign_id=p_campaign_id ORDER BY created_at DESC,id DESC LIMIT 120) w
  LEFT JOIN public.background_jobs j ON j.id=w.background_job_id
  LEFT JOIN LATERAL (
    SELECT a0.* FROM public.background_job_attempts a0 WHERE a0.job_id=j.id ORDER BY a0.attempt_number DESC LIMIT 1
  ) a ON true;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'runId',r.id,'status',r.status,'startedAt',r.started_at,'completedAt',r.completed_at,'metadata',r.metadata_json
  ) ORDER BY r.started_at DESC,r.id DESC),'[]'::jsonb) INTO v_runs
  FROM (SELECT * FROM public.scheduler_runs WHERE runner_key='GENESIS_RESEARCH_V1' ORDER BY started_at DESC,id DESC LIMIT 20) r;

  RETURN jsonb_build_object(
    'contractVersion','MRV2-APPLICATION-READ-1.0.0','resourceType','RESEARCH_ACTIVITY','evaluatedAt',to_jsonb(p_at),
    'organisationId',p_organisation_id,'campaignId',p_campaign_id,
    'policy',v_policy,'budget',v_budget,'plans',v_plans,'workUnits',v_work,'schedulerRuns',v_runs
  );
END $$;

--
-- Name: marketroute_application_route_display_read_v1(uuid, uuid, uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_application_route_display_read_v1(p_organisation_id uuid, p_campaign_id uuid, p_company_id uuid, p_at timestamp with time zone DEFAULT now()) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_env jsonb;
  v_r5 public.route_authority_r5_records%ROWTYPE;
  v_r6 public.contact_authority_r6_records%ROWTYPE;
  v_company public.companies%ROWTYPE;
  v_paths jsonb:='[]'::jsonb;
BEGIN
  PERFORM public.marketroute_require_service_role();
  PERFORM public.marketroute_application_require_current_read_time_v1(p_at);

  SELECT * INTO v_company FROM public.companies WHERE id=p_company_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_APPLICATION_COMPANY_NOT_FOUND'; END IF;

  v_env:=public.marketroute_authority_envelope_v1(p_organisation_id,p_campaign_id,p_company_id,p_at);
  IF NULLIF(v_env->'r5'->>'authorityRecordId','') IS NOT NULL THEN
    SELECT * INTO v_r5 FROM public.route_authority_r5_records WHERE authority_record_id=(v_env->'r5'->>'authorityRecordId')::uuid;
  END IF;
  IF NULLIF(v_env->'r6'->>'authorityRecordId','') IS NOT NULL THEN
    SELECT * INTO v_r6 FROM public.contact_authority_r6_records WHERE authority_record_id=(v_env->'r6'->>'authorityRecordId')::uuid;
  END IF;

  IF v_r5.id IS NOT NULL THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'ordinal',p.ordinality,
      'pathFingerprint',p.path->>'pathFingerprint',
      'pathState',p.path->>'pathState',
      'knowledgeState',p.path->>'knowledgeState',
      'terminalAccessPointId',p.path->>'terminalAccessPointId',
      'authorised',COALESCE(v_r6.authorised_path_fingerprints,'[]'::jsonb) ? (p.path->>'pathFingerprint'),
      'mode',COALESCE(rb.binding->>'mode',CASE WHEN p.path->>'pathState'='ORGANISATIONAL_OPEN' THEN 'ORGANISATIONAL_ROUTE' ELSE 'NAMED_CONTACT' END),
      'authorityState',COALESCE(rb.binding->>'authorityState',CASE WHEN COALESCE(v_r6.authorised_path_fingerprints,'[]'::jsonb) ? (p.path->>'pathFingerprint') THEN 'AUTHORISED' ELSE 'CONTACT_TRUTH_REQUIRED' END),
      'authorityReasonCode',rb.binding->>'reasonCode',
      'personId',rp.person_id,
      'personName',CASE WHEN rp.person_id IS NULL THEN NULL ELSE COALESCE(pe.canonical_name,pe.display_name) END,
      'roleTitles',COALESCE(ev.role_titles,'[]'::jsonb),
      'terminalAccessPoint',CASE WHEN ap.id IS NULL THEN NULL ELSE jsonb_build_object(
        'accessPointId',ap.id,'accessPointKind',ap.access_point_kind,'canonicalValue',ap.canonical_value
      ) END,
      'routeNextRevalidationAt',v_r5.next_revalidation_at,
      'contactNextRevalidationAt',CASE WHEN v_r6.id IS NULL THEN NULL ELSE v_r6.next_revalidation_at END,
      'evidence',jsonb_build_object(
        'identitySnapshotIds',COALESCE(ev.identity_snapshot_ids,'[]'::jsonb),
        'employmentSnapshotIds',COALESCE(ev.employment_snapshot_ids,'[]'::jsonb),
        'roleSnapshotIds',COALESCE(ev.role_snapshot_ids,'[]'::jsonb),
        'channelSnapshotIds',COALESCE(ev.channel_snapshot_ids,'[]'::jsonb)
      ),
      'nodes',COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'nodeId',n.id,'kind',n.node_kind,
        'label',COALESCE(n.label,co.canonical_name,pn.display_name,n.canonical_value,n.stable_key),
        'meta',CASE n.node_kind WHEN 'COMPANY' THEN co.canonical_domain WHEN 'PERSON' THEN pn.canonical_name WHEN 'ACCESS_POINT' THEN n.access_point_kind ELSE n.node_kind END,
        'canonicalValue',n.canonical_value,'accessPointKind',n.access_point_kind
      ) ORDER BY ids.ordinality)
      FROM jsonb_array_elements_text(p.path->'nodeIds') WITH ORDINALITY ids(node_id,ordinality)
      JOIN public.commercial_graph_nodes n ON n.id=ids.node_id::uuid
      LEFT JOIN public.companies co ON co.id=n.company_id
      LEFT JOIN public.people pn ON pn.id=n.person_id),'[]'::jsonb)
    ) ORDER BY p.ordinality),'[]'::jsonb) INTO v_paths
    FROM jsonb_array_elements(v_r5.paths_json) WITH ORDINALITY p(path,ordinality)
    LEFT JOIN LATERAL (
      SELECT b.value AS binding
      FROM jsonb_array_elements(COALESCE(v_r6.bindings_json,'[]'::jsonb)) b(value)
      WHERE b.value->>'pathFingerprint'=p.path->>'pathFingerprint'
      LIMIT 1
    ) rb ON true
    LEFT JOIN LATERAL (
      SELECT COALESCE(
        NULLIF(rb.binding->>'personId','')::uuid,
        (SELECT n.person_id
         FROM jsonb_array_elements_text(p.path->'nodeIds') WITH ORDINALITY ids(node_id,ordinality)
         JOIN public.commercial_graph_nodes n ON n.id=ids.node_id::uuid
         WHERE n.node_kind='PERSON' AND n.person_id IS NOT NULL
         ORDER BY ids.ordinality
         LIMIT 1)
      ) AS person_id
    ) rp ON true
    LEFT JOIN public.people pe ON pe.id=rp.person_id
    LEFT JOIN public.commercial_graph_nodes ap ON ap.id=NULLIF(p.path->>'terminalAccessPointId','')::uuid
    LEFT JOIN LATERAL (
      SELECT
        to_jsonb(COALESCE(array_agg(DISTINCT NULLIF(btrim(c.object_json->>'roleTitle'),'') ORDER BY NULLIF(btrim(c.object_json->>'roleTitle'),'')) FILTER (
          WHERE c.subject_type='PERSON' AND c.subject_id=rp.person_id AND c.claim_key='role.current' AND ts.truth_state IN('KNOWN','SUPPORTED') AND ts.next_revalidation_at>p_at AND NULLIF(btrim(c.object_json->>'roleTitle'),'') IS NOT NULL
        ),ARRAY[]::text[])) AS role_titles,
        to_jsonb(COALESCE(array_agg(ts.id::text ORDER BY ts.id::text) FILTER (WHERE c.subject_type='PERSON' AND c.subject_id=rp.person_id AND c.claim_key='identity.canonical_name'),ARRAY[]::text[])) AS identity_snapshot_ids,
        to_jsonb(COALESCE(array_agg(ts.id::text ORDER BY ts.id::text) FILTER (WHERE c.subject_type='PERSON' AND c.subject_id=rp.person_id AND c.claim_key='employment.current'),ARRAY[]::text[])) AS employment_snapshot_ids,
        to_jsonb(COALESCE(array_agg(ts.id::text ORDER BY ts.id::text) FILTER (WHERE c.subject_type='PERSON' AND c.subject_id=rp.person_id AND c.claim_key='role.current'),ARRAY[]::text[])) AS role_snapshot_ids,
        to_jsonb(COALESCE(array_agg(ts.id::text ORDER BY ts.id::text) FILTER (WHERE c.subject_type='CHANNEL' AND c.subject_id=ap.id AND c.claim_key='ownership.current'),ARRAY[]::text[])) AS channel_snapshot_ids
      FROM public.claims c
      JOIN public.truth_claim_snapshots ts ON ts.id=NULLIF(COALESCE(v_r6.contact_truth_snapshot_map,'{}'::jsonb)->>c.id::text,'')::uuid
      WHERE (c.subject_type='PERSON' AND c.subject_id=rp.person_id AND c.claim_key IN('identity.canonical_name','employment.current','role.current'))
         OR (c.subject_type='CHANNEL' AND c.subject_id=ap.id AND c.claim_key='ownership.current')
    ) ev ON true;
  END IF;

  RETURN jsonb_build_object(
    'contractVersion','MRV2-APPLICATION-READ-1.0.0',
    'resourceType','ROUTE_DISPLAY',
    'evaluatedAt',to_jsonb(p_at),
    'organisationId',p_organisation_id,
    'campaignId',p_campaign_id,
    'companyId',p_company_id,
    'company',jsonb_build_object(
      'companyName',v_company.canonical_name,
      'canonicalDomain',v_company.canonical_domain,
      'websiteUrl',v_company.website_url
    ),
    'r5Decision',COALESCE(v_r5.decision_code,'NO_CURRENT_R5'),
    'r6Decision',COALESCE(v_r6.decision_code,'NO_CURRENT_R6'),
    'paths',v_paths
  );
END $$;

--
-- Name: marketroute_attach_billing_checkout_v1(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_attach_billing_checkout_v1(p_attempt_id uuid, p_external_checkout_session_id text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF p_external_checkout_session_id IS NULL OR p_external_checkout_session_id !~ '^cs_' THEN RAISE EXCEPTION 'MARKETROUTE_BILLING_CHECKOUT_ID_INVALID'; END IF;
  UPDATE public.marketroute_billing_checkout_attempts SET external_checkout_session_id=p_external_checkout_session_id,status='REDIRECTED',updated_at=now() WHERE id=p_attempt_id AND status='PENDING';
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_BILLING_CHECKOUT_ATTEMPT_NOT_PENDING'; END IF;
  RETURN true;
END;$$;

--
-- Name: marketroute_authority_envelope_fingerprint_v1(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_authority_envelope_fingerprint_v1(p_envelope jsonb) RETURNS text
    LANGUAGE sql IMMUTABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
 SELECT encode(extensions.digest('MRV2-AUTHORITY-ENVELOPE-1.0.0|' || COALESCE(p_envelope,'{}'::jsonb)::text,'sha256'),'hex');
$$;

--
-- Name: marketroute_authority_envelope_v1(uuid, uuid, uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_authority_envelope_v1(p_organisation_id uuid, p_campaign_id uuid, p_company_id uuid, p_at timestamp with time zone DEFAULT now()) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_r4 public.commercial_reality_r4_records%ROWTYPE;
  v_r5 public.route_authority_r5_records%ROWTYPE;
  v_r6 public.contact_authority_r6_records%ROWTYPE;
  v_a4 public.authority_records%ROWTYPE;
  v_a5 public.authority_records%ROWTYPE;
  v_a6 public.authority_records%ROWTYPE;
  v_state text;
  v_required_layer text;
  v_reason text;
  v_ready boolean := false;
  v_next timestamptz;
BEGIN
  IF p_at IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_AUTHORITY_LIFECYCLE_TIME_REQUIRED'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.campaigns c WHERE c.id=p_campaign_id AND c.organisation_id=p_organisation_id) THEN
    RAISE EXCEPTION 'MARKETROUTE_AUTHORITY_LIFECYCLE_CAMPAIGN_SCOPE_MISMATCH';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.organisation_company_scopes s WHERE s.organisation_id=p_organisation_id AND s.company_id=p_company_id) THEN
    RAISE EXCEPTION 'MARKETROUTE_AUTHORITY_LIFECYCLE_COMPANY_SCOPE_MISMATCH';
  END IF;

  SELECT r.* INTO v_r4
  FROM public.commercial_reality_r4_records r
  WHERE r.organisation_id=p_organisation_id AND r.campaign_id=p_campaign_id AND r.company_id=p_company_id
    AND public.marketroute_r4_authority_current_v1(r.authority_record_id,p_at)
  ORDER BY r.created_at DESC,r.id DESC LIMIT 1;

  IF FOUND THEN SELECT * INTO v_a4 FROM public.authority_records WHERE id=v_r4.authority_record_id; END IF;

  IF v_r4.id IS NULL THEN
    v_state := 'R4_REVALIDATION_REQUIRED'; v_required_layer := 'R4'; v_reason := 'CURRENT_R4_REQUIRED';
  ELSIF v_r4.decision_code='NOT_ADMISSIBLE' THEN
    v_state := 'NOT_ADMISSIBLE'; v_reason := 'R4_NOT_ADMISSIBLE';
  ELSIF v_r4.decision_code='RESEARCH_REQUIRED' THEN
    v_state := 'COMMERCIAL_RESEARCH_REQUIRED'; v_required_layer := 'R4'; v_reason := 'R4_RESEARCH_REQUIRED';
  ELSE
    SELECT r.* INTO v_r5
    FROM public.route_authority_r5_records r
    WHERE r.organisation_id=p_organisation_id AND r.campaign_id=p_campaign_id AND r.company_id=p_company_id
      AND public.marketroute_r5_authority_current_v1(r.authority_record_id,p_at)
    ORDER BY r.created_at DESC,r.id DESC LIMIT 1;
    IF FOUND THEN SELECT * INTO v_a5 FROM public.authority_records WHERE id=v_r5.authority_record_id; END IF;

    IF v_r5.id IS NULL THEN
      v_state := 'R5_REVALIDATION_REQUIRED'; v_required_layer := 'R5'; v_reason := 'CURRENT_R5_REQUIRED';
    ELSIF v_r5.decision_code='ROUTE_NOT_APPLICABLE' THEN
      v_state := 'ROUTE_NOT_APPLICABLE'; v_reason := 'R5_ROUTE_NOT_APPLICABLE';
    ELSIF v_r5.decision_code='ROUTE_RESEARCH_REQUIRED' THEN
      v_state := 'ROUTE_RESEARCH_REQUIRED'; v_required_layer := 'R5'; v_reason := 'R5_RESEARCH_REQUIRED';
    ELSE
      SELECT r.* INTO v_r6
      FROM public.contact_authority_r6_records r
      WHERE r.organisation_id=p_organisation_id AND r.campaign_id=p_campaign_id AND r.company_id=p_company_id
        AND public.marketroute_r6_authority_current_v1(r.authority_record_id,p_at)
      ORDER BY r.created_at DESC,r.id DESC LIMIT 1;
      IF FOUND THEN SELECT * INTO v_a6 FROM public.authority_records WHERE id=v_r6.authority_record_id; END IF;

      IF v_r6.id IS NULL THEN
        v_state := 'R6_REVALIDATION_REQUIRED'; v_required_layer := 'R6'; v_reason := 'CURRENT_R6_REQUIRED';
      ELSIF v_r6.decision_code='CONTACT_NOT_APPLICABLE' THEN
        v_state := 'CONTACT_NOT_APPLICABLE'; v_reason := 'R6_CONTACT_NOT_APPLICABLE';
      ELSIF v_r6.decision_code='CONTACT_RESEARCH_REQUIRED' THEN
        v_state := 'CONTACT_RESEARCH_REQUIRED'; v_required_layer := 'R6'; v_reason := 'R6_RESEARCH_REQUIRED';
      ELSE
        v_state := 'AUTHORITY_READY'; v_reason := 'R4_R5_R6_CURRENT_AND_AUTHORISED'; v_ready := true;
      END IF;
    END IF;
  END IF;

  SELECT min(value) INTO v_next FROM unnest(ARRAY[
    CASE WHEN v_a4.id IS NOT NULL THEN v_a4.valid_until ELSE NULL END,
    CASE WHEN v_a5.id IS NOT NULL THEN v_a5.valid_until ELSE NULL END,
    CASE WHEN v_a6.id IS NOT NULL THEN v_a6.valid_until ELSE NULL END
  ]::timestamptz[]) AS u(value) WHERE value IS NOT NULL AND value>p_at;

  RETURN jsonb_build_object(
    'version','MRV2-AUTHORITY-LIFECYCLE-1.0.0',
    'organisationId',p_organisation_id::text,
    'campaignId',p_campaign_id::text,
    'companyId',p_company_id::text,
    'evaluatedAt',to_jsonb(p_at),
    'lifecycleState',v_state,
    'authorityReady',v_ready,
    'requiredLayer',v_required_layer,
    'reasonCode',v_reason,
    'nextRevalidationAt',CASE WHEN v_next IS NULL THEN NULL ELSE to_jsonb(v_next) END,
    'r4',jsonb_build_object(
      'current',v_r4.id IS NOT NULL,
      'decision',v_r4.decision_code,
      'authorityRecordId',v_a4.id,
      'authorityFingerprint',v_a4.authority_fingerprint,
      'validUntil',v_a4.valid_until
    ),
    'r5',jsonb_build_object(
      'current',v_r5.id IS NOT NULL,
      'decision',v_r5.decision_code,
      'authorityRecordId',v_a5.id,
      'authorityFingerprint',v_a5.authority_fingerprint,
      'parentAuthorityRecordId',v_r5.parent_r4_authority_record_id,
      'validUntil',v_a5.valid_until
    ),
    'r6',jsonb_build_object(
      'current',v_r6.id IS NOT NULL,
      'decision',v_r6.decision_code,
      'authorityRecordId',v_a6.id,
      'authorityFingerprint',v_a6.authority_fingerprint,
      'parentAuthorityRecordId',v_r6.parent_r5_authority_record_id,
      'validUntil',v_a6.valid_until
    )
  );
END $$;

--
-- Name: marketroute_authority_ready_v1(uuid, uuid, uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_authority_ready_v1(p_organisation_id uuid, p_campaign_id uuid, p_company_id uuid, p_at timestamp with time zone DEFAULT now()) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
 SELECT COALESCE((public.marketroute_authority_envelope_v1(p_organisation_id,p_campaign_id,p_company_id,p_at)->>'authorityReady')::boolean,false);
$$;

--
-- Name: marketroute_backfill_demand_fed_genesis_bank_v1(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_backfill_demand_fed_genesis_bank_v1(p_limit integer DEFAULT 250) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_inserted integer:=0;
BEGIN
  PERFORM public.marketroute_require_service_role();

  WITH company_batch AS (
    SELECT DISTINCT s.company_id,c.activation_job_id
    FROM public.organisation_company_scopes s
    JOIN public.campaigns c ON c.id=s.campaign_id AND c.organisation_id=s.organisation_id
    JOIN public.workspace_activation_jobs j ON j.id=c.activation_job_id AND j.organisation_id=c.organisation_id
    WHERE s.scope_kind='CAMPAIGN' AND s.campaign_id IS NOT NULL
      AND jsonb_typeof(j.result_json #> '{discovery,industryKeys}')='array'
      AND EXISTS (
        SELECT 1
        FROM jsonb_array_elements_text(j.result_json #> '{discovery,industryKeys}') k(industry_key)
        JOIN public.genesis_growth_industries i ON i.industry_key=k.industry_key AND i.enabled=true
        WHERE NOT EXISTS (
          SELECT 1 FROM public.genesis_growth_company_memberships m
          WHERE m.company_id=s.company_id AND m.industry_key=i.industry_key
        )
      )
    ORDER BY s.company_id,c.activation_job_id
    LIMIT greatest(1,least(COALESCE(p_limit,250),5000))
  ), classified AS (
    SELECT DISTINCT b.company_id,i.industry_key
    FROM company_batch b
    JOIN public.workspace_activation_jobs j ON j.id=b.activation_job_id
    CROSS JOIN LATERAL jsonb_array_elements_text(j.result_json #> '{discovery,industryKeys}') k(industry_key)
    JOIN public.genesis_growth_industries i ON i.industry_key=k.industry_key AND i.enabled=true
  ), inserted AS (
    INSERT INTO public.genesis_growth_company_memberships(industry_key,company_id,discovery_reason)
    SELECT c.industry_key,c.company_id,'DEMAND_FED_BOOTSTRAP_REPAIR'
    FROM classified c
    ON CONFLICT(industry_key,company_id) DO NOTHING
    RETURNING company_id
  )
  SELECT count(*)::int INTO v_inserted FROM inserted;

  INSERT INTO public.genesis_growth_company_progress(company_id)
  SELECT DISTINCT c.company_id
  FROM public.organisation_company_scopes c
  WHERE EXISTS(SELECT 1 FROM public.genesis_growth_company_memberships m WHERE m.company_id=c.company_id)
  ON CONFLICT(company_id) DO NOTHING;

  RETURN v_inserted;
END;
$$;

--
-- Name: marketroute_begin_billing_checkout_v1(uuid, uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_begin_billing_checkout_v1(p_organisation_id uuid, p_user_id uuid, p_plan_code text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_access jsonb;
  v_attempt uuid;
  v_ent public.organisation_commercial_entitlements%ROWTYPE;
  v_plan_limit integer;
  v_active_markets integer;
  v_legacy_full boolean:=false;
BEGIN
  PERFORM public.marketroute_require_service_role();

  IF p_plan_code NOT IN('STARTER','GROWTH','SCALE')
     OR NOT EXISTS(
       SELECT 1
       FROM public.marketroute_plan_catalog p
       WHERE p.plan_code=p_plan_code
         AND p.public_visible=true
     )
  THEN
    RAISE EXCEPTION 'MARKETROUTE_BILLING_PLAN_INVALID';
  END IF;

  IF NOT EXISTS(
    SELECT 1
    FROM public.organisation_memberships m
    WHERE m.organisation_id=p_organisation_id
      AND m.user_id=p_user_id
      AND m.status='ACTIVE'
      AND m.role='OWNER'
  ) THEN
    RAISE EXCEPTION 'MARKETROUTE_BILLING_OWNER_REQUIRED';
  END IF;

  SELECT *
  INTO v_ent
  FROM public.organisation_commercial_entitlements e
  WHERE e.organisation_id=p_organisation_id
  LIMIT 1;

  v_access:=public.marketroute_workspace_commercial_access_v1(p_organisation_id,now());
  v_legacy_full:=FOUND
    AND v_ent.plan_code='LEGACY_FULL'
    AND v_ent.status='ACTIVE'
    AND v_ent.external_subscription_id IS NULL
    AND COALESCE(v_access->>'mode','UNENTITLED')='FULL';

  IF COALESCE(v_access->>'mode','UNENTITLED')<>'DISCOVERY_FREE' AND NOT v_legacy_full THEN
    RAISE EXCEPTION 'MARKETROUTE_BILLING_CHECKOUT_NOT_AVAILABLE';
  END IF;

  IF FOUND
     AND v_ent.external_subscription_id IS NOT NULL
     AND v_ent.status NOT IN('CANCELLED','EXPIRED')
  THEN
    RAISE EXCEPTION 'MARKETROUTE_BILLING_EXISTING_SUBSCRIPTION_REQUIRES_PORTAL';
  END IF;

  SELECT p.active_market_limit
  INTO v_plan_limit
  FROM public.marketroute_plan_catalog p
  WHERE p.plan_code=p_plan_code
    AND p.public_visible=true;

  SELECT count(*)::int
  INTO v_active_markets
  FROM public.campaigns c
  WHERE c.organisation_id=p_organisation_id
    AND c.workflow_state<>'ARCHIVED';

  IF v_plan_limit IS NULL OR v_active_markets>v_plan_limit THEN
    RAISE EXCEPTION 'MARKETROUTE_BILLING_PLAN_CAMPAIGN_LIMIT_TOO_LOW';
  END IF;

  IF EXISTS(
    SELECT 1
    FROM public.marketroute_billing_checkout_attempts a
    WHERE a.organisation_id=p_organisation_id
      AND a.status IN('PENDING','REDIRECTED')
      AND a.created_at>now()-interval '31 minutes'
  ) THEN
    RAISE EXCEPTION 'MARKETROUTE_BILLING_CHECKOUT_ALREADY_IN_PROGRESS';
  END IF;

  INSERT INTO public.marketroute_billing_checkout_attempts(
    organisation_id,user_id,plan_code,status,metadata_json
  )
  VALUES(
    p_organisation_id,p_user_id,p_plan_code,'PENDING',
    jsonb_build_object(
      'source','RC_ENGAGEMENT_CURRENTNESS_BILLING_LEGACY_HOTFIX',
      'replacesLegacyFull',v_legacy_full
    )
  )
  RETURNING id INTO v_attempt;

  RETURN jsonb_build_object('attemptId',v_attempt);
END;$$;

--
-- Name: marketroute_begin_billing_event_v1(text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_begin_billing_event_v1(p_external_event_id text, p_event_type text, p_payload_sha256 text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
DECLARE v_inserted integer:=0;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF p_external_event_id IS NULL OR p_external_event_id !~ '^evt_' THEN RAISE EXCEPTION 'MARKETROUTE_BILLING_EVENT_ID_INVALID'; END IF;
  IF p_payload_sha256 IS NULL OR p_payload_sha256 !~ '^[a-f0-9]{64}$' THEN RAISE EXCEPTION 'MARKETROUTE_BILLING_EVENT_HASH_INVALID'; END IF;
  INSERT INTO public.marketroute_billing_events(external_event_id,event_type,payload_sha256,status)
  VALUES(p_external_event_id,left(COALESCE(p_event_type,''),160),p_payload_sha256,'RECEIVED') ON CONFLICT(external_event_id) DO NOTHING;
  GET DIAGNOSTICS v_inserted=ROW_COUNT;
  IF v_inserted=1 THEN RETURN true; END IF;
  IF EXISTS(SELECT 1 FROM public.marketroute_billing_events e WHERE e.external_event_id=p_external_event_id AND e.payload_sha256<>p_payload_sha256) THEN RAISE EXCEPTION 'MARKETROUTE_BILLING_EVENT_PAYLOAD_MISMATCH'; END IF;
  UPDATE public.marketroute_billing_events SET status='RECEIVED',error_code=NULL,received_at=now(),processed_at=NULL,updated_at=now()
  WHERE external_event_id=p_external_event_id AND (status='FAILED' OR (status='RECEIVED' AND updated_at<now()-interval '5 minutes'));
  GET DIAGNOSTICS v_inserted=ROW_COUNT;
  RETURN v_inserted=1;
END;$_$;

--
-- Name: marketroute_billing_context_v1(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_billing_context_v1(p_organisation_id uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_ent public.organisation_commercial_entitlements%ROWTYPE;
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT * INTO v_ent FROM public.organisation_commercial_entitlements e WHERE e.organisation_id=p_organisation_id LIMIT 1;
  RETURN jsonb_build_object(
    'organisationId',p_organisation_id,
    'planCode',CASE WHEN FOUND THEN v_ent.plan_code ELSE NULL END,
    'entitlementStatus',CASE WHEN FOUND THEN v_ent.status ELSE NULL END,
    'externalCustomerId',CASE WHEN FOUND THEN v_ent.external_customer_id ELSE NULL END,
    'externalSubscriptionId',CASE WHEN FOUND THEN v_ent.external_subscription_id ELSE NULL END,
    'currentPeriodStart',CASE WHEN FOUND THEN v_ent.current_period_start ELSE NULL END,
    'currentPeriodEnd',CASE WHEN FOUND THEN v_ent.current_period_end ELSE NULL END,
    'cancelAtPeriodEnd',CASE WHEN FOUND THEN COALESCE((v_ent.metadata_json->>'cancelAtPeriodEnd')::boolean,false) ELSE false END
  );
END;$$;

--
-- Name: marketroute_billing_reconciliation_due_v1(timestamp with time zone, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_billing_reconciliation_due_v1(p_at timestamp with time zone DEFAULT now(), p_limit integer DEFAULT 10) RETURNS TABLE(organisation_id uuid, external_customer_id text, external_subscription_id text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
  PERFORM public.marketroute_require_service_role();
  RETURN QUERY
  SELECT e.organisation_id,e.external_customer_id,e.external_subscription_id
  FROM public.organisation_commercial_entitlements e
  WHERE e.source='BILLING' AND e.external_customer_id IS NOT NULL AND e.external_subscription_id IS NOT NULL
    AND e.status NOT IN('CANCELLED','EXPIRED')
    AND COALESCE(NULLIF(e.metadata_json->>'lastRecoveryAttemptAt','')::timestamptz,'epoch'::timestamptz)<=p_at-interval '15 minutes'
    AND (e.status='PAST_DUE' OR e.current_period_end IS NULL OR e.current_period_end<=p_at+interval '24 hours' OR COALESCE(NULLIF(e.metadata_json->>'lastReconciledAt','')::timestamptz,e.updated_at)<=p_at-interval '6 hours')
  ORDER BY CASE WHEN e.current_period_end IS NULL THEN p_at ELSE e.current_period_end END,e.updated_at,e.organisation_id
  LIMIT LEAST(50,GREATEST(1,COALESCE(p_limit,10)));
END;$$;

--
-- Name: marketroute_campaign_authority_ready_count_v1(uuid, uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_campaign_authority_ready_count_v1(p_organisation_id uuid, p_campaign_id uuid, p_at timestamp with time zone DEFAULT now()) RETURNS integer
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  SELECT COALESCE(count(DISTINCT r.company_id),0)::int
  FROM public.marketroute_materialised_ready_opportunities_v1(
    p_organisation_id,p_campaign_id,250,COALESCE(p_at,now())
  ) r;
$$;

--
-- Name: marketroute_campaign_capacity_v1(uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_campaign_capacity_v1(p_organisation_id uuid, p_at timestamp with time zone DEFAULT now()) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_plan_code text;
  v_plan_name text;
  v_limit integer:=1;
  v_count integer:=0;
  v_mode text:='UNENTITLED';
  v_current_price numeric:=0;
  v_next_code text;
  v_next_name text;
  v_next_limit integer;
BEGIN
  PERFORM public.marketroute_require_service_role();

  SELECT e.plan_code,p.display_name,p.active_market_limit,p.monthly_price_gbp
  INTO v_plan_code,v_plan_name,v_limit,v_current_price
  FROM public.organisation_commercial_entitlements e
  JOIN public.marketroute_plan_catalog p ON p.plan_code=e.plan_code
  WHERE e.organisation_id=p_organisation_id
    AND e.status='ACTIVE'
    AND (e.current_period_start IS NULL OR e.current_period_start<=p_at)
    AND (e.current_period_end IS NULL OR e.current_period_end>p_at)
  ORDER BY e.updated_at DESC
  LIMIT 1;

  IF v_plan_code IS NOT NULL THEN
    v_mode:=CASE WHEN v_plan_code='LEGACY_FULL' THEN 'FULL' ELSE 'PAID' END;
  ELSIF EXISTS(
    SELECT 1 FROM public.anonymous_discovery_runs r
    WHERE r.organisation_id=p_organisation_id
      AND r.status IN ('ACTIVE','CLAIMED')
  ) THEN
    v_plan_code:='DISCOVERY';v_plan_name:='MarketRoute Discovery';v_limit:=1;v_current_price:=0;v_mode:='DISCOVERY_FREE';
  ELSE
    v_plan_code:=NULL;v_plan_name:=NULL;v_limit:=1;v_current_price:=0;v_mode:='UNENTITLED';
  END IF;

  SELECT count(*)::int INTO v_count
  FROM public.campaigns c
  WHERE c.organisation_id=p_organisation_id
    AND c.workflow_state<>'ARCHIVED';

  IF v_mode IN ('PAID','FULL') AND v_count<v_limit THEN
    v_next_code:=NULL;v_next_name:=NULL;v_next_limit:=NULL;
  ELSE
    SELECT p.plan_code,p.display_name,p.active_market_limit
    INTO v_next_code,v_next_name,v_next_limit
    FROM public.marketroute_plan_catalog p
    WHERE p.public_visible=true
      AND p.plan_code IN ('STARTER','GROWTH','SCALE')
      AND p.active_market_limit>=v_count+1
      AND p.monthly_price_gbp>v_current_price
    ORDER BY p.monthly_price_gbp,p.active_market_limit
    LIMIT 1;
  END IF;

  RETURN jsonb_build_object(
    'mode',v_mode,
    'planCode',v_plan_code,
    'planName',v_plan_name,
    'activeMarketLimit',v_limit,
    'activeMarketCount',v_count,
    'remainingMarkets',greatest(0,v_limit-v_count),
    'canCreate',(v_mode IN ('PAID','FULL') AND v_count<v_limit),
    'requiresUpgrade',NOT (v_mode IN ('PAID','FULL') AND v_count<v_limit),
    'nextPlanCode',v_next_code,
    'nextPlanName',v_next_name,
    'nextPlanActiveMarketLimit',v_next_limit
  );
END;$$;

--
-- Name: marketroute_campaign_research_cycle_ready_v1(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_campaign_research_cycle_ready_v1(p_organisation_id uuid, p_campaign_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  -- A refill cycle may widen only after every currently scoped company has had a
  -- campaign-specific research plan since it entered this campaign and that plan's
  -- queued work has settled. A pre-existing global COMPANY_CORE snapshot alone is
  -- not sufficient: otherwise a dense Genesis-bank company could cause repeated
  -- widening before its campaign-specific R4/R5/R6 work has had a chance to run.
  SELECT NOT EXISTS(
    SELECT 1
    FROM public.organisation_company_scopes s
    WHERE s.organisation_id=p_organisation_id
      AND s.campaign_id=p_campaign_id
      AND s.scope_kind='CAMPAIGN'
      AND (
        NOT EXISTS(
          SELECT 1
          FROM public.research_plan_runs p
          WHERE p.organisation_id=s.organisation_id
            AND p.campaign_id=s.campaign_id
            AND p.company_id=s.company_id
            AND p.reference_time>=s.created_at
        )
        OR EXISTS(
          SELECT 1
          FROM public.research_plan_runs p
          JOIN public.research_work_units w ON w.plan_id=p.id
          JOIN public.background_jobs j ON j.id=w.background_job_id
          WHERE p.organisation_id=s.organisation_id
            AND p.campaign_id=s.campaign_id
            AND p.company_id=s.company_id
            AND p.reference_time>=s.created_at
            AND j.status IN('PENDING','DEFERRED','RUNNING')
        )
      )
  );
$$;

--
-- Name: marketroute_campaign_research_entitled_v1(uuid, uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_campaign_research_entitled_v1(p_organisation_id uuid, p_campaign_id uuid, p_at timestamp with time zone DEFAULT now()) RETURNS boolean
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_limit integer;v_rank integer;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.campaigns c WHERE c.organisation_id=p_organisation_id AND c.id=p_campaign_id AND c.workflow_state<>'ARCHIVED') THEN RETURN false; END IF;
  IF public.marketroute_paid_entitlement_active_v1(p_organisation_id,p_at) THEN
    SELECT p.active_market_limit INTO v_limit
    FROM public.organisation_commercial_entitlements e
    JOIN public.marketroute_plan_catalog p ON p.plan_code=e.plan_code
    WHERE e.organisation_id=p_organisation_id AND e.status='ACTIVE'
      AND e.plan_code IN('STARTER','GROWTH','SCALE','LEGACY_FULL')
      AND (e.current_period_start IS NULL OR e.current_period_start<=p_at)
      AND (e.current_period_end IS NULL OR e.current_period_end>p_at)
    LIMIT 1;
    SELECT count(*)::int INTO v_rank
    FROM public.campaigns c
    WHERE c.organisation_id=p_organisation_id AND c.workflow_state<>'ARCHIVED'
      AND (c.created_at,c.id) <= (
        SELECT cx.created_at,cx.id FROM public.campaigns cx
        WHERE cx.organisation_id=p_organisation_id AND cx.id=p_campaign_id
      );
    RETURN COALESCE(v_rank,2147483647)<=COALESCE(v_limit,0);
  END IF;
  RETURN EXISTS(
    SELECT 1 FROM public.anonymous_discovery_runs r
    WHERE r.organisation_id=p_organisation_id
      AND r.original_campaign_id=p_campaign_id
      AND r.status IN('ACTIVE','CLAIMED')
      AND r.research_expires_at>p_at
      AND NOT public.marketroute_anonymous_discovery_budget_terminal_v1(r.id,p_at)
  );
END;$$;

--
-- Name: marketroute_claim_anonymous_discovery_extension_v1(text, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_claim_anonymous_discovery_extension_v1(p_worker_id text, p_at timestamp with time zone DEFAULT now()) RETURNS TABLE(job_id uuid, run_id uuid, organisation_id uuid, campaign_id uuid, seller_business_id uuid, seller_name text, canonical_domain text, website_url text, objective_text text, target_market_text text, target_count integer, scoped_count integer, remaining_count integer, attempt_count integer, existing_domains text[])
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_job uuid;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF length(btrim(COALESCE(p_worker_id,'')))<3 THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_EXTENSION_WORKER_REQUIRED'; END IF;

  -- Seed a tracking job as soon as a run has a READY deficit. Unlike v3 this does
  -- not require the research-cycle marker first. That lets the same controller
  -- terminate truthfully if the batch becomes economically unable to finish.
  INSERT INTO public.anonymous_discovery_extension_jobs(
    run_id,organisation_id,campaign_id,status,available_at,cycle_policy_version
  )
  SELECT r.id,r.organisation_id,r.original_campaign_id,'PENDING',p_at,4
  FROM public.anonymous_discovery_runs r
  JOIN public.campaigns c ON c.id=r.original_campaign_id AND c.organisation_id=r.organisation_id
  WHERE r.status IN('ACTIVE','CLAIMED')
    AND r.original_campaign_id IS NOT NULL
    AND c.workflow_state='ACTIVE'
    AND NOT public.marketroute_paid_entitlement_active_v1(r.organisation_id,p_at)
    AND public.marketroute_anonymous_discovery_ready_count_v1(r.id,p_at)<r.target_count
  ON CONFLICT ON CONSTRAINT anonymous_discovery_extension_jobs_run_id_key DO UPDATE SET
    campaign_id=EXCLUDED.campaign_id,
    cycle_policy_version=4,
    attempt_count=CASE
      WHEN anonymous_discovery_extension_jobs.cycle_policy_version<4
       AND anonymous_discovery_extension_jobs.status IN('SUCCEEDED','EXHAUSTED')
      THEN 0
      ELSE anonymous_discovery_extension_jobs.attempt_count
    END,
    status=CASE
      WHEN anonymous_discovery_extension_jobs.cycle_policy_version<4
       AND anonymous_discovery_extension_jobs.status IN('SUCCEEDED','EXHAUSTED')
      THEN 'PENDING'
      ELSE anonymous_discovery_extension_jobs.status
    END,
    available_at=CASE
      WHEN anonymous_discovery_extension_jobs.cycle_policy_version<4
       AND anonymous_discovery_extension_jobs.status IN('SUCCEEDED','EXHAUSTED')
      THEN p_at
      ELSE anonymous_discovery_extension_jobs.available_at
    END,
    last_error_code=CASE
      WHEN anonymous_discovery_extension_jobs.cycle_policy_version<4
       AND anonymous_discovery_extension_jobs.status IN('SUCCEEDED','EXHAUSTED')
      THEN 'MARKETROUTE_ANONYMOUS_EXTENSION_REARMED_FOR_BUDGET_LIVENESS_POLICY'
      ELSE anonymous_discovery_extension_jobs.last_error_code
    END;

  -- Terminalise jobs that can no longer make progress. This runs before the
  -- research-cycle gate so "missing COMPANY_CORE" cannot deadlock an exhausted run.
  UPDATE public.anonymous_discovery_extension_jobs j
  SET status='EXHAUSTED',
      cycle_policy_version=4,
      worker_id=NULL,
      lease_expires_at=NULL,
      last_error_code=CASE
        WHEN public.marketroute_paid_entitlement_active_v1(j.organisation_id,p_at)
          THEN 'MARKETROUTE_ANONYMOUS_EXTENSION_STOPPED_PAID_CONVERSION'
        WHEN r.research_expires_at<=p_at
          THEN 'MARKETROUTE_ANONYMOUS_EXTENSION_RESEARCH_WINDOW_CLOSED'
        WHEN j.attempt_count>=3
          THEN 'MARKETROUTE_ANONYMOUS_EXTENSION_ATTEMPT_CEILING_REACHED'
        WHEN (SELECT count(DISTINCT s.company_id) FROM public.organisation_company_scopes s WHERE s.organisation_id=j.organisation_id AND s.campaign_id=j.campaign_id AND s.scope_kind='CAMPAIGN')>=LEAST(40,GREATEST(r.target_count,r.target_count*4))
          THEN 'MARKETROUTE_ANONYMOUS_EXTENSION_CANDIDATE_CEILING_REACHED'
        WHEN public.marketroute_anonymous_discovery_budget_terminal_v1(r.id,p_at)
          THEN 'MARKETROUTE_ANONYMOUS_EXTENSION_RESEARCH_CAPACITY_EXHAUSTED'
        ELSE 'MARKETROUTE_ANONYMOUS_EXTENSION_EXHAUSTED'
      END,
      result_json=COALESCE(j.result_json,'{}'::jsonb)||jsonb_build_object(
        'terminalAt',p_at,
        'readyCount',public.marketroute_anonymous_discovery_ready_count_v1(r.id,p_at),
        'readyTarget',r.target_count,
        'quotaCyclePolicyVersion',4,
        'terminallyBudgetAware',true,
        'completionMetric','AUTHORITY_READY_OPPORTUNITIES'
      )
  FROM public.anonymous_discovery_runs r
  WHERE r.id=j.run_id
    AND j.status IN('PENDING','DEFERRED','SUCCEEDED','EXHAUSTED')
    AND public.marketroute_anonymous_discovery_ready_count_v1(r.id,p_at)<r.target_count
    AND (
      public.marketroute_paid_entitlement_active_v1(j.organisation_id,p_at)
      OR r.research_expires_at<=p_at
      OR j.attempt_count>=3
      OR (SELECT count(DISTINCT s.company_id) FROM public.organisation_company_scopes s WHERE s.organisation_id=j.organisation_id AND s.campaign_id=j.campaign_id AND s.scope_kind='CAMPAIGN')>=LEAST(40,GREATEST(r.target_count,r.target_count*4))
      OR public.marketroute_anonymous_discovery_budget_terminal_v1(r.id,p_at)
    );

  UPDATE public.anonymous_discovery_extension_jobs j
  SET status='DEFERRED',worker_id=NULL,lease_expires_at=NULL,available_at=p_at,
      last_error_code='MARKETROUTE_ANONYMOUS_EXTENSION_LEASE_RECOVERED'
  WHERE j.status='RUNNING' AND j.lease_expires_at<p_at;

  SELECT j.id INTO v_job
  FROM public.anonymous_discovery_extension_jobs j
  JOIN public.anonymous_discovery_runs r ON r.id=j.run_id AND r.original_campaign_id=j.campaign_id
  JOIN public.campaigns c ON c.id=j.campaign_id AND c.organisation_id=j.organisation_id
  WHERE j.status IN('PENDING','DEFERRED')
    AND j.available_at<=p_at
    AND j.attempt_count<3
    AND r.status IN('ACTIVE','CLAIMED')
    AND r.research_expires_at>p_at
    AND c.workflow_state='ACTIVE'
    AND NOT public.marketroute_paid_entitlement_active_v1(j.organisation_id,p_at)
    AND NOT public.marketroute_anonymous_discovery_budget_terminal_v1(r.id,p_at)
    AND public.marketroute_anonymous_discovery_research_cycle_ready_v1(r.id)
    AND public.marketroute_anonymous_discovery_ready_count_v1(r.id,p_at)<r.target_count
    AND (
      SELECT count(DISTINCT s.company_id)
      FROM public.organisation_company_scopes s
      WHERE s.organisation_id=j.organisation_id
        AND s.campaign_id=j.campaign_id
        AND s.scope_kind='CAMPAIGN'
    ) < LEAST(40,GREATEST(r.target_count,r.target_count*4))
  ORDER BY j.available_at,j.created_at,j.id
  FOR UPDATE OF j SKIP LOCKED
  LIMIT 1;

  IF v_job IS NULL THEN RETURN; END IF;

  UPDATE public.anonymous_discovery_extension_jobs
  SET status='RUNNING',
      attempt_count=anonymous_discovery_extension_jobs.attempt_count+1,
      cycle_policy_version=4,
      worker_id=left(btrim(p_worker_id),200),
      lease_expires_at=p_at+interval '5 minutes',
      last_error_code=NULL
  WHERE id=v_job;

  RETURN QUERY
  SELECT j.id,r.id,r.organisation_id,j.campaign_id,r.seller_business_id,s.name,s.canonical_domain,s.website_url,
    COALESCE(r.objective_text,'Win new B2B contracts'),COALESCE(r.target_market_text,'Target market'),r.target_count,
    (SELECT count(DISTINCT sc.company_id)::int FROM public.organisation_company_scopes sc WHERE sc.organisation_id=r.organisation_id AND sc.campaign_id=j.campaign_id AND sc.scope_kind='CAMPAIGN'),
    greatest(0,r.target_count-public.marketroute_anonymous_discovery_ready_count_v1(r.id,p_at)),
    j.attempt_count,
    COALESCE((SELECT array_agg(DISTINCT lower(cmp.canonical_domain) ORDER BY lower(cmp.canonical_domain)) FROM public.organisation_company_scopes sc JOIN public.companies cmp ON cmp.id=sc.company_id WHERE sc.organisation_id=r.organisation_id AND sc.campaign_id=j.campaign_id AND sc.scope_kind='CAMPAIGN' AND cmp.canonical_domain IS NOT NULL),'{}'::text[])
  FROM public.anonymous_discovery_extension_jobs j
  JOIN public.anonymous_discovery_runs r ON r.id=j.run_id
  JOIN public.seller_businesses s ON s.id=r.seller_business_id AND s.organisation_id=r.organisation_id
  WHERE j.id=v_job;
END;
$$;

--
-- Name: marketroute_claim_anonymous_discovery_v1(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_claim_anonymous_discovery_v1(p_browser_key_hash text, p_actor_user_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
DECLARE v_user uuid:=p_actor_user_id;v_run public.anonymous_discovery_runs%ROWTYPE;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_AUTH_REQUIRED'; END IF;
  IF COALESCE(p_browser_key_hash,'') !~ '^[a-f0-9]{64}$' THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_HASH_INVALID'; END IF;
  SELECT * INTO v_run FROM public.anonymous_discovery_runs WHERE browser_key_hash=p_browser_key_hash FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_RUN_NOT_FOUND'; END IF;
  IF v_run.status='BLOCKED' THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_RUN_BLOCKED'; END IF;
  IF v_run.status='CLAIMED' THEN
    IF v_run.claimed_by_user_id IS DISTINCT FROM v_user THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_RUN_ALREADY_CLAIMED'; END IF;
    RETURN jsonb_build_object('organisationId',v_run.organisation_id,'runId',v_run.id,'alreadyClaimed',true);
  END IF;

  -- Membership first is safe while the workspace is still anonymous. Creator ownership
  -- is then promoted atomically before child creator columns are normalised.
  INSERT INTO public.organisation_memberships(organisation_id,user_id,role,status)
  VALUES(v_run.organisation_id,v_user,'OWNER','ACTIVE')
  ON CONFLICT(organisation_id,user_id) DO UPDATE SET role='OWNER',status='ACTIVE',updated_at=now();

  UPDATE public.organisations SET created_by=v_user,workspace_kind='CUSTOMER',updated_at=now()
  WHERE id=v_run.organisation_id;
  UPDATE public.seller_businesses SET created_by=v_user,updated_at=now()
  WHERE organisation_id=v_run.organisation_id AND created_by IS NULL;
  UPDATE public.campaigns SET created_by=v_user,updated_at=now()
  WHERE organisation_id=v_run.organisation_id AND created_by IS NULL;

  UPDATE public.anonymous_discovery_runs
  SET status='CLAIMED',claimed_by_user_id=v_user,claimed_at=now(),updated_at=now()
  WHERE id=v_run.id;

  RETURN jsonb_build_object('organisationId',v_run.organisation_id,'runId',v_run.id,'alreadyClaimed',false);
END;
$_$;

--
-- Name: marketroute_claim_engagement_delivery_v1(text, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_claim_engagement_delivery_v1(p_worker_id text, p_at timestamp with time zone DEFAULT now()) RETURNS TABLE(queue_item_id uuid, job_id uuid, attempt_number integer, send_gate_fingerprint text, delivery_payload jsonb)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_job public.engagement_delivery_jobs%ROWTYPE; v_queue public.engagement_queue_items%ROWTYPE; v_gate jsonb;
BEGIN
 PERFORM public.marketroute_require_service_role(); IF p_at IS NULL OR abs(extract(epoch FROM(now()-p_at)))>300 THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_CLAIM_TIME_NOT_CURRENT'; END IF; IF length(btrim(COALESCE(p_worker_id,''))) NOT BETWEEN 1 AND 160 THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_WORKER_ID_INVALID'; END IF; PERFORM public.marketroute_recover_abandoned_engagement_delivery_v1(p_at);
 SELECT j.* INTO v_job
 FROM public.engagement_delivery_jobs j
 JOIN public.engagement_queue_items q ON q.id=j.queue_item_id
 WHERE j.status='PENDING'
   AND NOT EXISTS(SELECT 1 FROM public.engagement_delivery_jobs running JOIN public.engagement_queue_items rq ON rq.id=running.queue_item_id WHERE rq.opportunity_id=q.opportunity_id AND running.status='RUNNING')
   AND NOT EXISTS(SELECT 1 FROM public.engagement_delivery_jobs older JOIN public.engagement_queue_items oq ON oq.id=older.queue_item_id WHERE oq.opportunity_id=q.opportunity_id AND older.status='PENDING' AND (older.created_at,older.id)<(j.created_at,j.id))
 ORDER BY j.created_at,j.id FOR UPDATE OF j SKIP LOCKED LIMIT 1;
 IF NOT FOUND THEN RETURN; END IF;
 SELECT * INTO v_queue FROM public.engagement_queue_items WHERE id=v_job.queue_item_id;
 PERFORM 1 FROM public.campaigns c WHERE c.id=v_queue.campaign_id AND c.organisation_id=v_queue.organisation_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_DELIVERY_CAMPAIGN_NOT_FOUND'; END IF;
 PERFORM 1 FROM public.opportunities WHERE id=v_queue.opportunity_id FOR UPDATE;
 IF EXISTS(SELECT 1 FROM public.engagement_delivery_jobs other JOIN public.engagement_queue_items oq ON oq.id=other.queue_item_id WHERE oq.opportunity_id=v_queue.opportunity_id AND other.status='RUNNING' AND other.id<>v_job.id) THEN RETURN; END IF;
 v_gate:=public.marketroute_engagement_send_gate_v1(v_job.queue_item_id,p_at);
 IF COALESCE((v_gate->>'allowed')::boolean,false) IS NOT TRUE THEN
  UPDATE public.engagement_delivery_jobs SET status='BLOCKED_STALE',finished_at=p_at,last_error_code=v_gate->>'reasonCode' WHERE id=v_job.id;
  INSERT INTO public.engagement_delivery_events(queue_item_id,job_id,event_type,worker_id,send_gate_fingerprint,metadata_json,occurred_at) VALUES(v_job.queue_item_id,v_job.id,'BLOCKED_STALE',p_worker_id,v_gate->>'sendGateFingerprint',jsonb_build_object('reasonCode',v_gate->>'reasonCode'),p_at); RETURN;
 END IF;
 UPDATE public.engagement_delivery_jobs SET status='RUNNING',attempt_number=1,claimed_by=p_worker_id,claimed_at=p_at,send_gate_fingerprint=v_gate->>'sendGateFingerprint',last_error_code=NULL WHERE id=v_job.id RETURNING * INTO v_job;
 INSERT INTO public.engagement_delivery_events(queue_item_id,job_id,event_type,worker_id,send_gate_fingerprint,metadata_json,occurred_at) VALUES(v_job.queue_item_id,v_job.id,'CLAIMED',p_worker_id,v_job.send_gate_fingerprint,jsonb_build_object('authorityEnvelopeFingerprint',v_gate->>'authorityEnvelopeFingerprint','currentApprovalId',v_gate->>'currentApprovalId','currentApprovalMode',v_gate->>'currentApprovalMode'),p_at);
 RETURN QUERY SELECT v_job.queue_item_id,v_job.id,v_job.attempt_number,v_job.send_gate_fingerprint,v_gate->'deliveryPayload';
END $$;

--
-- Name: marketroute_claim_paid_campaign_refill_v1(text, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_claim_paid_campaign_refill_v1(p_worker_id text, p_at timestamp with time zone DEFAULT now()) RETURNS TABLE(job_id uuid, organisation_id uuid, campaign_id uuid, seller_business_id uuid, seller_name text, canonical_domain text, website_url text, objective_text text, target_market_text text, target_count integer, scoped_count integer, remaining_count integer, attempt_count integer, existing_domains text[])
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_job uuid;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF length(btrim(COALESCE(p_worker_id,'')))<3 THEN
    RAISE EXCEPTION 'MARKETROUTE_PAID_REFILL_WORKER_REQUIRED';
  END IF;

  INSERT INTO public.paid_campaign_refill_jobs(
    organisation_id,campaign_id,target_count,candidate_ceiling,status,available_at
  )
  SELECT c.organisation_id,c.id,10,60,'PENDING',p_at
  FROM public.campaigns c
  JOIN public.research_budget_policies rp
    ON rp.organisation_id=c.organisation_id
   AND rp.campaign_id=c.id
   AND rp.enabled=true
  WHERE c.workflow_state='ACTIVE'
    AND public.marketroute_paid_entitlement_active_v1(c.organisation_id,p_at)
    AND public.marketroute_campaign_research_entitled_v1(c.organisation_id,c.id,p_at)
    AND public.marketroute_campaign_authority_ready_count_v1(c.organisation_id,c.id,p_at)<10
    AND (
      SELECT count(DISTINCT s.company_id)
      FROM public.organisation_company_scopes s
      WHERE s.organisation_id=c.organisation_id
        AND s.campaign_id=c.id
        AND s.scope_kind='CAMPAIGN'
    )<60
  ON CONFLICT ON CONSTRAINT paid_campaign_refill_jobs_organisation_id_campaign_id_key
  DO UPDATE SET
    status=CASE
      WHEN paid_campaign_refill_jobs.status='SUCCEEDED' THEN 'DEFERRED'
      WHEN paid_campaign_refill_jobs.status='EXHAUSTED'
        AND paid_campaign_refill_jobs.last_error_code='MARKETROUTE_PAID_REFILL_ENTITLEMENT_INACTIVE'
      THEN 'DEFERRED'
      ELSE paid_campaign_refill_jobs.status
    END,
    attempt_count=CASE
      WHEN paid_campaign_refill_jobs.status='SUCCEEDED' THEN 0
      WHEN paid_campaign_refill_jobs.status='EXHAUSTED'
        AND paid_campaign_refill_jobs.last_error_code='MARKETROUTE_PAID_REFILL_ENTITLEMENT_INACTIVE'
      THEN 0
      ELSE paid_campaign_refill_jobs.attempt_count
    END,
    available_at=CASE
      WHEN paid_campaign_refill_jobs.status='SUCCEEDED' THEN p_at
      WHEN paid_campaign_refill_jobs.status='EXHAUSTED'
        AND paid_campaign_refill_jobs.last_error_code='MARKETROUTE_PAID_REFILL_ENTITLEMENT_INACTIVE'
      THEN p_at
      ELSE paid_campaign_refill_jobs.available_at
    END,
    last_error_code=CASE
      WHEN paid_campaign_refill_jobs.status='SUCCEEDED' THEN NULL
      WHEN paid_campaign_refill_jobs.status='EXHAUSTED'
        AND paid_campaign_refill_jobs.last_error_code='MARKETROUTE_PAID_REFILL_ENTITLEMENT_INACTIVE'
      THEN NULL
      ELSE paid_campaign_refill_jobs.last_error_code
    END,
    updated_at=p_at;

  UPDATE public.paid_campaign_refill_jobs j
  SET status='EXHAUSTED',
      worker_id=NULL,
      lease_expires_at=NULL,
      last_error_code='MARKETROUTE_PAID_REFILL_ENTITLEMENT_INACTIVE',
      updated_at=p_at
  WHERE j.status IN('PENDING','DEFERRED','RUNNING')
    AND NOT public.marketroute_paid_entitlement_active_v1(j.organisation_id,p_at);

  UPDATE public.paid_campaign_refill_jobs j
  SET status='DEFERRED',
      worker_id=NULL,
      lease_expires_at=NULL,
      available_at=p_at,
      last_error_code='MARKETROUTE_PAID_REFILL_LEASE_RECOVERED',
      updated_at=p_at
  WHERE j.status='RUNNING'
    AND j.lease_expires_at<p_at;

  SELECT j.id
  INTO v_job
  FROM public.paid_campaign_refill_jobs j
  JOIN public.campaigns c
    ON c.id=j.campaign_id
   AND c.organisation_id=j.organisation_id
  JOIN public.research_budget_policies rp
    ON rp.organisation_id=j.organisation_id
   AND rp.campaign_id=j.campaign_id
  WHERE j.status IN('PENDING','DEFERRED')
    AND j.available_at<=p_at
    AND j.attempt_count<6
    AND c.workflow_state='ACTIVE'
    AND rp.enabled=true
    AND public.marketroute_paid_entitlement_active_v1(j.organisation_id,p_at)
    AND public.marketroute_campaign_research_entitled_v1(j.organisation_id,j.campaign_id,p_at)
    AND public.marketroute_campaign_research_cycle_ready_v1(j.organisation_id,j.campaign_id)
    AND public.marketroute_campaign_authority_ready_count_v1(j.organisation_id,j.campaign_id,p_at)<j.target_count
    AND COALESCE((public.marketroute_research_capacity_snapshot_v1(j.organisation_id,p_at)->>'available')::boolean,false)=true
    AND (
      SELECT count(DISTINCT s.company_id)
      FROM public.organisation_company_scopes s
      WHERE s.organisation_id=j.organisation_id
        AND s.campaign_id=j.campaign_id
        AND s.scope_kind='CAMPAIGN'
    )<j.candidate_ceiling
  ORDER BY j.available_at,j.created_at,j.id
  FOR UPDATE OF j SKIP LOCKED
  LIMIT 1;

  IF v_job IS NULL THEN RETURN; END IF;

  UPDATE public.paid_campaign_refill_jobs AS prj
  SET status='RUNNING',
      attempt_count=prj.attempt_count+1,
      worker_id=left(btrim(p_worker_id),200),
      lease_expires_at=p_at+interval '5 minutes',
      last_error_code=NULL,
      updated_at=p_at
  WHERE prj.id=v_job;

  RETURN QUERY
  SELECT
    j.id,
    j.organisation_id,
    j.campaign_id,
    c.seller_business_id,
    s.name,
    s.canonical_domain,
    s.website_url,
    COALESCE(c.objective_text,'Win new B2B contracts'),
    COALESCE(a.target_market_text,ad.target_market_text,'Target market'),
    j.target_count,
    (
      SELECT count(DISTINCT sc.company_id)::int
      FROM public.organisation_company_scopes sc
      WHERE sc.organisation_id=j.organisation_id
        AND sc.campaign_id=j.campaign_id
        AND sc.scope_kind='CAMPAIGN'
    ),
    greatest(
      0,
      j.target_count-public.marketroute_campaign_authority_ready_count_v1(
        j.organisation_id,j.campaign_id,p_at
      )
    ),
    j.attempt_count,
    COALESCE((
      SELECT array_agg(
        DISTINCT lower(cmp.canonical_domain)
        ORDER BY lower(cmp.canonical_domain)
      )
      FROM public.organisation_company_scopes sc
      JOIN public.companies cmp ON cmp.id=sc.company_id
      WHERE sc.organisation_id=j.organisation_id
        AND sc.campaign_id=j.campaign_id
        AND sc.scope_kind='CAMPAIGN'
        AND cmp.canonical_domain IS NOT NULL
    ),'{}'::text[])
  FROM public.paid_campaign_refill_jobs j
  JOIN public.campaigns c
    ON c.id=j.campaign_id
   AND c.organisation_id=j.organisation_id
  JOIN public.seller_businesses s
    ON s.id=c.seller_business_id
   AND s.organisation_id=c.organisation_id
  LEFT JOIN public.workspace_activation_jobs a
    ON a.id=c.activation_job_id
   AND a.organisation_id=c.organisation_id
  LEFT JOIN public.anonymous_discovery_runs ad
    ON ad.original_campaign_id=c.id
   AND ad.organisation_id=c.organisation_id
  WHERE j.id=v_job;
END;
$$;

--
-- Name: marketroute_claim_research_work_v1(uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_claim_research_work_v1(p_scheduler_run_id uuid, p_at timestamp with time zone DEFAULT now()) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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
      AND public.marketroute_campaign_research_entitled_v1(w.organisation_id,w.campaign_id,p_at)
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
          AND a.original_campaign_id = w.campaign_id
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
        AND original_campaign_id = v_work.campaign_id
        AND status IN ('ACTIVE','CLAIMED')
      ORDER BY created_at
      LIMIT 1;
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
$$;

--
-- Name: marketroute_claim_workspace_activation_v1(text, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_claim_workspace_activation_v1(p_worker_id text, p_at timestamp with time zone DEFAULT now()) RETURNS TABLE(job_id uuid, organisation_id uuid, seller_business_id uuid, seller_name text, canonical_domain text, website_url text, created_by_user_id uuid, objective_text text, target_market_text text, hard_constraints_text text, no_hard_constraints boolean, attempt_count integer)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_id uuid;
BEGIN
  PERFORM public.marketroute_require_service_role();

  SELECT j.id INTO v_id
  FROM public.workspace_activation_jobs AS j
  WHERE ((j.status IN ('PENDING','FAILED') AND j.available_at <= p_at)
      OR (j.status = 'RUNNING' AND j.lease_expires_at < p_at))
    AND j.attempt_count < 5
  ORDER BY j.available_at, j.created_at
  FOR UPDATE SKIP LOCKED
  LIMIT 1;

  IF v_id IS NULL THEN RETURN; END IF;

  UPDATE public.workspace_activation_jobs AS j
  SET status = 'RUNNING',
      attempt_count = j.attempt_count + 1,
      worker_id = left(btrim(p_worker_id),200),
      lease_expires_at = p_at + interval '10 minutes',
      last_error_code = NULL
  WHERE j.id = v_id;

  RETURN QUERY
  SELECT j.id,j.organisation_id,j.seller_business_id,s.name,s.canonical_domain,s.website_url,
         o.created_by,j.objective_text,j.target_market_text,j.hard_constraints_text,
         j.no_hard_constraints,j.attempt_count
  FROM public.workspace_activation_jobs AS j
  JOIN public.seller_businesses AS s
    ON s.id = j.seller_business_id AND s.organisation_id = j.organisation_id
  JOIN public.organisations AS o ON o.id = j.organisation_id
  WHERE j.id = v_id;
END;
$$;

--
-- Name: marketroute_claim_workspace_activation_v2(text, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_claim_workspace_activation_v2(p_worker_id text, p_at timestamp with time zone DEFAULT now()) RETURNS TABLE(job_id uuid, organisation_id uuid, seller_business_id uuid, seller_name text, canonical_domain text, website_url text, created_by_user_id uuid, seller_offering_text text, objective_text text, target_market_text text, hard_constraints_text text, no_hard_constraints boolean, attempt_count integer)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_id uuid;
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT j.id INTO v_id FROM public.workspace_activation_jobs AS j
  WHERE ((j.status IN ('PENDING','FAILED') AND j.available_at<=p_at) OR (j.status='RUNNING' AND j.lease_expires_at<p_at))
    AND j.attempt_count<5
    AND j.seller_offering_text IS NOT NULL
  ORDER BY j.available_at,j.created_at FOR UPDATE SKIP LOCKED LIMIT 1;
  IF v_id IS NULL THEN RETURN;END IF;
  UPDATE public.workspace_activation_jobs AS j SET status='RUNNING',attempt_count=j.attempt_count+1,worker_id=left(btrim(p_worker_id),200),lease_expires_at=p_at+interval '10 minutes',last_error_code=NULL WHERE j.id=v_id;
  RETURN QUERY SELECT j.id,j.organisation_id,j.seller_business_id,s.name,s.canonical_domain,s.website_url,o.created_by,j.seller_offering_text,j.objective_text,j.target_market_text,j.hard_constraints_text,j.no_hard_constraints,j.attempt_count
    FROM public.workspace_activation_jobs AS j JOIN public.seller_businesses AS s ON s.id=j.seller_business_id AND s.organisation_id=j.organisation_id JOIN public.organisations AS o ON o.id=j.organisation_id WHERE j.id=v_id;
END;$$;

--
-- Name: marketroute_claim_workspace_activation_v3(text, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_claim_workspace_activation_v3(p_worker_id text, p_at timestamp with time zone DEFAULT now()) RETURNS TABLE(job_id uuid, organisation_id uuid, seller_business_id uuid, seller_name text, canonical_domain text, website_url text, created_by_user_id uuid, campaign_name text, seller_offering_text text, objective_text text, target_market_text text, hard_constraints_text text, no_hard_constraints boolean, attempt_count integer)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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
$$;

--
-- Name: marketroute_claim_workspace_activation_v4(text, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_claim_workspace_activation_v4(p_worker_id text, p_at timestamp with time zone DEFAULT now()) RETURNS TABLE(job_id uuid, organisation_id uuid, seller_business_id uuid, seller_name text, canonical_domain text, website_url text, created_by_user_id uuid, campaign_name text, seller_offering_text text, objective_text text, target_market_text text, hard_constraints_text text, no_hard_constraints boolean, attempt_count integer, activation_kind text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_id uuid;
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT j.id INTO v_id
  FROM public.workspace_activation_jobs j
  WHERE ((j.status IN('PENDING','FAILED') AND j.available_at<=p_at) OR (j.status='RUNNING' AND j.lease_expires_at<p_at))
    AND j.attempt_count<5
    AND j.seller_offering_text IS NOT NULL
  ORDER BY j.available_at,j.created_at,j.id
  FOR UPDATE SKIP LOCKED LIMIT 1;
  IF v_id IS NULL THEN RETURN; END IF;

  UPDATE public.workspace_activation_jobs j
  SET status='RUNNING',attempt_count=j.attempt_count+1,worker_id=left(btrim(p_worker_id),200),
      lease_expires_at=p_at+interval '10 minutes',last_error_code=NULL
  WHERE j.id=v_id;

  RETURN QUERY
  SELECT j.id,j.organisation_id,j.seller_business_id,s.name,s.canonical_domain,s.website_url,o.created_by,
         j.campaign_name,j.seller_offering_text,j.objective_text,j.target_market_text,j.hard_constraints_text,
         j.no_hard_constraints,j.attempt_count,j.activation_kind
  FROM public.workspace_activation_jobs j
  JOIN public.seller_businesses s ON s.id=j.seller_business_id AND s.organisation_id=j.organisation_id
  JOIN public.organisations o ON o.id=j.organisation_id
  WHERE j.id=v_id;
END;
$$;

--
-- Name: marketroute_complete_anonymous_discovery_extension_v1(uuid, text, jsonb, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_complete_anonymous_discovery_extension_v1(p_job_id uuid, p_worker_id text, p_result_json jsonb, p_at timestamp with time zone DEFAULT now()) RETURNS TABLE(status text, scoped_count integer, target_count integer)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_job public.anonymous_discovery_extension_jobs%ROWTYPE;v_run public.anonymous_discovery_runs%ROWTYPE;
  v_count integer;v_ready integer;v_status text;v_candidate_ceiling integer;v_budget_state text;v_budget_remaining numeric;v_terminal_reason text;
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT * INTO v_job FROM public.anonymous_discovery_extension_jobs WHERE id=p_job_id FOR UPDATE;
  IF NOT FOUND OR v_job.status<>'RUNNING' OR v_job.worker_id IS DISTINCT FROM left(btrim(COALESCE(p_worker_id,'')),200) THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_EXTENSION_LEASE_INVALID'; END IF;
  SELECT * INTO v_run FROM public.anonymous_discovery_runs WHERE id=v_job.run_id;
  SELECT count(DISTINCT s.company_id)::int INTO v_count FROM public.organisation_company_scopes s WHERE s.organisation_id=v_job.organisation_id AND s.campaign_id=v_job.campaign_id AND s.scope_kind='CAMPAIGN';
  v_ready:=public.marketroute_anonymous_discovery_ready_count_v1(v_run.id,p_at);
  v_candidate_ceiling:=LEAST(40,GREATEST(v_run.target_count,v_run.target_count*4));
  SELECT b.budget_state,b.remaining_usd INTO v_budget_state,v_budget_remaining FROM public.marketroute_anonymous_discovery_budget_state_v1(v_run.id,p_at) b;
  v_status:=CASE
    WHEN v_ready>=v_run.target_count THEN 'SUCCEEDED'
    WHEN public.marketroute_paid_entitlement_active_v1(v_run.organisation_id,p_at) THEN 'EXHAUSTED'
    WHEN v_budget_state IN('WINDOW_CLOSED','EXHAUSTED','INSUFFICIENT_FOR_WAITING_WORK') THEN 'EXHAUSTED'
    WHEN v_job.attempt_count>=3 OR v_run.research_expires_at<=p_at OR v_count>=v_candidate_ceiling THEN 'EXHAUSTED'
    ELSE 'DEFERRED'
  END;
  v_terminal_reason:=CASE
    WHEN v_status<>'EXHAUSTED' THEN NULL
    WHEN public.marketroute_paid_entitlement_active_v1(v_run.organisation_id,p_at) THEN 'MARKETROUTE_ANONYMOUS_EXTENSION_STOPPED_PAID_CONVERSION'
    WHEN v_budget_state IN('EXHAUSTED','INSUFFICIENT_FOR_WAITING_WORK') THEN 'MARKETROUTE_ANONYMOUS_EXTENSION_RESEARCH_CAPACITY_EXHAUSTED'
    WHEN v_budget_state='WINDOW_CLOSED' OR v_run.research_expires_at<=p_at THEN 'MARKETROUTE_ANONYMOUS_EXTENSION_RESEARCH_WINDOW_CLOSED'
    WHEN v_job.attempt_count>=3 THEN 'MARKETROUTE_ANONYMOUS_EXTENSION_ATTEMPT_CEILING_REACHED'
    WHEN v_count>=v_candidate_ceiling THEN 'MARKETROUTE_ANONYMOUS_EXTENSION_CANDIDATE_CEILING_REACHED'
    ELSE 'MARKETROUTE_ANONYMOUS_EXTENSION_EXHAUSTED'
  END;
  UPDATE public.anonymous_discovery_extension_jobs
  SET status=v_status,
      cycle_policy_version=4,
      worker_id=NULL,
      lease_expires_at=NULL,
      available_at=CASE WHEN v_status='DEFERRED' THEN p_at+interval '2 minutes' ELSE available_at END,
      last_error_code=v_terminal_reason,
      result_json=COALESCE(p_result_json,'{}'::jsonb) || jsonb_build_object(
        'scopedCount',v_count,
        'readyCount',v_ready,
        'readyTarget',v_run.target_count,
        'candidateCeiling',v_candidate_ceiling,
        'completedAt',p_at,
        'quotaCyclePolicyVersion',4,
        'completionMetric','AUTHORITY_READY_OPPORTUNITIES',
        'researchCycleGated',true,
        'terminallyBudgetAware',true,
        'budgetState',COALESCE(v_budget_state,'UNKNOWN'),
        'budgetRemainingUsd',v_budget_remaining,
        'terminalReason',v_terminal_reason
      )
  WHERE id=p_job_id;
  RETURN QUERY SELECT v_status,v_count,v_run.target_count;
END;
$$;

--
-- Name: marketroute_complete_engagement_delivery_v1(uuid, text, text, jsonb, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_complete_engagement_delivery_v1(p_queue_item_id uuid, p_worker_id text, p_provider_message_id text, p_provider_metadata_json jsonb, p_at timestamp with time zone DEFAULT now()) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_job public.engagement_delivery_jobs%ROWTYPE; v_queue public.engagement_queue_items%ROWTYPE; v_opp public.opportunities%ROWTYPE; v_request uuid:=gen_random_uuid();
BEGIN
 PERFORM public.marketroute_require_service_role(); IF p_at IS NULL OR abs(extract(epoch FROM(now()-p_at)))>300 THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_COMPLETE_TIME_NOT_CURRENT'; END IF; SELECT * INTO v_job FROM public.engagement_delivery_jobs WHERE queue_item_id=p_queue_item_id FOR UPDATE; IF NOT FOUND OR v_job.status<>'RUNNING' OR v_job.claimed_by IS DISTINCT FROM p_worker_id THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_DELIVERY_CLAIM_MISMATCH'; END IF;
 SELECT * INTO v_queue FROM public.engagement_queue_items WHERE id=p_queue_item_id; SELECT * INTO v_opp FROM public.opportunities WHERE id=v_queue.opportunity_id FOR UPDATE;
 UPDATE public.engagement_delivery_jobs SET status='SENT',finished_at=p_at,last_error_code=NULL WHERE id=v_job.id;
 INSERT INTO public.engagement_delivery_events(queue_item_id,job_id,event_type,worker_id,send_gate_fingerprint,provider_message_id,metadata_json,occurred_at) VALUES(v_queue.id,v_job.id,'SENT',p_worker_id,v_job.send_gate_fingerprint,NULLIF(btrim(p_provider_message_id),''),COALESCE(p_provider_metadata_json,'{}'::jsonb),p_at);
 IF v_opp.workflow_state='APPROVED' THEN
  UPDATE public.opportunities SET workflow_state='ENGAGED',updated_at=p_at WHERE id=v_opp.id;
  INSERT INTO public.opportunity_workflow_events(opportunity_id,organisation_id,event_type,prior_workflow_state,resulting_workflow_state,actor_user_id,request_id,reason_code,authority_envelope_json,authority_envelope_fingerprint,occurred_at)
  VALUES(v_opp.id,v_opp.organisation_id,'ENGAGEMENT','APPROVED','ENGAGED',NULL,v_request,'FIRST_ENGAGEMENT_DELIVERED',v_queue.authority_envelope_json,v_queue.authority_envelope_fingerprint,p_at);
 END IF;
 RETURN true;
END $$;

--
-- Name: marketroute_complete_paid_campaign_refill_v1(uuid, text, jsonb, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_complete_paid_campaign_refill_v1(p_job_id uuid, p_worker_id text, p_result_json jsonb, p_at timestamp with time zone DEFAULT now()) RETURNS TABLE(status text, scoped_count integer, target_count integer)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_job public.paid_campaign_refill_jobs%ROWTYPE;v_count integer;v_ready integer;v_status text;v_capacity jsonb;
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT * INTO v_job FROM public.paid_campaign_refill_jobs WHERE id=p_job_id FOR UPDATE;
  IF NOT FOUND OR v_job.status<>'RUNNING' OR v_job.worker_id IS DISTINCT FROM left(btrim(COALESCE(p_worker_id,'')),200) THEN RAISE EXCEPTION 'MARKETROUTE_PAID_REFILL_LEASE_INVALID'; END IF;
  SELECT count(DISTINCT s.company_id)::int INTO v_count FROM public.organisation_company_scopes s WHERE s.organisation_id=v_job.organisation_id AND s.campaign_id=v_job.campaign_id AND s.scope_kind='CAMPAIGN';
  v_ready:=public.marketroute_campaign_authority_ready_count_v1(v_job.organisation_id,v_job.campaign_id,p_at);
  v_capacity:=public.marketroute_research_capacity_snapshot_v1(v_job.organisation_id,p_at);
  v_status:=CASE
    WHEN NOT public.marketroute_paid_entitlement_active_v1(v_job.organisation_id,p_at) THEN 'EXHAUSTED'
    WHEN v_ready>=v_job.target_count THEN 'SUCCEEDED'
    WHEN v_job.attempt_count>=6 OR v_count>=v_job.candidate_ceiling THEN 'EXHAUSTED'
    ELSE 'DEFERRED' END;
  UPDATE public.paid_campaign_refill_jobs SET status=v_status,worker_id=NULL,lease_expires_at=NULL,
    available_at=CASE WHEN v_status='DEFERRED' THEN CASE WHEN COALESCE((v_capacity->>'available')::boolean,false)=false THEN COALESCE(NULLIF(v_capacity->>'periodEnd','')::timestamptz,p_at+interval '1 day') ELSE p_at+interval '2 minutes' END ELSE available_at END,
    last_error_code=CASE WHEN v_status='EXHAUSTED' AND NOT public.marketroute_paid_entitlement_active_v1(v_job.organisation_id,p_at) THEN 'MARKETROUTE_PAID_REFILL_ENTITLEMENT_INACTIVE' WHEN v_status='EXHAUSTED' AND v_job.attempt_count>=6 THEN 'MARKETROUTE_PAID_REFILL_ATTEMPT_CEILING_REACHED' WHEN v_status='EXHAUSTED' AND v_count>=v_job.candidate_ceiling THEN 'MARKETROUTE_PAID_REFILL_CANDIDATE_CEILING_REACHED' ELSE NULL END,
    result_json=COALESCE(p_result_json,'{}'::jsonb)||jsonb_build_object('scopedCount',v_count,'readyCount',v_ready,'readyTarget',v_job.target_count,'candidateCeiling',v_job.candidate_ceiling,'completedAt',p_at,'completionMetric','AUTHORITY_READY_OPPORTUNITIES','paidDemandDrivenRefill',true),updated_at=p_at
  WHERE id=p_job_id;
  RETURN QUERY SELECT v_status,v_count,v_job.target_count;
END;$$;

--
-- Name: marketroute_complete_research_work_v1(uuid, uuid, numeric, jsonb, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_complete_research_work_v1(p_work_unit_id uuid, p_scheduler_run_id uuid, p_actual_cost_usd numeric, p_metadata jsonb DEFAULT '{}'::jsonb, p_at timestamp with time zone DEFAULT now()) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_work public.research_work_units%ROWTYPE; v_job public.background_jobs%ROWTYPE;
BEGIN
 SELECT * INTO v_work FROM public.research_work_units WHERE id=p_work_unit_id; IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_WORK_NOT_FOUND'; END IF; SELECT * INTO v_job FROM public.background_jobs WHERE id=v_work.background_job_id FOR UPDATE;
 IF v_job.status<>'RUNNING' OR v_job.reserved_by_run_id IS DISTINCT FROM p_scheduler_run_id THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_WORK_NOT_OWNED'; END IF;
 IF p_actual_cost_usd<0 OR p_actual_cost_usd>v_work.cost_ceiling_usd THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_ACTUAL_COST_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM public.research_budget_events WHERE work_unit_id=v_work.id AND attempt_number=v_job.attempt_count AND event_type IN('COMMIT','RELEASE')) THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_WORK_ALREADY_SETTLED'; END IF;
 INSERT INTO public.research_budget_events(organisation_id,campaign_id,work_unit_id,scheduler_run_id,attempt_number,event_type,amount_usd,occurred_at,metadata_json) VALUES(v_work.organisation_id,v_work.campaign_id,v_work.id,p_scheduler_run_id,v_job.attempt_count,'COMMIT',p_actual_cost_usd,p_at,COALESCE(p_metadata,'{}'::jsonb));
 UPDATE public.background_jobs SET status='SUCCEEDED',reserved_by_run_id=NULL,reserved_at=NULL,updated_at=p_at WHERE id=v_job.id;
 UPDATE public.background_job_attempts SET status='SUCCEEDED',completed_at=p_at,telemetry_json=COALESCE(p_metadata,'{}'::jsonb) WHERE job_id=v_job.id AND attempt_number=v_job.attempt_count AND status='RUNNING';
END $$;

--
-- Name: marketroute_complete_workspace_activation_v1(uuid, text, jsonb, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_complete_workspace_activation_v1(p_job_id uuid, p_worker_id text, p_result_json jsonb, p_at timestamp with time zone DEFAULT now()) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$ BEGIN PERFORM public.marketroute_require_service_role();UPDATE public.workspace_activation_jobs SET status='SUCCEEDED',worker_id=NULL,lease_expires_at=NULL,result_json=COALESCE(p_result_json,'{}'::jsonb),last_error_code=NULL WHERE id=p_job_id AND status='RUNNING' AND worker_id=p_worker_id;IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_ACTIVATION_LEASE_MISMATCH';END IF;END;$$;

--
-- Name: marketroute_conversation_cache_get_v1(text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_conversation_cache_get_v1(p_scope_kind text, p_scope_key text, p_input_fingerprint text, p_contract_version text) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_row public.marketroute_conversation_narration_cache%ROWTYPE;
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT * INTO v_row
  FROM public.marketroute_conversation_narration_cache
  WHERE scope_kind=p_scope_kind
    AND scope_key=p_scope_key
    AND input_fingerprint=p_input_fingerprint
    AND contract_version=p_contract_version
    AND expires_at>now()
  ORDER BY created_at DESC
  LIMIT 1;
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN jsonb_build_object(
    'payload',v_row.payload_json,
    'model',v_row.model,
    'createdAt',v_row.created_at,
    'expiresAt',v_row.expires_at
  );
END;
$$;

--
-- Name: marketroute_conversation_cache_put_v1(text, text, text, text, jsonb, text, uuid, uuid, uuid, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_conversation_cache_put_v1(p_scope_kind text, p_scope_key text, p_input_fingerprint text, p_contract_version text, p_payload_json jsonb, p_model text, p_organisation_id uuid DEFAULT NULL::uuid, p_campaign_id uuid DEFAULT NULL::uuid, p_company_id uuid DEFAULT NULL::uuid, p_ttl_hours integer DEFAULT 72) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF p_scope_kind NOT IN ('DISCOVERY_PROGRESS','COMMAND_CENTRE','CAMPAIGN_OVERVIEW','OPPORTUNITY_SUMMARY','OPPORTUNITY_QA') THEN RAISE EXCEPTION 'MARKETROUTE_CONVERSATION_SCOPE_INVALID'; END IF;
  IF length(btrim(COALESCE(p_scope_key,''))) NOT BETWEEN 1 AND 240 THEN RAISE EXCEPTION 'MARKETROUTE_CONVERSATION_SCOPE_KEY_INVALID'; END IF;
  IF COALESCE(p_input_fingerprint,'') !~ '^[a-f0-9]{64}$' THEN RAISE EXCEPTION 'MARKETROUTE_CONVERSATION_FINGERPRINT_INVALID'; END IF;
  IF COALESCE(p_payload_json->>'contractVersion','')<>p_contract_version OR COALESCE(p_payload_json->>'scope','')<>p_scope_kind OR COALESCE(p_payload_json->>'sourceFingerprint','')<>p_input_fingerprint THEN RAISE EXCEPTION 'MARKETROUTE_CONVERSATION_PAYLOAD_LINEAGE_INVALID'; END IF;
  IF jsonb_typeof(p_payload_json->'known') IS DISTINCT FROM 'array' OR jsonb_typeof(p_payload_json->'uncertainties') IS DISTINCT FROM 'array' OR jsonb_typeof(p_payload_json->'evidenceReferences') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'MARKETROUTE_CONVERSATION_PAYLOAD_SHAPE_INVALID'; END IF;
  IF pg_column_size(p_payload_json)>32768 THEN RAISE EXCEPTION 'MARKETROUTE_CONVERSATION_PAYLOAD_TOO_LARGE'; END IF;
  IF p_ttl_hours<1 OR p_ttl_hours>720 THEN RAISE EXCEPTION 'MARKETROUTE_CONVERSATION_TTL_INVALID'; END IF;
  INSERT INTO public.marketroute_conversation_narration_cache(
    scope_kind,scope_key,input_fingerprint,contract_version,payload_json,model,organisation_id,campaign_id,company_id,created_at,expires_at
  ) VALUES(
    p_scope_kind,btrim(p_scope_key),p_input_fingerprint,p_contract_version,p_payload_json,btrim(p_model),p_organisation_id,p_campaign_id,p_company_id,now(),now()+make_interval(hours=>p_ttl_hours)
  )
  ON CONFLICT(scope_kind,scope_key,input_fingerprint,contract_version) DO UPDATE
  SET payload_json=EXCLUDED.payload_json,
      model=EXCLUDED.model,
      organisation_id=EXCLUDED.organisation_id,
      campaign_id=EXCLUDED.campaign_id,
      company_id=EXCLUDED.company_id,
      created_at=now(),
      expires_at=EXCLUDED.expires_at;
END;
$_$;

--
-- Name: marketroute_create_activation_campaign_v1(uuid, uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_create_activation_campaign_v1(p_organisation_id uuid, p_seller_business_id uuid, p_objective_text text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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
$$;

--
-- Name: marketroute_create_activation_campaign_v2(uuid, uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_create_activation_campaign_v2(p_organisation_id uuid, p_seller_business_id uuid, p_campaign_name text, p_objective_text text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_id uuid;v_user uuid;v_kind text;v_name text:=COALESCE(nullif(btrim(p_campaign_name),''),'Initial market research');
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF length(v_name) NOT BETWEEN 3 AND 120 THEN RAISE EXCEPTION 'MARKETROUTE_CAMPAIGN_NAME_REQUIRED'; END IF;
  SELECT created_by,workspace_kind INTO v_user,v_kind FROM public.organisations WHERE id=p_organisation_id FOR UPDATE;
  IF v_kind IS NULL OR NOT EXISTS(SELECT 1 FROM public.seller_businesses WHERE id=p_seller_business_id AND organisation_id=p_organisation_id AND lifecycle_state='ACTIVE') THEN RAISE EXCEPTION 'MARKETROUTE_ACTIVATION_SCOPE_INVALID'; END IF;
  IF (v_kind='CUSTOMER' AND v_user IS NULL) OR (v_kind='ANONYMOUS_DISCOVERY' AND v_user IS NOT NULL) THEN RAISE EXCEPTION 'MARKETROUTE_ACTIVATION_CREATOR_SCOPE_INVALID'; END IF;
  SELECT id INTO v_id FROM public.campaigns WHERE organisation_id=p_organisation_id AND seller_business_id=p_seller_business_id AND workflow_state<>'ARCHIVED' ORDER BY created_at LIMIT 1;
  IF v_id IS NULL THEN
    INSERT INTO public.campaigns(organisation_id,seller_business_id,name,workflow_state,objective_text,created_by)
    VALUES(p_organisation_id,p_seller_business_id,v_name,'ACTIVE',btrim(p_objective_text),v_user) RETURNING id INTO v_id;
  ELSE
    UPDATE public.campaigns SET name=v_name,workflow_state='ACTIVE',objective_text=btrim(p_objective_text),updated_at=now() WHERE id=v_id;
  END IF;
  RETURN v_id;
END;
$$;

--
-- Name: marketroute_create_activation_campaign_v3(uuid, uuid, uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_create_activation_campaign_v3(p_job_id uuid, p_organisation_id uuid, p_seller_business_id uuid, p_campaign_name text, p_objective_text text) RETURNS uuid
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
  SELECT public.marketroute_create_activation_campaign_v4($1,$2,$3,$4,$5);
$_$;

--
-- Name: marketroute_create_activation_campaign_v4(uuid, uuid, uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_create_activation_campaign_v4(p_job_id uuid, p_organisation_id uuid, p_seller_business_id uuid, p_campaign_name text, p_objective_text text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_job public.workspace_activation_jobs%ROWTYPE;
  v_id uuid;v_user uuid;
  v_name text:=COALESCE(nullif(btrim(p_campaign_name),''),'Initial market research');
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF length(v_name) NOT BETWEEN 3 AND 120 THEN RAISE EXCEPTION 'MARKETROUTE_CAMPAIGN_NAME_REQUIRED'; END IF;

  SELECT * INTO v_job FROM public.workspace_activation_jobs j
  WHERE j.id=p_job_id AND j.organisation_id=p_organisation_id AND j.seller_business_id=p_seller_business_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_ACTIVATION_JOB_SCOPE_INVALID'; END IF;

  SELECT c.id INTO v_id
  FROM public.campaigns c
  WHERE c.activation_job_id=p_job_id AND c.organisation_id=p_organisation_id;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;

  IF nullif(v_job.result_json->>'campaignId','') IS NOT NULL THEN
    BEGIN v_id:=(v_job.result_json->>'campaignId')::uuid; EXCEPTION WHEN invalid_text_representation THEN v_id:=NULL; END;
    IF v_id IS NOT NULL AND EXISTS(SELECT 1 FROM public.campaigns c WHERE c.id=v_id AND c.organisation_id=p_organisation_id) THEN
      UPDATE public.campaigns c SET activation_job_id=p_job_id WHERE c.id=v_id AND c.activation_job_id IS NULL;
      IF EXISTS(SELECT 1 FROM public.campaigns c WHERE c.id=v_id AND c.activation_job_id=p_job_id) THEN RETURN v_id; END IF;
      RAISE EXCEPTION 'MARKETROUTE_ACTIVATION_CAMPAIGN_LINEAGE_CONFLICT';
    END IF;
  END IF;

  SELECT o.created_by INTO v_user FROM public.organisations o
  WHERE o.id=p_organisation_id AND o.status='ACTIVE' FOR UPDATE;
  IF NOT FOUND OR NOT EXISTS(
    SELECT 1 FROM public.seller_businesses s
    WHERE s.id=p_seller_business_id AND s.organisation_id=p_organisation_id AND s.lifecycle_state='ACTIVE'
  ) THEN RAISE EXCEPTION 'MARKETROUTE_ACTIVATION_SCOPE_INVALID'; END IF;

  INSERT INTO public.campaigns(
    organisation_id,seller_business_id,name,workflow_state,objective_text,created_by,activation_job_id
  ) VALUES(
    p_organisation_id,p_seller_business_id,v_name,'ACTIVE',btrim(p_objective_text),v_user,p_job_id
  ) RETURNING id INTO v_id;

  UPDATE public.workspace_activation_jobs
  SET result_json=COALESCE(result_json,'{}'::jsonb)||jsonb_build_object('campaignId',v_id),updated_at=now()
  WHERE id=p_job_id;

  IF v_job.activation_kind='ANONYMOUS_DISCOVERY' THEN
    UPDATE public.anonymous_discovery_runs r
    SET original_campaign_id=COALESCE(r.original_campaign_id,v_id),updated_at=now()
    WHERE r.activation_job_id=p_job_id AND r.organisation_id=p_organisation_id;
  END IF;
  RETURN v_id;
END;
$$;

--
-- Name: marketroute_create_anonymous_discovery_v1(text, text, text, text, text, text, text, numeric, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_create_anonymous_discovery_v1(p_browser_key_hash text, p_ip_hash text, p_company_name text, p_website_url text, p_seller_offering_text text, p_target_market_text text, p_objective_text text, p_lifetime_budget_usd numeric, p_research_window_hours integer, p_target_count integer) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp', 'extensions'
    AS $_$
DECLARE
  v_existing public.anonymous_discovery_runs%ROWTYPE;
  v_org uuid:=gen_random_uuid();v_seller uuid:=gen_random_uuid();v_job uuid:=gen_random_uuid();v_slug text;
  v_name text:=btrim(COALESCE(p_company_name,''));v_url text:=btrim(COALESCE(p_website_url,''));v_host text;
  v_offering text:=btrim(COALESCE(p_seller_offering_text,''));v_target text:=btrim(COALESCE(p_target_market_text,''));v_objective text:=btrim(COALESCE(p_objective_text,''));
  v_budget numeric:=LEAST(1.00::numeric,GREATEST(0.50::numeric,round(COALESCE(p_lifetime_budget_usd,1.00)::numeric,8)));
  v_hours integer:=LEAST(12,GREATEST(1,COALESCE(p_research_window_hours,12)));
  v_target_count integer:=LEAST(10,GREATEST(8,COALESCE(p_target_count,10)));v_run uuid;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF COALESCE(p_browser_key_hash,'') !~ '^[a-f0-9]{64}$' OR COALESCE(p_ip_hash,'') !~ '^[a-f0-9]{64}$' THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_HASH_INVALID'; END IF;
  SELECT * INTO v_existing FROM public.anonymous_discovery_runs WHERE browser_key_hash=p_browser_key_hash;
  IF FOUND THEN RETURN jsonb_build_object('runId',v_existing.id,'existing',true); END IF;
  IF (SELECT count(*) FROM public.anonymous_discovery_runs WHERE ip_hash=p_ip_hash AND created_at>=now()-interval '24 hours')>=5 THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_IP_LIMIT'; END IF;
  IF length(v_name) NOT BETWEEN 2 AND 160 THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_COMPANY_NAME_REQUIRED'; END IF;
  IF v_url !~ '^https?://[^/]+\.[^/]+' THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_WEBSITE_INVALID'; END IF;
  v_host:=lower(regexp_replace(split_part(regexp_replace(v_url,'^https?://','','i'),'/',1),'^www\.','','i'));
  IF v_host !~ '^[a-z0-9][a-z0-9.-]*\.[a-z]{2,63}$' THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_WEBSITE_INVALID'; END IF;
  IF length(v_offering) NOT BETWEEN 8 AND 2000 THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_OFFERING_REQUIRED'; END IF;
  IF length(v_target) NOT BETWEEN 3 AND 2000 OR length(v_objective) NOT BETWEEN 8 AND 2000 THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_BRIEF_INVALID'; END IF;
  IF v_budget<0.50 OR v_budget>1.00 OR v_hours<1 OR v_hours>12 OR v_target_count<8 OR v_target_count>10 THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_POLICY_INVALID'; END IF;
  v_slug:='anon-'||left(replace(v_org::text,'-',''),20);
  INSERT INTO public.organisations(id,name,slug,status,workspace_kind,created_by) VALUES(v_org,v_name,v_slug,'ACTIVE','ANONYMOUS_DISCOVERY',NULL);
  INSERT INTO public.seller_businesses(id,organisation_id,name,canonical_domain,website_url,lifecycle_state,created_by) VALUES(v_seller,v_org,v_name,v_host,v_url,'ACTIVE',NULL);
  INSERT INTO public.workspace_activation_jobs(
    id,organisation_id,seller_business_id,campaign_name,seller_offering_text,objective_text,target_market_text,
    hard_constraints_text,no_hard_constraints,status,attempt_count,available_at,worker_id,lease_expires_at,last_error_code,result_json,
    activation_stage,activation_progress,activation_stage_detail_json,activation_kind
  ) VALUES(
    v_job,v_org,v_seller,'MarketRoute discovery',v_offering,v_objective,v_target,NULL,true,'PENDING',0,now(),NULL,NULL,NULL,'{}'::jsonb,
    'QUEUED',0,'{}'::jsonb,'ANONYMOUS_DISCOVERY'
  );
  INSERT INTO public.anonymous_discovery_runs(browser_key_hash,ip_hash,organisation_id,seller_business_id,activation_job_id,company_name,website_url,lifetime_budget_usd,target_count,research_expires_at,status,objective_text,target_market_text)
  VALUES(p_browser_key_hash,p_ip_hash,v_org,v_seller,v_job,v_name,v_url,v_budget,v_target_count,now()+make_interval(hours=>v_hours),'ACTIVE',v_objective,v_target)
  RETURNING id INTO v_run;
  RETURN jsonb_build_object('runId',v_run,'existing',false);
END;
$_$;

--
-- Name: marketroute_create_engagement_strategy_v1(uuid, text, uuid, text, text, text, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_create_engagement_strategy_v1(p_opportunity_id uuid, p_path_fingerprint text, p_request_id uuid, p_context_fingerprint text, p_strategy_fingerprint text, p_strategy_version text, p_at timestamp with time zone DEFAULT now()) RETURNS TABLE(strategy_id uuid, strategy_fingerprint text, channel_kind text, deduplicated boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_existing public.engagement_strategies%ROWTYPE; v_ctx jsonb; v_ctxfp text; v_channel text; v_expected text; v_id uuid;
BEGIN
 PERFORM public.marketroute_require_service_role(); IF p_request_id IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_STRATEGY_REQUEST_ID_REQUIRED'; END IF;
 SELECT * INTO v_existing FROM public.engagement_strategies WHERE request_id=p_request_id;
 IF FOUND THEN
  IF v_existing.opportunity_id IS DISTINCT FROM p_opportunity_id OR v_existing.path_fingerprint IS DISTINCT FROM p_path_fingerprint OR v_existing.generation_context_fingerprint IS DISTINCT FROM p_context_fingerprint OR v_existing.strategy_fingerprint IS DISTINCT FROM p_strategy_fingerprint THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_STRATEGY_IDEMPOTENCY_COLLISION'; END IF;
  RETURN QUERY SELECT v_existing.id,v_existing.strategy_fingerprint,v_existing.channel_kind,true; RETURN;
 END IF;
 IF p_strategy_version<>'MRV2-ENGAGEMENT-STRATEGY-1.0.0' THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_STRATEGY_VERSION_MISMATCH'; END IF;
 v_ctx:=public.marketroute_engagement_generation_context_v1(p_opportunity_id,p_path_fingerprint,p_at); v_ctxfp:=public.marketroute_engagement_generation_context_fingerprint_v1(v_ctx);
 IF p_context_fingerprint IS DISTINCT FROM v_ctxfp THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_GENERATION_CONTEXT_CHANGED'; END IF;
 v_channel:=public.marketroute_engagement_channel_kind_v1(v_ctx->>'accessPointKind'); v_expected:=public.marketroute_engagement_strategy_fingerprint_v1(v_ctx,v_channel);
 IF p_strategy_fingerprint IS DISTINCT FROM v_expected THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_STRATEGY_FINGERPRINT_MISMATCH'; END IF;
 INSERT INTO public.engagement_strategies(request_id,opportunity_id,organisation_id,campaign_id,company_id,path_fingerprint,access_point_id,access_point_kind,access_point_value,route_mode,person_id,channel_kind,strategy_version,generation_context_fingerprint,authority_envelope_fingerprint,r6_authority_record_id,r6_authority_fingerprint,strategy_fingerprint,created_at)
 VALUES(p_request_id,p_opportunity_id,(v_ctx->>'organisationId')::uuid,(v_ctx->>'campaignId')::uuid,(v_ctx->>'companyId')::uuid,p_path_fingerprint,(v_ctx->>'accessPointId')::uuid,v_ctx->>'accessPointKind',v_ctx->>'accessPointValue',v_ctx->>'routeMode',NULLIF(v_ctx->>'personId','')::uuid,v_channel,p_strategy_version,v_ctxfp,v_ctx->>'authorityEnvelopeFingerprint',(v_ctx->>'r6AuthorityRecordId')::uuid,v_ctx->>'r6AuthorityFingerprint',v_expected,p_at) RETURNING id INTO v_id;
 RETURN QUERY SELECT v_id,v_expected,v_channel,false;
END $$;

--
-- Name: marketroute_create_organisation(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_create_organisation(p_name text, p_slug text, p_actor_user_id uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_user_id uuid := p_actor_user_id;
  v_organisation_id uuid;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'MARKETROUTE_AUTH_REQUIRED';
  END IF;

  INSERT INTO public.organisations(name, slug, created_by)
  VALUES (btrim(p_name), lower(btrim(p_slug)), v_user_id)
  RETURNING id INTO v_organisation_id;

  INSERT INTO public.organisation_memberships(organisation_id, user_id, role, status)
  VALUES (v_organisation_id, v_user_id, 'OWNER', 'ACTIVE');

  RETURN v_organisation_id;
END;
$$;

--
-- Name: marketroute_create_workspace_with_seller_v1(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_create_workspace_with_seller_v1(p_name text, p_website_url text, p_actor_user_id uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
DECLARE
  v_user_id uuid := p_actor_user_id;
  v_name text := btrim(COALESCE(p_name, ''));
  v_website_url text := btrim(COALESCE(p_website_url, ''));
  v_host text;
  v_base_slug text;
  v_slug text;
  v_suffix text;
  v_organisation_id uuid;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'MARKETROUTE_AUTH_REQUIRED';
  END IF;

  IF length(v_name) < 1 OR length(v_name) > 160 THEN
    RAISE EXCEPTION 'MARKETROUTE_WORKSPACE_NAME_WEBSITE_REQUIRED';
  END IF;

  IF v_website_url !~* '^https?://[^[:space:]]+$' THEN
    RAISE EXCEPTION 'MARKETROUTE_WORKSPACE_WEBSITE_INVALID';
  END IF;

  v_host := lower(split_part(regexp_replace(v_website_url, '^https?://', '', 'i'), '/', 1));
  v_host := split_part(v_host, ':', 1);
  v_host := regexp_replace(v_host, '^www\.', '', 'i');

  IF v_host !~ '^[a-z0-9][a-z0-9.-]*\.[a-z]{2,63}$' THEN
    RAISE EXCEPTION 'MARKETROUTE_WORKSPACE_WEBSITE_INVALID';
  END IF;

  -- Slugs are internal implementation details in V2. Generate one from the
  -- organisation name and add a short suffix only when the natural slug exists.
  v_base_slug := lower(regexp_replace(v_name, '[^a-zA-Z0-9]+', '-', 'g'));
  v_base_slug := btrim(v_base_slug, '-');
  IF length(v_base_slug) < 2 THEN
    v_base_slug := 'workspace';
  END IF;
  v_base_slug := left(v_base_slug, 56);
  v_slug := v_base_slug;

  IF EXISTS (SELECT 1 FROM public.organisations o WHERE o.slug = v_slug) THEN
    LOOP
      v_suffix := '-' || left(replace(gen_random_uuid()::text, '-', ''), 6);
      v_slug := left(v_base_slug, 63 - length(v_suffix)) || v_suffix;
      EXIT WHEN NOT EXISTS (SELECT 1 FROM public.organisations o WHERE o.slug = v_slug);
    END LOOP;
  END IF;

  INSERT INTO public.organisations(name, slug, created_by)
  VALUES (v_name, v_slug, v_user_id)
  RETURNING id INTO v_organisation_id;

  INSERT INTO public.organisation_memberships(organisation_id, user_id, role, status)
  VALUES (v_organisation_id, v_user_id, 'OWNER', 'ACTIVE');

  INSERT INTO public.seller_businesses(
    organisation_id,
    name,
    canonical_domain,
    website_url,
    lifecycle_state,
    created_by
  )
  VALUES (
    v_organisation_id,
    v_name,
    v_host,
    v_website_url,
    'ACTIVE',
    v_user_id
  );

  RETURN v_organisation_id;
END;
$_$;

--
-- Name: marketroute_current_engagement_policy_v1(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_current_engagement_policy_v1(p_organisation_id uuid, p_campaign_id uuid) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
 SELECT COALESCE((SELECT e.policy_mode FROM public.campaign_engagement_policy_events e WHERE e.organisation_id=p_organisation_id AND e.campaign_id=p_campaign_id ORDER BY e.occurred_at DESC,e.id DESC LIMIT 1),'HUMAN_ONLY');
$$;

--
-- Name: marketroute_discovery_campaign_archive_guard_v1(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_discovery_campaign_archive_guard_v1() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
  IF OLD.workflow_state IS DISTINCT FROM 'ARCHIVED' AND NEW.workflow_state='ARCHIVED' THEN
    UPDATE public.anonymous_discovery_runs r
    SET research_expires_at=GREATEST(r.created_at+interval '1 second',LEAST(r.research_expires_at,now())),updated_at=now()
    WHERE r.original_campaign_id=NEW.id AND r.organisation_id=NEW.organisation_id AND r.status IN('ACTIVE','CLAIMED');
    UPDATE public.anonymous_discovery_extension_jobs j
    SET status='EXHAUSTED',worker_id=NULL,lease_expires_at=NULL,last_error_code='MARKETROUTE_DISCOVERY_ORIGINAL_CAMPAIGN_ARCHIVED',updated_at=now()
    WHERE j.campaign_id=NEW.id AND j.organisation_id=NEW.organisation_id AND j.status IN('PENDING','RUNNING','DEFERRED','SUCCEEDED');
  END IF;
  RETURN NEW;
END;$$;

--
-- Name: marketroute_discovery_free_access_v1(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_discovery_free_access_v1(p_organisation_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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
$$;

--
-- Name: marketroute_enforce_declared_authority_writer(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_enforce_declared_authority_writer() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_writer_key text := current_setting('marketroute.authority_writer', true);
  v_expected_writer text;
  v_run_org uuid;
  v_run_campaign uuid;
  v_run_input_fingerprint text;
BEGIN
  IF v_writer_key IS NULL OR btrim(v_writer_key) = '' THEN
    RAISE EXCEPTION 'MARKETROUTE_UNDECLARED_AUTHORITY_WRITE';
  END IF;

  IF TG_TABLE_NAME = 'authority_records' THEN
    v_expected_writer := NEW.writer_key;
  ELSE
    v_expected_writer := NEW.writer_key;
  END IF;

  IF v_expected_writer IS DISTINCT FROM v_writer_key THEN
    RAISE EXCEPTION 'MARKETROUTE_AUTHORITY_WRITER_CONTEXT_MISMATCH';
  END IF;

  IF TG_TABLE_NAME = 'authority_records' THEN
    IF NOT EXISTS (
      SELECT 1
      FROM public.authority_writer_registry r
      WHERE r.writer_key = v_writer_key
        AND r.enabled = true
        AND r.authority_stage = NEW.authority_stage
        AND r.writer_version = NEW.writer_version
    ) THEN
      RAISE EXCEPTION 'MARKETROUTE_AUTHORITY_WRITER_CONTRACT_MISMATCH';
    END IF;

    SELECT organisation_id, campaign_id, input_fingerprint
    INTO v_run_org, v_run_campaign, v_run_input_fingerprint
    FROM public.reasoning_runs
    WHERE id = NEW.reasoning_run_id;

    IF v_run_org IS DISTINCT FROM NEW.organisation_id
       OR v_run_campaign IS DISTINCT FROM NEW.campaign_id
       OR v_run_input_fingerprint IS DISTINCT FROM NEW.input_fingerprint THEN
      RAISE EXCEPTION 'MARKETROUTE_AUTHORITY_REASONING_LINEAGE_MISMATCH';
    END IF;
  ELSE
    IF NOT EXISTS (
      SELECT 1
      FROM public.authority_writer_registry r
      JOIN public.authority_records a ON a.id = NEW.authority_record_id
      WHERE r.writer_key = v_writer_key
        AND r.enabled = true
        AND r.authority_stage = a.authority_stage
    ) THEN
      RAISE EXCEPTION 'MARKETROUTE_AUTHORITY_EVENT_WRITER_CONTRACT_MISMATCH';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

--
-- Name: marketroute_enforce_workspace_creator_v1(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_enforce_workspace_creator_v1() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_kind text;
BEGIN
  SELECT workspace_kind INTO v_kind
  FROM public.organisations
  WHERE id=NEW.organisation_id;
  IF v_kind IS NULL THEN
    RAISE EXCEPTION 'MARKETROUTE_WORKSPACE_NOT_FOUND';
  END IF;
  IF v_kind='CUSTOMER' AND NEW.created_by IS NULL THEN
    RAISE EXCEPTION 'MARKETROUTE_CUSTOMER_CREATOR_REQUIRED';
  END IF;
  IF v_kind='ANONYMOUS_DISCOVERY' AND NEW.created_by IS NOT NULL THEN
    RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_CREATOR_FORBIDDEN';
  END IF;
  RETURN NEW;
END;
$$;

--
-- Name: marketroute_engagement_authority_snapshot_fingerprint_v1(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_engagement_authority_snapshot_fingerprint_v1(p_envelope jsonb) RETURNS text
    LANGUAGE sql IMMUTABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  SELECT encode(
    extensions.digest(
      'MRV2-ENGAGEMENT-AUTHORITY-SNAPSHOT-1.0.0|' ||
      (COALESCE(p_envelope,'{}'::jsonb) - 'evaluatedAt')::text,
      'sha256'
    ),
    'hex'
  );
$$;

--
-- Name: marketroute_engagement_channel_kind_v1(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_engagement_channel_kind_v1(p_access_point_kind text) RETURNS text
    LANGUAGE sql IMMUTABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
 SELECT CASE p_access_point_kind
  WHEN 'GENERIC_EMAIL' THEN 'EMAIL' WHEN 'DEPARTMENT_EMAIL' THEN 'EMAIL' WHEN 'PERSONAL_EMAIL' THEN 'EMAIL'
  WHEN 'CONTACT_FORM' THEN 'CONTACT_FORM' WHEN 'DEPARTMENT_FORM' THEN 'CONTACT_FORM'
  WHEN 'LINKEDIN' THEN 'LINKEDIN'
  WHEN 'SWITCHBOARD' THEN 'PHONE' WHEN 'PERSONAL_PHONE' THEN 'PHONE'
  WHEN 'OTHER' THEN 'OTHER' ELSE NULL END;
$$;

--
-- Name: marketroute_engagement_generation_context_fingerprint_v1(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_engagement_generation_context_fingerprint_v1(p_context jsonb) RETURNS text
    LANGUAGE sql IMMUTABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  SELECT encode(
    extensions.digest(
      'MRV2-ENGAGEMENT-GENERATION-CONTEXT-1.0.2|' ||
      (COALESCE(p_context,'{}'::jsonb) - 'evaluatedAt')::text,
      'sha256'
    ),
    'hex'
  );
$$;

--
-- Name: marketroute_engagement_generation_context_v1(uuid, text, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_engagement_generation_context_v1(p_opportunity_id uuid, p_path_fingerprint text, p_at timestamp with time zone DEFAULT now()) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
DECLARE
 v_opp public.opportunities%ROWTYPE; v_company public.companies%ROWTYPE; v_env jsonb; v_envfp text;
 v_r4 public.commercial_reality_r4_records%ROWTYPE; v_r6 public.contact_authority_r6_records%ROWTYPE; v_a6 public.authority_records%ROWTYPE; v_r5 public.route_authority_r5_records%ROWTYPE;
 v_binding jsonb; v_path jsonb; v_node public.commercial_graph_nodes%ROWTYPE; v_person public.people%ROWTYPE; v_seller jsonb;
 v_objective text; v_objective_statement text; v_offering_keys jsonb:='[]'::jsonb; v_offering_labels jsonb:='[]'::jsonb; v_offering_summaries jsonb:='[]'::jsonb; v_boundary_facts jsonb:='[]'::jsonb; v_channel text;
BEGIN
 PERFORM public.marketroute_require_service_role();
 IF p_at IS NULL OR abs(extract(epoch FROM(now()-p_at)))>300 THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_CONTEXT_TIME_NOT_CURRENT'; END IF;
 IF p_path_fingerprint IS NULL OR p_path_fingerprint !~ '^[a-f0-9]{64}$' THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_PATH_FINGERPRINT_INVALID'; END IF;
 SELECT * INTO v_opp FROM public.opportunities WHERE id=p_opportunity_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_OPPORTUNITY_NOT_FOUND'; END IF;
 IF NOT EXISTS(
   SELECT 1 FROM public.organisations o
   JOIN public.campaigns c ON c.organisation_id=o.id AND c.id=v_opp.campaign_id
   JOIN public.seller_businesses sb ON sb.organisation_id=c.organisation_id AND sb.id=c.seller_business_id
   WHERE o.id=v_opp.organisation_id AND o.status='ACTIVE' AND c.workflow_state='ACTIVE' AND sb.lifecycle_state='ACTIVE'
 ) THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_ACTIVE_COMMERCIAL_CONTEXT_REQUIRED'; END IF;
 IF v_opp.workflow_state NOT IN('REVIEWABLE','APPROVED') THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_REQUIRES_READY_OPPORTUNITY'; END IF;
 IF NOT public.marketroute_opportunity_executable_now_v1(v_opp.id,p_at) THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_REQUIRES_CURRENT_AUTHORITY'; END IF;
 SELECT * INTO v_company FROM public.companies WHERE id=v_opp.company_id;
 IF NOT FOUND OR v_company.lifecycle_state<>'ACTIVE' THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_ACTIVE_TARGET_COMPANY_REQUIRED'; END IF;
 v_env:=public.marketroute_authority_envelope_v1(v_opp.organisation_id,v_opp.campaign_id,v_opp.company_id,p_at); v_envfp:=public.marketroute_engagement_authority_snapshot_fingerprint_v1(v_env);
 SELECT r.* INTO v_r4 FROM public.commercial_reality_r4_records r WHERE r.authority_record_id=(v_env->'r4'->>'authorityRecordId')::uuid;
 IF NOT FOUND OR v_r4.decision_code<>'COMMERCIAL_CANDIDATE' THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_CURRENT_R4_REQUIRED'; END IF;
 SELECT COALESCE(jsonb_agg(jsonb_build_object('boundaryKey',b.value->>'boundaryKey','claimKey',b.value->>'claimKey','observedValue',b.value->>'observedValue') ORDER BY b.value->>'boundaryKey'),'[]'::jsonb) INTO v_boundary_facts
 FROM jsonb_array_elements(v_r4.boundaries_json) b(value)
 WHERE b.value->>'state'='SATISFIED' AND NULLIF(b.value->>'claimKey','') IS NOT NULL AND NULLIF(b.value->>'observedValue','') IS NOT NULL;
 SELECT r.* INTO v_r6 FROM public.contact_authority_r6_records r WHERE r.authority_record_id=(v_env->'r6'->>'authorityRecordId')::uuid;
 IF NOT FOUND OR v_r6.decision_code<>'CONTACT_AUTHORISED' THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_CURRENT_R6_REQUIRED'; END IF;
 SELECT * INTO v_a6 FROM public.authority_records WHERE id=v_r6.authority_record_id;
 SELECT r.* INTO v_r5 FROM public.route_authority_r5_records r WHERE r.authority_record_id=v_r6.parent_r5_authority_record_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_PARENT_R5_NOT_FOUND'; END IF;
 SELECT b.value INTO v_binding FROM jsonb_array_elements(v_r6.bindings_json) b(value) WHERE b.value->>'pathFingerprint'=p_path_fingerprint AND b.value->>'authorityState'='AUTHORISED' LIMIT 1;
 IF v_binding IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_PATH_NOT_R6_AUTHORISED'; END IF;
 SELECT p.value INTO v_path FROM jsonb_array_elements(v_r5.paths_json) p(value) WHERE p.value->>'pathFingerprint'=p_path_fingerprint LIMIT 1;
 IF v_path IS NULL OR v_path->>'terminalAccessPointId' IS DISTINCT FROM v_binding->>'terminalAccessPointId' THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_R5_R6_PATH_MISMATCH'; END IF;
 SELECT * INTO v_node FROM public.commercial_graph_nodes WHERE id=(v_binding->>'terminalAccessPointId')::uuid AND node_kind='ACCESS_POINT';
 IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_ACCESS_POINT_NOT_FOUND'; END IF;
 v_channel:=public.marketroute_engagement_channel_kind_v1(v_node.access_point_kind); IF v_channel IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_ACCESS_POINT_KIND_UNSUPPORTED'; END IF;
 IF NULLIF(v_binding->>'personId','') IS NOT NULL THEN SELECT * INTO v_person FROM public.people WHERE id=(v_binding->>'personId')::uuid AND lifecycle_state='ACTIVE'; IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_PERSON_NOT_ACTIVE'; END IF; END IF;
 v_seller:=public.marketroute_get_current_campaign_seller_context_v1(v_opp.organisation_id,v_opp.campaign_id); IF v_seller IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_SELLER_CONTEXT_REQUIRED'; END IF;
 v_objective:=v_seller->>'objectiveKey';
 SELECT e.value->>'statement' INTO v_objective_statement FROM jsonb_array_elements(COALESCE(v_seller->'canonicalGenome'->'explanatory'->'objectiveCopy','[]'::jsonb)) e(value) WHERE e.value->>'objectiveKey'=v_objective LIMIT 1;
 SELECT COALESCE(o.value->'offeringKeys','[]'::jsonb) INTO v_offering_keys FROM jsonb_array_elements(COALESCE(v_seller->'canonicalGenome'->'semantic'->'commercialObjectives'->'items','[]'::jsonb)) o(value) WHERE o.value->>'objectiveKey'=v_objective LIMIT 1;
 SELECT COALESCE(jsonb_agg(c.value->>'label' ORDER BY c.value->>'offeringKey'),'[]'::jsonb),
        COALESCE(jsonb_agg(jsonb_build_object('offeringKey',c.value->>'offeringKey','label',c.value->>'label','description',c.value->'description') ORDER BY c.value->>'offeringKey'),'[]'::jsonb)
 INTO v_offering_labels,v_offering_summaries
 FROM jsonb_array_elements(COALESCE(v_seller->'canonicalGenome'->'explanatory'->'offeringCopy','[]'::jsonb)) c(value)
 WHERE (c.value->>'offeringKey') IN (SELECT jsonb_array_elements_text(COALESCE(v_offering_keys,'[]'::jsonb)));
 RETURN jsonb_build_object(
  'opportunityId',v_opp.id::text,'organisationId',v_opp.organisation_id::text,'campaignId',v_opp.campaign_id::text,'companyId',v_opp.company_id::text,
  'companyName',v_company.canonical_name,'canonicalDomain',v_company.canonical_domain,'pathFingerprint',p_path_fingerprint,
  'accessPointId',v_node.id::text,'accessPointKind',v_node.access_point_kind,'accessPointValue',v_node.canonical_value,
  'routeMode',v_binding->>'mode','personId',NULLIF(v_binding->>'personId',''),'personName',CASE WHEN v_person.id IS NULL THEN NULL ELSE COALESCE(v_person.canonical_name,v_person.display_name) END,
  'sellerObjectiveKey',v_objective,'sellerObjectiveStatement',v_objective_statement,'sellerOfferingLabels',COALESCE(v_offering_labels,'[]'::jsonb),
  'sellerOfferings',COALESCE(v_offering_summaries,'[]'::jsonb),'commercialBoundaryFacts',COALESCE(v_boundary_facts,'[]'::jsonb),
  'authorityEnvelopeFingerprint',v_envfp,'r6AuthorityRecordId',v_r6.authority_record_id::text,'r6AuthorityFingerprint',v_a6.authority_fingerprint,
  'evaluatedAt',to_jsonb(p_at),'executableNow',true
 );
END $_$;

--
-- Name: marketroute_engagement_send_gate_v1(uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_engagement_send_gate_v1(p_queue_item_id uuid, p_at timestamp with time zone DEFAULT now()) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_queue public.engagement_queue_items%ROWTYPE; v_message public.engagement_messages%ROWTYPE; v_strategy public.engagement_strategies%ROWTYPE; v_review public.engagement_ai_reviews%ROWTYPE; v_approval public.engagement_message_approvals%ROWTYPE; v_policy text; v_env jsonb; v_envfp text; v_allowed boolean:=false; v_reason text:='UNKNOWN'; v_fp text;
BEGIN
 PERFORM public.marketroute_require_service_role(); IF p_at IS NULL OR abs(extract(epoch FROM(now()-p_at)))>300 THEN RETURN jsonb_build_object('allowed',false,'reasonCode','SEND_GATE_TIME_NOT_CURRENT'); END IF; SELECT * INTO v_queue FROM public.engagement_queue_items WHERE id=p_queue_item_id; IF NOT FOUND THEN RETURN jsonb_build_object('allowed',false,'reasonCode','QUEUE_ITEM_NOT_FOUND'); END IF;
 SELECT * INTO v_message FROM public.engagement_messages WHERE id=v_queue.message_id; SELECT * INTO v_strategy FROM public.engagement_strategies WHERE id=v_queue.strategy_id; SELECT * INTO v_review FROM public.engagement_ai_reviews WHERE id=v_queue.review_id; SELECT * INTO v_approval FROM public.engagement_message_approvals WHERE id=v_queue.approval_id;
 IF NOT public.marketroute_opportunity_executable_now_v1(v_queue.opportunity_id,p_at) THEN v_reason:='OPPORTUNITY_NOT_EXECUTABLE_NOW';
 ELSIF NOT public.marketroute_engagement_strategy_current_v1(v_strategy.id,p_at) THEN v_reason:='STRATEGY_AUTHORITY_STALE';
 ELSIF v_review.verdict<>'PASS' OR v_review.review_contract_version<>'MRV2-ENGAGEMENT-REVIEW-1.0.0' THEN v_reason:='CATEGORICAL_PASS_REQUIRED';
 ELSE
  IF v_queue.approval_mode='HUMAN' THEN
   SELECT * INTO v_approval FROM public.engagement_message_approvals a WHERE a.message_id=v_queue.message_id AND a.approval_mode='HUMAN' ORDER BY a.created_at DESC,a.id DESC LIMIT 1;
  END IF;
  IF v_approval.id IS NULL OR v_approval.decision<>'APPROVE' THEN v_reason:='MESSAGE_APPROVAL_REQUIRED';
  ELSE
  v_policy:=public.marketroute_current_engagement_policy_v1(v_queue.organisation_id,v_queue.campaign_id);
  IF v_approval.approval_mode='AUTOPILOT' AND v_policy<>'AUTOPILOT' THEN v_reason:='AUTOPILOT_POLICY_REVOKED';
  ELSE
   v_env:=public.marketroute_authority_envelope_v1(v_queue.organisation_id,v_queue.campaign_id,v_queue.company_id,p_at); v_envfp:=public.marketroute_authority_envelope_fingerprint_v1(v_env);
   IF v_envfp IS DISTINCT FROM v_strategy.authority_envelope_fingerprint OR v_queue.authority_envelope_fingerprint IS DISTINCT FROM v_strategy.authority_envelope_fingerprint THEN v_reason:='AUTHORITY_ENVELOPE_CHANGED'; ELSE v_allowed:=true;v_reason:='SEND_GATE_OPEN'; END IF;
  END IF;
  END IF;
 END IF;
 v_fp:=encode(extensions.digest(concat_ws('|','MRV2-ENGAGEMENT-SEND-GATE-1.0.0',v_queue.id::text,COALESCE(v_strategy.strategy_fingerprint,''),COALESCE(v_message.message_fingerprint,''),COALESCE(v_review.review_fingerprint,''),COALESCE(v_approval.id::text,''),COALESCE(v_policy,''),COALESCE(v_envfp,''),v_allowed::text,v_reason),'sha256'),'hex');
 RETURN jsonb_build_object('allowed',v_allowed,'reasonCode',v_reason,'sendGateFingerprint',v_fp,'authorityEnvelopeFingerprint',v_envfp,'currentApprovalId',CASE WHEN v_approval.id IS NULL THEN NULL ELSE v_approval.id::text END,'currentApprovalMode',v_approval.approval_mode,
  'deliveryPayload',CASE WHEN v_allowed THEN jsonb_build_object('queueItemId',v_queue.id::text,'idempotencyKey',v_queue.id::text,'channel',v_strategy.channel_kind,'accessPointValue',v_strategy.access_point_value,'subjectText',v_message.subject_text,'bodyText',v_message.body_text) ELSE NULL END);
END $$;

--
-- Name: marketroute_engagement_strategy_current_v1(uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_engagement_strategy_current_v1(p_strategy_id uuid, p_at timestamp with time zone DEFAULT now()) RETURNS boolean
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_strategy public.engagement_strategies%ROWTYPE; v_ctx jsonb; v_fp text;
BEGIN
 SELECT * INTO v_strategy FROM public.engagement_strategies WHERE id=p_strategy_id; IF NOT FOUND THEN RETURN false; END IF;
 IF NOT public.marketroute_opportunity_executable_now_v1(v_strategy.opportunity_id,p_at) THEN RETURN false; END IF;
 BEGIN
  v_ctx:=public.marketroute_engagement_generation_context_v1(v_strategy.opportunity_id,v_strategy.path_fingerprint,p_at);
  v_fp:=public.marketroute_engagement_generation_context_fingerprint_v1(v_ctx);
 EXCEPTION WHEN OTHERS THEN RETURN false;
 END;
 RETURN v_fp=v_strategy.generation_context_fingerprint AND v_ctx->>'authorityEnvelopeFingerprint'=v_strategy.authority_envelope_fingerprint AND v_ctx->>'r6AuthorityRecordId'=v_strategy.r6_authority_record_id::text AND v_ctx->>'r6AuthorityFingerprint'=v_strategy.r6_authority_fingerprint AND v_ctx->>'accessPointId'=v_strategy.access_point_id::text;
END $$;

--
-- Name: marketroute_engagement_strategy_fingerprint_v1(jsonb, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_engagement_strategy_fingerprint_v1(p_context jsonb, p_channel text) RETURNS text
    LANGUAGE sql IMMUTABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
 SELECT encode(extensions.digest(concat_ws('|','MRV2-ENGAGEMENT-STRATEGY-FINGERPRINT-1.0.0',
  p_context->>'opportunityId',p_context->>'organisationId',p_context->>'campaignId',p_context->>'companyId',p_context->>'pathFingerprint',p_context->>'accessPointId',p_channel,p_context->>'routeMode',p_context->>'accessPointValue',COALESCE(p_context->>'personId','NONE'),p_context->>'authorityEnvelopeFingerprint',p_context->>'r6AuthorityRecordId',p_context->>'r6AuthorityFingerprint'),'sha256'),'hex');
$$;

--
-- Name: marketroute_ensure_activation_company_v1(uuid, uuid, text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_ensure_activation_company_v1(p_organisation_id uuid, p_campaign_id uuid, p_name text, p_domain text, p_website_url text, p_country_code text DEFAULT NULL::text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
DECLARE
  v_domain text := lower(regexp_replace(
    btrim(COALESCE(p_domain, '')),
    '^www[.]',
    '',
    'i'
  ));
  v_name text := left(btrim(COALESCE(p_name, '')), 240);
  v_website_url text := nullif(btrim(COALESCE(p_website_url, '')), '');
  v_country_code text := CASE
    WHEN upper(COALESCE(p_country_code, '')) ~ '^[A-Z]{2}$'
      THEN upper(p_country_code)
    ELSE NULL
  END;
  v_company uuid;
BEGIN
  PERFORM public.marketroute_require_service_role();

  IF NOT EXISTS (
    SELECT 1
    FROM public.campaigns AS c
    WHERE c.id = p_campaign_id
      AND c.organisation_id = p_organisation_id
      AND c.workflow_state = 'ACTIVE'
  ) THEN
    RAISE EXCEPTION 'MARKETROUTE_ACTIVATION_CAMPAIGN_NOT_ACTIVE';
  END IF;

  IF v_domain !~ '^[a-z0-9][a-z0-9.-]*[.][a-z]{2,63}$'
     OR v_domain ~ '[.][.]' THEN
    RAISE EXCEPTION 'MARKETROUTE_ACTIVATION_COMPANY_DOMAIN_INVALID';
  END IF;

  SELECT c.id
  INTO v_company
  FROM public.companies AS c
  WHERE c.canonical_domain = v_domain
  LIMIT 1;

  IF v_company IS NULL THEN
    IF length(v_name) = 0 THEN
      RAISE EXCEPTION 'MARKETROUTE_ACTIVATION_COMPANY_NAME_INVALID';
    END IF;

    INSERT INTO public.companies(
      canonical_name,
      canonical_domain,
      website_url,
      country_code,
      lifecycle_state
    )
    VALUES(
      v_name,
      v_domain,
      COALESCE(v_website_url, 'https://' || v_domain),
      v_country_code,
      'ACTIVE'
    )
    RETURNING id INTO v_company;
  END IF;

  INSERT INTO public.organisation_company_scopes(
    organisation_id,
    company_id,
    campaign_id,
    scope_kind
  )
  VALUES(
    p_organisation_id,
    v_company,
    p_campaign_id,
    'CAMPAIGN'
  )
  ON CONFLICT DO NOTHING;

  RETURN v_company;
END;
$_$;

--
-- Name: marketroute_ensure_commercial_relationship_v1(uuid, text, uuid, uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_ensure_commercial_relationship_v1(p_tenant_scope_organisation_id uuid, p_relation_type text, p_from_node_id uuid, p_to_node_id uuid, p_ontology_version text, p_canonical_version text) RETURNS TABLE(relationship_id uuid, claim_id uuid, relationship_fingerprint text, deduplicated boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_type public.commercial_relationship_type_registry%ROWTYPE; v_from public.commercial_graph_nodes%ROWTYPE; v_to public.commercial_graph_nodes%ROWTYPE; v_from_id uuid:=p_from_node_id; v_to_id uuid:=p_to_node_id; v_tmp uuid; v_fp text; v_claim_fp text; v_existing public.commercial_relationships%ROWTYPE; v_claim_id uuid; v_relationship_id uuid:=gen_random_uuid();
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT * INTO v_type FROM public.commercial_relationship_type_registry WHERE relation_type=p_relation_type;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_RELATIONSHIP_TYPE_UNKNOWN'; END IF;
  IF p_ontology_version IS DISTINCT FROM v_type.ontology_version OR p_canonical_version IS DISTINCT FROM 'MRV2-RELATIONSHIP-CANON-1.0.0' THEN RAISE EXCEPTION 'MARKETROUTE_RELATIONSHIP_VERSION_MISMATCH'; END IF;
  SELECT * INTO v_from FROM public.commercial_graph_nodes WHERE id=v_from_id; IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_RELATIONSHIP_FROM_NODE_NOT_FOUND'; END IF;
  SELECT * INTO v_to FROM public.commercial_graph_nodes WHERE id=v_to_id; IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_RELATIONSHIP_TO_NODE_NOT_FOUND'; END IF;
  IF NOT (v_type.allowed_from_kinds ? v_from.node_kind) OR NOT (v_type.allowed_to_kinds ? v_to.node_kind) THEN RAISE EXCEPTION 'MARKETROUTE_RELATIONSHIP_ENDPOINT_KIND_INVALID'; END IF;
  IF p_tenant_scope_organisation_id IS NULL AND (v_from.tenant_scope_organisation_id IS NOT NULL OR v_to.tenant_scope_organisation_id IS NOT NULL) THEN RAISE EXCEPTION 'MARKETROUTE_GLOBAL_RELATIONSHIP_PRIVATE_NODE'; END IF;
  IF p_tenant_scope_organisation_id IS NOT NULL AND ((v_from.tenant_scope_organisation_id IS NOT NULL AND v_from.tenant_scope_organisation_id<>p_tenant_scope_organisation_id) OR (v_to.tenant_scope_organisation_id IS NOT NULL AND v_to.tenant_scope_organisation_id<>p_tenant_scope_organisation_id)) THEN RAISE EXCEPTION 'MARKETROUTE_RELATIONSHIP_NODE_SCOPE_MISMATCH'; END IF;
  IF v_from_id=v_to_id THEN RAISE EXCEPTION 'MARKETROUTE_RELATIONSHIP_SELF_EDGE'; END IF;
  IF v_type.direction='UNDIRECTED' AND v_from.node_fingerprint>v_to.node_fingerprint THEN v_tmp:=v_from_id;v_from_id:=v_to_id;v_to_id:=v_tmp; SELECT * INTO v_from FROM public.commercial_graph_nodes WHERE id=v_from_id; SELECT * INTO v_to FROM public.commercial_graph_nodes WHERE id=v_to_id; END IF;
  v_fp:=encode(extensions.digest(concat_ws('|','MRV2-RELATIONSHIP-1.0.0',COALESCE(p_tenant_scope_organisation_id::text,'GLOBAL'),p_relation_type,v_from.node_fingerprint,v_to.node_fingerprint,v_type.ontology_version),'sha256'),'hex');
  SELECT * INTO v_existing FROM public.commercial_relationships r WHERE r.relationship_fingerprint=v_fp;
  IF FOUND THEN RETURN QUERY SELECT v_existing.id,v_existing.claim_id,v_existing.relationship_fingerprint,true; RETURN; END IF;
  v_claim_fp:=encode(extensions.digest(concat_ws('|','MRV2-RELATIONSHIP-CLAIM-1.0.0',COALESCE(p_tenant_scope_organisation_id::text,'GLOBAL'),v_fp,'relationship.exists','EXISTS','true'),'sha256'),'hex');
  INSERT INTO public.claims(tenant_scope_organisation_id,subject_type,subject_id,claim_key,predicate,object_json,canonical_value_text,claim_fingerprint,fingerprint_version)
  VALUES(p_tenant_scope_organisation_id,'RELATIONSHIP',v_relationship_id,'relationship.exists','EXISTS','true'::jsonb,'true',v_claim_fp,'MRV2-CLAIM-FP-1.0.0')
  RETURNING id INTO v_claim_id;
  -- Relationship id is the evidence subject identity.
  INSERT INTO public.commercial_relationships(id,tenant_scope_organisation_id,relation_type,from_node_id,to_node_id,claim_id,relationship_fingerprint,ontology_version,canonical_version)
  VALUES(v_relationship_id,p_tenant_scope_organisation_id,p_relation_type,v_from_id,v_to_id,v_claim_id,v_fp,v_type.ontology_version,p_canonical_version);
  RETURN QUERY SELECT v_relationship_id,v_claim_id,v_fp,false;
END; $$;

--
-- Name: marketroute_ensure_graph_node_v1(uuid, text, uuid, uuid, text, text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_ensure_graph_node_v1(p_tenant_scope_organisation_id uuid, p_node_kind text, p_company_id uuid, p_person_id uuid, p_stable_key text, p_label text, p_access_point_kind text, p_canonical_value text, p_canonical_version text) RETURNS TABLE(node_id uuid, node_fingerprint text, deduplicated boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_fp text; v_node_id uuid; v_existing public.commercial_graph_nodes%ROWTYPE; v_stable text:=NULLIF(lower(btrim(p_stable_key)),''); v_value text:=NULLIF(btrim(p_canonical_value),'');
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF p_canonical_version IS DISTINCT FROM 'MRV2-RELATIONSHIP-CANON-1.0.0' THEN RAISE EXCEPTION 'MARKETROUTE_GRAPH_NODE_CANONICAL_VERSION_MISMATCH'; END IF;
  IF p_node_kind NOT IN ('COMPANY','PERSON','ORGANISATIONAL_UNIT','TECHNOLOGY','ACCESS_POINT') THEN RAISE EXCEPTION 'MARKETROUTE_GRAPH_NODE_KIND_INVALID'; END IF;
  IF p_node_kind IN ('COMPANY','PERSON') AND p_tenant_scope_organisation_id IS NOT NULL THEN RAISE EXCEPTION 'MARKETROUTE_CANONICAL_ENTITY_NODE_MUST_BE_GLOBAL'; END IF;
  IF p_node_kind='COMPANY' AND (p_company_id IS NULL OR p_person_id IS NOT NULL OR v_stable IS NOT NULL OR p_access_point_kind IS NOT NULL OR v_value IS NOT NULL) THEN RAISE EXCEPTION 'MARKETROUTE_GRAPH_COMPANY_NODE_INVALID'; END IF;
  IF p_node_kind='PERSON' AND (p_person_id IS NULL OR p_company_id IS NOT NULL OR v_stable IS NOT NULL OR p_access_point_kind IS NOT NULL OR v_value IS NOT NULL) THEN RAISE EXCEPTION 'MARKETROUTE_GRAPH_PERSON_NODE_INVALID'; END IF;
  IF p_node_kind IN ('ORGANISATIONAL_UNIT','TECHNOLOGY') AND (p_company_id IS NOT NULL OR p_person_id IS NOT NULL OR v_stable IS NULL OR p_access_point_kind IS NOT NULL OR v_value IS NOT NULL) THEN RAISE EXCEPTION 'MARKETROUTE_GRAPH_SEMANTIC_NODE_INVALID'; END IF;
  IF p_node_kind='ACCESS_POINT' AND (p_company_id IS NOT NULL OR p_person_id IS NOT NULL OR v_stable IS NULL OR p_access_point_kind IS NULL OR v_value IS NULL) THEN RAISE EXCEPTION 'MARKETROUTE_GRAPH_ACCESS_POINT_INVALID'; END IF;
  IF p_node_kind='COMPANY' AND NOT EXISTS(SELECT 1 FROM public.companies WHERE id=p_company_id) THEN RAISE EXCEPTION 'MARKETROUTE_GRAPH_COMPANY_NOT_FOUND'; END IF;
  IF p_node_kind='PERSON' AND NOT EXISTS(SELECT 1 FROM public.people WHERE id=p_person_id) THEN RAISE EXCEPTION 'MARKETROUTE_GRAPH_PERSON_NOT_FOUND'; END IF;
  v_fp:=public.marketroute_graph_node_fingerprint_v1(p_tenant_scope_organisation_id,p_node_kind,p_company_id,p_person_id,v_stable,p_access_point_kind,v_value);
  SELECT * INTO v_existing FROM public.commercial_graph_nodes n WHERE n.node_fingerprint=v_fp;
  IF FOUND THEN RETURN QUERY SELECT v_existing.id,v_existing.node_fingerprint,true; RETURN; END IF;
  INSERT INTO public.commercial_graph_nodes(tenant_scope_organisation_id,node_kind,company_id,person_id,stable_key,label,access_point_kind,canonical_value,node_fingerprint,canonical_version)
  VALUES(p_tenant_scope_organisation_id,p_node_kind,p_company_id,p_person_id,v_stable,NULLIF(btrim(p_label),''),p_access_point_kind,v_value,v_fp,p_canonical_version)
  RETURNING id INTO v_node_id;
  RETURN QUERY SELECT v_node_id,v_fp,false;
END; $$;

--
-- Name: marketroute_fail_anonymous_discovery_extension_v1(uuid, text, text, boolean, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_fail_anonymous_discovery_extension_v1(p_job_id uuid, p_worker_id text, p_error_code text, p_retryable boolean, p_at timestamp with time zone DEFAULT now()) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_job public.anonymous_discovery_extension_jobs%ROWTYPE;v_terminal boolean:=false;
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT * INTO v_job FROM public.anonymous_discovery_extension_jobs WHERE id=p_job_id FOR UPDATE;
  IF NOT FOUND OR v_job.status<>'RUNNING' OR v_job.worker_id IS DISTINCT FROM left(btrim(COALESCE(p_worker_id,'')),200) THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_EXTENSION_LEASE_INVALID'; END IF;
  v_terminal:=public.marketroute_anonymous_discovery_budget_terminal_v1(v_job.run_id,p_at);
  UPDATE public.anonymous_discovery_extension_jobs
  SET status=CASE WHEN COALESCE(p_retryable,false) AND attempt_count<3 AND NOT v_terminal THEN 'DEFERRED' ELSE CASE WHEN v_terminal THEN 'EXHAUSTED' ELSE 'FAILED' END END,
      cycle_policy_version=4,
      worker_id=NULL,
      lease_expires_at=NULL,
      available_at=CASE WHEN COALESCE(p_retryable,false) AND attempt_count<3 AND NOT v_terminal THEN p_at+interval '2 minutes' ELSE available_at END,
      last_error_code=CASE WHEN v_terminal THEN 'MARKETROUTE_ANONYMOUS_EXTENSION_RESEARCH_CAPACITY_EXHAUSTED' ELSE left(COALESCE(NULLIF(btrim(p_error_code),''),'MARKETROUTE_ANONYMOUS_EXTENSION_FAILED'),240) END
  WHERE id=p_job_id;
END;
$$;

--
-- Name: marketroute_fail_engagement_delivery_v1(uuid, text, text, boolean, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_fail_engagement_delivery_v1(p_queue_item_id uuid, p_worker_id text, p_error_code text, p_delivery_state_unknown boolean, p_at timestamp with time zone DEFAULT now()) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_job public.engagement_delivery_jobs%ROWTYPE; v_status text;
BEGIN
 PERFORM public.marketroute_require_service_role(); IF p_at IS NULL OR abs(extract(epoch FROM(now()-p_at)))>300 THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_FAILURE_TIME_NOT_CURRENT'; END IF; SELECT * INTO v_job FROM public.engagement_delivery_jobs WHERE queue_item_id=p_queue_item_id FOR UPDATE; IF NOT FOUND OR v_job.status<>'RUNNING' OR v_job.claimed_by IS DISTINCT FROM p_worker_id THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_DELIVERY_CLAIM_MISMATCH'; END IF;
 v_status:=CASE WHEN COALESCE(p_delivery_state_unknown,true) THEN 'RECONCILIATION_REQUIRED' ELSE 'FAILED' END;
 UPDATE public.engagement_delivery_jobs SET status=v_status,finished_at=p_at,last_error_code=left(COALESCE(NULLIF(btrim(p_error_code),''),'MARKETROUTE_ENGAGEMENT_DELIVERY_FAILED'),500) WHERE id=v_job.id;
 INSERT INTO public.engagement_delivery_events(queue_item_id,job_id,event_type,worker_id,send_gate_fingerprint,metadata_json,occurred_at) VALUES(v_job.queue_item_id,v_job.id,v_status,p_worker_id,v_job.send_gate_fingerprint,jsonb_build_object('errorCode',left(COALESCE(p_error_code,'MARKETROUTE_ENGAGEMENT_DELIVERY_FAILED'),500),'deliveryStateUnknown',COALESCE(p_delivery_state_unknown,true)),p_at);
 RETURN v_status;
END $$;

--
-- Name: marketroute_fail_paid_campaign_refill_v1(uuid, text, text, boolean, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_fail_paid_campaign_refill_v1(p_job_id uuid, p_worker_id text, p_error_code text, p_retryable boolean, p_at timestamp with time zone DEFAULT now()) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_job public.paid_campaign_refill_jobs%ROWTYPE;
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT * INTO v_job FROM public.paid_campaign_refill_jobs WHERE id=p_job_id FOR UPDATE;
  IF NOT FOUND OR v_job.status<>'RUNNING' OR v_job.worker_id IS DISTINCT FROM left(btrim(COALESCE(p_worker_id,'')),200) THEN RAISE EXCEPTION 'MARKETROUTE_PAID_REFILL_LEASE_INVALID'; END IF;
  UPDATE public.paid_campaign_refill_jobs SET status=CASE WHEN COALESCE(p_retryable,false) AND attempt_count<6 THEN 'DEFERRED' ELSE 'FAILED' END,worker_id=NULL,lease_expires_at=NULL,available_at=CASE WHEN COALESCE(p_retryable,false) AND attempt_count<6 THEN p_at+interval '2 minutes' ELSE available_at END,last_error_code=left(COALESCE(NULLIF(btrim(p_error_code),''),'MARKETROUTE_PAID_REFILL_FAILED'),240),updated_at=p_at WHERE id=p_job_id;
END;$$;

--
-- Name: marketroute_fail_research_work_v1(uuid, uuid, text, numeric, boolean, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_fail_research_work_v1(p_work_unit_id uuid, p_scheduler_run_id uuid, p_error_code text, p_actual_cost_usd numeric DEFAULT 0, p_retryable boolean DEFAULT true, p_at timestamp with time zone DEFAULT now()) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_work public.research_work_units%ROWTYPE; v_job public.background_jobs%ROWTYPE; v_terminal boolean;
BEGIN
 SELECT * INTO v_work FROM public.research_work_units WHERE id=p_work_unit_id; IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_WORK_NOT_FOUND'; END IF; SELECT * INTO v_job FROM public.background_jobs WHERE id=v_work.background_job_id FOR UPDATE;
 IF v_job.status<>'RUNNING' OR v_job.reserved_by_run_id IS DISTINCT FROM p_scheduler_run_id THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_WORK_NOT_OWNED'; END IF;
 IF p_actual_cost_usd<0 OR p_actual_cost_usd>100000 THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_FAILED_COST_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM public.research_budget_events WHERE work_unit_id=v_work.id AND attempt_number=v_job.attempt_count AND event_type IN('COMMIT','RELEASE')) THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_WORK_ALREADY_SETTLED'; END IF;
 IF p_actual_cost_usd>0 THEN INSERT INTO public.research_budget_events(organisation_id,campaign_id,work_unit_id,scheduler_run_id,attempt_number,event_type,amount_usd,occurred_at,metadata_json) VALUES(v_work.organisation_id,v_work.campaign_id,v_work.id,p_scheduler_run_id,v_job.attempt_count,'COMMIT',p_actual_cost_usd,p_at,jsonb_build_object('failedAttempt',true,'errorCode',p_error_code)); END IF;
 INSERT INTO public.research_budget_events(organisation_id,campaign_id,work_unit_id,scheduler_run_id,attempt_number,event_type,amount_usd,occurred_at,metadata_json) VALUES(v_work.organisation_id,v_work.campaign_id,v_work.id,p_scheduler_run_id,v_job.attempt_count,'RELEASE',greatest(0,v_work.cost_ceiling_usd-p_actual_cost_usd),p_at,jsonb_build_object('errorCode',p_error_code));
 v_terminal:=NOT p_retryable OR v_job.attempt_count>=v_job.max_attempts;
 UPDATE public.background_jobs SET status=CASE WHEN v_terminal THEN 'FAILED' ELSE 'PENDING' END,available_at=CASE WHEN v_terminal THEN available_at ELSE p_at+interval '5 minutes' END,reserved_by_run_id=NULL,reserved_at=NULL,last_error_code=left(COALESCE(p_error_code,'RESEARCH_FAILED'),200),updated_at=p_at WHERE id=v_job.id;
 UPDATE public.background_job_attempts SET status='FAILED',completed_at=p_at,error_code=left(COALESCE(p_error_code,'RESEARCH_FAILED'),200) WHERE job_id=v_job.id AND attempt_number=v_job.attempt_count AND status='RUNNING';
END $$;

--
-- Name: marketroute_fail_workspace_activation_v1(uuid, text, text, boolean, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_fail_workspace_activation_v1(p_job_id uuid, p_worker_id text, p_error_code text, p_retryable boolean, p_at timestamp with time zone DEFAULT now()) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$ DECLARE v_attempt integer;BEGIN PERFORM public.marketroute_require_service_role();SELECT attempt_count INTO v_attempt FROM public.workspace_activation_jobs WHERE id=p_job_id AND status='RUNNING' AND worker_id=p_worker_id FOR UPDATE;IF v_attempt IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_ACTIVATION_LEASE_MISMATCH';END IF;UPDATE public.workspace_activation_jobs SET status=CASE WHEN p_retryable AND v_attempt<5 THEN 'FAILED' ELSE 'NEEDS_INPUT' END,available_at=CASE WHEN p_retryable AND v_attempt<5 THEN p_at+interval '10 minutes' ELSE available_at END,worker_id=NULL,lease_expires_at=NULL,last_error_code=left(COALESCE(p_error_code,'MARKETROUTE_ACTIVATION_FAILED'),500) WHERE id=p_job_id;END;$$;

--
-- Name: marketroute_finish_billing_event_v1(text, text, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_finish_billing_event_v1(p_external_event_id text, p_status text, p_error_code text DEFAULT NULL::text, p_metadata_json jsonb DEFAULT '{}'::jsonb) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF p_status NOT IN('PROCESSED','IGNORED','FAILED') THEN RAISE EXCEPTION 'MARKETROUTE_BILLING_EVENT_STATUS_INVALID'; END IF;
  UPDATE public.marketroute_billing_events SET status=p_status,error_code=left(NULLIF(btrim(COALESCE(p_error_code,'')),''),500),metadata_json=COALESCE(p_metadata_json,'{}'::jsonb),processed_at=now(),updated_at=now() WHERE external_event_id=p_external_event_id;
  RETURN FOUND;
END;$$;

--
-- Name: marketroute_finish_growth_scheduler_run_v1(uuid, text, jsonb, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_finish_growth_scheduler_run_v1(p_scheduler_run_id uuid, p_status text, p_metadata jsonb DEFAULT '{}'::jsonb, p_at timestamp with time zone DEFAULT now()) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
 PERFORM public.marketroute_require_service_role();
 IF p_status NOT IN('SUCCEEDED','PARTIAL','FAILED','CANCELLED') THEN RAISE EXCEPTION 'MARKETROUTE_GROWTH_RUN_STATUS_INVALID'; END IF;
 UPDATE public.scheduler_runs SET status=p_status,completed_at=p_at,metadata_json=COALESCE(metadata_json,'{}'::jsonb)||COALESCE(p_metadata,'{}'::jsonb) WHERE id=p_scheduler_run_id AND runner_key='GENESIS_DATABASE_GROWTH_V1' AND status='RUNNING';
 IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_GROWTH_RUN_NOT_ACTIVE'; END IF;
 DELETE FROM public.scheduler_leases WHERE lease_key='GENESIS_DATABASE_GROWTH_V1' AND owner_run_id=p_scheduler_run_id;
END;$$;

--
-- Name: marketroute_finish_research_scheduler_run_v1(uuid, text, jsonb, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_finish_research_scheduler_run_v1(p_scheduler_run_id uuid, p_status text, p_metadata jsonb DEFAULT '{}'::jsonb, p_at timestamp with time zone DEFAULT now()) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
 IF p_status NOT IN('SUCCEEDED','PARTIAL','FAILED','CANCELLED') THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_RUN_STATUS_INVALID'; END IF;
 UPDATE public.scheduler_runs SET status=p_status,completed_at=p_at,metadata_json=COALESCE(metadata_json,'{}'::jsonb)||COALESCE(p_metadata,'{}'::jsonb) WHERE id=p_scheduler_run_id AND status='RUNNING' AND runner_key='GENESIS_RESEARCH_V1';
 IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_RUN_NOT_ACTIVE'; END IF;
 DELETE FROM public.scheduler_leases WHERE lease_key='GENESIS_RESEARCH_V1' AND owner_run_id=p_scheduler_run_id;
END $$;

--
-- Name: marketroute_founder_dashboard_snapshot_v1(timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_founder_dashboard_snapshot_v1(p_at timestamp with time zone DEFAULT now()) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_at timestamptz := COALESCE(p_at,now());
  v_day_start timestamptz := date_trunc('day',COALESCE(p_at,now()) AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
  v_24h timestamptz := COALESCE(p_at,now()) - interval '24 hours';
  v_runtime jsonb;
  v_latest_release jsonb;
BEGIN
  PERFORM public.marketroute_require_service_role();

  SELECT COALESCE(jsonb_object_agg(x.runtime_kind,jsonb_build_object(
    'eventType',x.event_type,
    'occurredAt',x.occurred_at,
    'durationMs',x.duration_ms,
    'errorCode',x.error_code,
    'metadata',x.metadata_json
  )),'{}'::jsonb) INTO v_runtime
  FROM (
    SELECT DISTINCT ON (runtime_kind) runtime_kind,event_type,occurred_at,duration_ms,error_code,metadata_json
    FROM public.production_runtime_events
    ORDER BY runtime_kind,occurred_at DESC,id DESC
  ) x;

  SELECT jsonb_build_object('releaseKey',release_key,'buildNumber',build_number,'appliedAt',applied_at)
  INTO v_latest_release
  FROM public.marketroute_schema_releases
  ORDER BY applied_at DESC LIMIT 1;

  RETURN jsonb_build_object(
    'generatedAt',v_at,
    'schemaRelease',COALESCE(v_latest_release,'{}'::jsonb),
    'runtime',COALESCE(v_runtime,'{}'::jsonb),
    'platform',jsonb_build_object(
      'organisations',(SELECT count(*) FROM public.organisations WHERE status='ACTIVE'),
      'sellerBusinesses',(SELECT count(*) FROM public.seller_businesses WHERE lifecycle_state='ACTIVE'),
      'activeCampaigns',(SELECT count(*) FROM public.campaigns WHERE workflow_state='ACTIVE'),
      'allCampaigns',(SELECT count(*) FROM public.campaigns),
      'migrationBatches',0,
      'migratedRecords',0,
      'migrationRejections',0
    ),
    'growth',jsonb_build_object(
      'enabled',(SELECT enabled FROM public.genesis_growth_settings WHERE singleton=true),
      'phase',(CASE WHEN EXISTS(SELECT 1 FROM public.genesis_growth_industries i WHERE i.enabled AND (SELECT count(*) FROM public.genesis_growth_company_memberships m WHERE m.industry_key=i.industry_key)<i.seed_target_company_count) THEN 'SEED' WHEN EXISTS(SELECT 1 FROM public.genesis_growth_company_progress p WHERE (p.retry_after IS NULL OR p.retry_after<=v_at) AND (p.core_complete_at IS NULL OR p.profile_complete_at IS NULL OR p.routes_complete_at IS NULL OR p.contacts_complete_at IS NULL)) THEN 'DEPTH' WHEN EXISTS(SELECT 1 FROM public.genesis_growth_industries i WHERE i.enabled AND (SELECT count(*) FROM public.genesis_growth_company_memberships m WHERE m.industry_key=i.industry_key)<i.launch_target_company_count) THEN 'BREADTH' ELSE 'REFRESH' END),
      'targetCompanies',(SELECT COALESCE(sum(launch_target_company_count),0) FROM public.genesis_growth_industries WHERE enabled),
      'seedTargetCompanies',(SELECT COALESCE(sum(seed_target_company_count),0) FROM public.genesis_growth_industries WHERE enabled),
      'companies',(SELECT count(DISTINCT company_id) FROM public.genesis_growth_company_memberships),
      'dense80',(SELECT count(DISTINCT p.company_id) FROM public.genesis_growth_company_progress p JOIN public.genesis_growth_company_memberships m ON m.company_id=p.company_id WHERE (20 + CASE WHEN p.core_complete_at IS NOT NULL THEN 20 ELSE 0 END + CASE WHEN p.profile_complete_at IS NOT NULL THEN 20 ELSE 0 END + CASE WHEN p.routes_complete_at IS NOT NULL THEN 20 ELSE 0 END + CASE WHEN p.contacts_complete_at IS NOT NULL THEN 20 ELSE 0 END)>=80),
      'dense100',(SELECT count(DISTINCT p.company_id) FROM public.genesis_growth_company_progress p JOIN public.genesis_growth_company_memberships m ON m.company_id=p.company_id WHERE p.core_complete_at IS NOT NULL AND p.profile_complete_at IS NOT NULL AND p.routes_complete_at IS NOT NULL AND p.contacts_complete_at IS NOT NULL),
      'averageDensity',(SELECT COALESCE(round(avg(20 + CASE WHEN p.core_complete_at IS NOT NULL THEN 20 ELSE 0 END + CASE WHEN p.profile_complete_at IS NOT NULL THEN 20 ELSE 0 END + CASE WHEN p.routes_complete_at IS NOT NULL THEN 20 ELSE 0 END + CASE WHEN p.contacts_complete_at IS NOT NULL THEN 20 ELSE 0 END),1),0) FROM public.genesis_growth_company_progress p JOIN public.genesis_growth_company_memberships m ON m.company_id=p.company_id),
      'actions',(SELECT count(*) FROM public.genesis_growth_action_runs),
      'actionsSucceeded',(SELECT count(*) FROM public.genesis_growth_action_runs WHERE status='SUCCEEDED'),
      'actionsFailed',(SELECT count(*) FROM public.genesis_growth_action_runs WHERE status='FAILED'),
      'spendUsd',public.marketroute_growth_effective_spend_v1(NULL,NULL),
      'spentTodayUsd',public.marketroute_growth_effective_spend_v1(v_day_start,NULL),
      'dailyBudgetUsd',(SELECT daily_budget_usd FROM public.genesis_growth_settings WHERE singleton=true),
      'latestAt',(SELECT max(completed_at) FROM public.genesis_growth_action_runs),
      'nextPriorityIndustry',(CASE
        WHEN EXISTS(SELECT 1 FROM public.genesis_growth_industries i WHERE i.enabled AND (SELECT count(*) FROM public.genesis_growth_company_memberships m WHERE m.industry_key=i.industry_key)<i.seed_target_company_count) THEN
          (SELECT i.display_name FROM public.genesis_growth_industries i WHERE i.enabled AND (SELECT count(*) FROM public.genesis_growth_company_memberships m WHERE m.industry_key=i.industry_key)<i.seed_target_company_count ORDER BY ((SELECT count(*) FROM public.genesis_growth_company_memberships m WHERE m.industry_key=i.industry_key)::numeric/greatest(1,i.seed_target_company_count)),i.priority DESC,i.industry_key LIMIT 1)
        WHEN EXISTS(SELECT 1 FROM public.genesis_growth_company_progress p WHERE (p.retry_after IS NULL OR p.retry_after<=v_at) AND (p.core_complete_at IS NULL OR p.profile_complete_at IS NULL OR p.routes_complete_at IS NULL OR p.contacts_complete_at IS NULL)) THEN
          (SELECT i.display_name FROM public.genesis_growth_company_progress p JOIN public.genesis_growth_company_memberships m ON m.company_id=p.company_id JOIN public.genesis_growth_industries i ON i.industry_key=m.industry_key WHERE i.enabled AND (p.retry_after IS NULL OR p.retry_after<=v_at) AND (p.core_complete_at IS NULL OR p.profile_complete_at IS NULL OR p.routes_complete_at IS NULL OR p.contacts_complete_at IS NULL) ORDER BY ((CASE WHEN p.core_complete_at IS NOT NULL THEN 1 ELSE 0 END)+(CASE WHEN p.profile_complete_at IS NOT NULL THEN 1 ELSE 0 END)+(CASE WHEN p.routes_complete_at IS NOT NULL THEN 1 ELSE 0 END)+(CASE WHEN p.contacts_complete_at IS NOT NULL THEN 1 ELSE 0 END)) DESC,COALESCE(p.last_researched_at,'epoch'::timestamptz),p.company_id,i.priority DESC,i.industry_key LIMIT 1)
        WHEN EXISTS(SELECT 1 FROM public.genesis_growth_industries i WHERE i.enabled AND (SELECT count(*) FROM public.genesis_growth_company_memberships m WHERE m.industry_key=i.industry_key)<i.launch_target_company_count) THEN
          (SELECT i.display_name FROM public.genesis_growth_industries i WHERE i.enabled AND (SELECT count(*) FROM public.genesis_growth_company_memberships m WHERE m.industry_key=i.industry_key)<i.launch_target_company_count ORDER BY ((SELECT count(*) FROM public.genesis_growth_company_memberships m WHERE m.industry_key=i.industry_key)::numeric/greatest(1,i.launch_target_company_count)),i.priority DESC,i.industry_key LIMIT 1)
        ELSE
          (SELECT i.display_name FROM public.genesis_growth_company_progress p JOIN public.genesis_growth_company_memberships m ON m.company_id=p.company_id JOIN public.genesis_growth_industries i ON i.industry_key=m.industry_key WHERE i.enabled AND COALESCE(p.last_researched_at,'epoch'::timestamptz)<=v_at-make_interval(days=>(SELECT refresh_days FROM public.genesis_growth_settings WHERE singleton=true)) ORDER BY COALESCE(p.last_researched_at,'epoch'::timestamptz),p.company_id,i.priority DESC,i.industry_key LIMIT 1)
      END),
      'industries',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'key',q.industry_key,'name',q.display_name,'priority',q.priority,'companies',q.companies,'seedTarget',q.seed_target_company_count,'launchTarget',q.launch_target_company_count,
        'dense80',q.dense80,'dense100',q.dense100,'averageDensity',q.average_density,'people',q.people,'relationships',q.relationships
      ) ORDER BY q.priority DESC,q.display_name),'[]'::jsonb) FROM (
        SELECT i.industry_key,i.display_name,i.priority,i.seed_target_company_count,i.launch_target_company_count,
          count(DISTINCT m.company_id) companies,
          count(DISTINCT p.company_id) FILTER(WHERE (20 + CASE WHEN p.core_complete_at IS NOT NULL THEN 20 ELSE 0 END + CASE WHEN p.profile_complete_at IS NOT NULL THEN 20 ELSE 0 END + CASE WHEN p.routes_complete_at IS NOT NULL THEN 20 ELSE 0 END + CASE WHEN p.contacts_complete_at IS NOT NULL THEN 20 ELSE 0 END)>=80) dense80,
          count(DISTINCT p.company_id) FILTER(WHERE p.core_complete_at IS NOT NULL AND p.profile_complete_at IS NOT NULL AND p.routes_complete_at IS NOT NULL AND p.contacts_complete_at IS NOT NULL) dense100,
          COALESCE(round(avg(20 + CASE WHEN p.core_complete_at IS NOT NULL THEN 20 ELSE 0 END + CASE WHEN p.profile_complete_at IS NOT NULL THEN 20 ELSE 0 END + CASE WHEN p.routes_complete_at IS NOT NULL THEN 20 ELSE 0 END + CASE WHEN p.contacts_complete_at IS NOT NULL THEN 20 ELSE 0 END),1),0) average_density,
          count(DISTINCT gp.person_id) people,
          count(DISTINCT cr.id) relationships
        FROM public.genesis_growth_industries i
        LEFT JOIN public.genesis_growth_company_memberships m ON m.industry_key=i.industry_key
        LEFT JOIN public.genesis_growth_company_progress p ON p.company_id=m.company_id
        LEFT JOIN public.genesis_growth_people gp ON gp.company_id=m.company_id
        LEFT JOIN public.commercial_graph_nodes gn ON gn.node_kind='COMPANY' AND gn.company_id=m.company_id
        LEFT JOIN public.commercial_relationships cr ON cr.tenant_scope_organisation_id IS NULL AND (cr.from_node_id=gn.id OR cr.to_node_id=gn.id)
        WHERE i.enabled GROUP BY i.industry_key,i.display_name,i.priority,i.seed_target_company_count,i.launch_target_company_count
      ) q)
    ),
    'activation',jsonb_build_object(
      'total',(SELECT count(*) FROM public.workspace_activation_jobs),
      'pending',(SELECT count(*) FROM public.workspace_activation_jobs WHERE status='PENDING'),
      'running',(SELECT count(*) FROM public.workspace_activation_jobs WHERE status='RUNNING'),
      'succeeded',(SELECT count(*) FROM public.workspace_activation_jobs WHERE status='SUCCEEDED'),
      'failed',(SELECT count(*) FROM public.workspace_activation_jobs WHERE status='FAILED'),
      'needsInput',(SELECT count(*) FROM public.workspace_activation_jobs WHERE status='NEEDS_INPUT'),
      'latestAt',(SELECT max(updated_at) FROM public.workspace_activation_jobs)
    ),
    'discovery',jsonb_build_object(
      'companies',(SELECT count(*) FROM public.companies),
      'scopedCompanies',(SELECT count(DISTINCT company_id) FROM public.organisation_company_scopes WHERE scope_kind='CAMPAIGN'),
      'people',(SELECT count(*) FROM public.people),
      'latestCompanyAt',(SELECT max(created_at) FROM public.companies),
      'latestPersonAt',(SELECT max(created_at) FROM public.people)
    ),
    'research',jsonb_build_object(
      'plans',(SELECT count(*) FROM public.research_plan_runs),
      'workUnits',(SELECT count(*) FROM public.research_work_units),
      'pending',(SELECT count(*) FROM public.background_jobs WHERE job_type='GENESIS_RESEARCH_V1' AND status IN ('PENDING','DEFERRED')),
      'running',(SELECT count(*) FROM public.background_jobs WHERE job_type='GENESIS_RESEARCH_V1' AND status IN ('RESERVED','RUNNING')),
      'succeeded',(SELECT count(*) FROM public.background_jobs WHERE job_type='GENESIS_RESEARCH_V1' AND status='SUCCEEDED'),
      'failed',(SELECT count(*) FROM public.background_jobs WHERE job_type='GENESIS_RESEARCH_V1' AND status='FAILED'),
      'dailyBudgetUsd',(SELECT COALESCE(sum(daily_budget_usd),0) FROM public.research_budget_policies WHERE enabled),
      'spentUsd',(SELECT COALESCE(sum(amount_usd),0) FROM public.research_budget_events WHERE event_type='COMMIT'),
      'spentTodayUsd',(SELECT COALESCE(sum(amount_usd),0) FROM public.research_budget_events WHERE event_type='COMMIT' AND occurred_at>=v_day_start),
      'latestPlanAt',(SELECT max(created_at) FROM public.research_plan_runs),
      'latestWorkAt',(SELECT max(updated_at) FROM public.background_jobs WHERE job_type='GENESIS_RESEARCH_V1'),
      'latestScheduler',(
        SELECT COALESCE(jsonb_build_object('status',status,'startedAt',started_at,'completedAt',completed_at,'metadata',metadata_json),'{}'::jsonb)
        FROM public.scheduler_runs WHERE runner_key='GENESIS_RESEARCH_V1' ORDER BY started_at DESC LIMIT 1
      )
    ),
    'evidence',jsonb_build_object(
      'sources',(SELECT count(*) FROM public.source_records),
      'acquisitions',(SELECT count(*) FROM public.source_acquisitions),
      'items',(SELECT count(*) FROM public.evidence_items),
      'claims',(SELECT count(*) FROM public.claims),
      'links',(SELECT count(*) FROM public.claim_evidence_links),
      'latestAt',(SELECT max(created_at) FROM public.evidence_items)
    ),
    'truth',jsonb_build_object(
      'claimSnapshots',(SELECT count(*) FROM public.truth_claim_snapshots),
      'entitySnapshots',(SELECT count(*) FROM public.truth_entity_snapshots),
      'researchedCompanies',(SELECT count(DISTINCT subject_id) FROM public.truth_entity_snapshots WHERE subject_type='COMPANY'),
      'knownOrSupportedCompanies',(SELECT count(DISTINCT subject_id) FROM public.truth_entity_snapshots WHERE subject_type='COMPANY' AND entity_state IN ('KNOWN','SUPPORTED')),
      'latestAt',(SELECT max(created_at) FROM public.truth_entity_snapshots)
    ),
    'r4',jsonb_build_object(
      'records',(SELECT count(*) FROM public.commercial_reality_r4_records),
      'companies',(SELECT count(DISTINCT company_id) FROM public.commercial_reality_r4_records),
      'candidates',(SELECT count(DISTINCT company_id) FROM public.commercial_reality_r4_records WHERE decision_code='COMMERCIAL_CANDIDATE'),
      'researchRequired',(SELECT count(DISTINCT company_id) FROM public.commercial_reality_r4_records WHERE decision_code='RESEARCH_REQUIRED'),
      'notAdmissible',(SELECT count(DISTINCT company_id) FROM public.commercial_reality_r4_records WHERE decision_code='NOT_ADMISSIBLE'),
      'latestAt',(SELECT max(created_at) FROM public.commercial_reality_r4_records)
    ),
    'r5',jsonb_build_object(
      'records',(SELECT count(*) FROM public.route_authority_r5_records),
      'relationships',(SELECT count(*) FROM public.commercial_relationships),
      'graphNodes',(SELECT count(*) FROM public.commercial_graph_nodes),
      'reachableCompanies',(SELECT count(DISTINCT company_id) FROM public.route_authority_r5_records WHERE decision_code='ROUTE_STRUCTURALLY_OPEN'),
      'researchRequired',(SELECT count(DISTINCT company_id) FROM public.route_authority_r5_records WHERE decision_code='ROUTE_RESEARCH_REQUIRED'),
      'latestAt',(SELECT max(created_at) FROM public.route_authority_r5_records)
    ),
    'r6',jsonb_build_object(
      'records',(SELECT count(*) FROM public.contact_authority_r6_records),
      'contactQualifiedCompanies',(SELECT count(DISTINCT company_id) FROM public.contact_authority_r6_records WHERE decision_code='CONTACT_AUTHORISED'),
      'authorisedAccessPoints',(SELECT COALESCE(sum(distinct_authorised_access_point_count),0) FROM public.contact_authority_r6_records WHERE decision_code='CONTACT_AUTHORISED'),
      'researchRequired',(SELECT count(DISTINCT company_id) FROM public.contact_authority_r6_records WHERE decision_code='CONTACT_RESEARCH_REQUIRED'),
      'latestAt',(SELECT max(created_at) FROM public.contact_authority_r6_records)
    ),
    'opportunity',jsonb_build_object(
      'total',(SELECT count(*) FROM public.opportunities WHERE workflow_state<>'ARCHIVED'),
      'researching',(SELECT count(*) FROM public.opportunities WHERE workflow_state='RESEARCHING'),
      'reviewable',(SELECT count(*) FROM public.opportunities WHERE workflow_state='REVIEWABLE'),
      'approved',(SELECT count(*) FROM public.opportunities WHERE workflow_state='APPROVED'),
      'engaged',(SELECT count(*) FROM public.opportunities WHERE workflow_state='ENGAGED'),
      'rejected',(SELECT count(*) FROM public.opportunities WHERE workflow_state='REJECTED'),
      'syncEvents',(SELECT count(*) FROM public.opportunity_sync_events),
      'latestAt',(SELECT max(updated_at) FROM public.opportunities)
    ),
    'engagement',jsonb_build_object(
      'strategies',(SELECT count(*) FROM public.engagement_strategies),
      'messages',(SELECT count(*) FROM public.engagement_messages),
      'reviews',(SELECT count(*) FROM public.engagement_ai_reviews),
      'reviewPass',(SELECT count(*) FROM public.engagement_ai_reviews WHERE verdict='PASS'),
      'reviewRewrite',(SELECT count(*) FROM public.engagement_ai_reviews WHERE verdict='REWRITE'),
      'reviewBlock',(SELECT count(*) FROM public.engagement_ai_reviews WHERE verdict='BLOCK'),
      'approvals',(SELECT count(*) FROM public.engagement_message_approvals WHERE decision='APPROVE'),
      'queued',(SELECT count(*) FROM public.engagement_queue_items),
      'deliveryPending',(SELECT count(*) FROM public.engagement_delivery_jobs WHERE status='PENDING'),
      'deliverySent',(SELECT count(*) FROM public.engagement_delivery_jobs WHERE status='SENT'),
      'deliveryFailed',(SELECT count(*) FROM public.engagement_delivery_jobs WHERE status='FAILED'),
      'deliveryBlockedStale',(SELECT count(*) FROM public.engagement_delivery_jobs WHERE status='BLOCKED_STALE'),
      'deliveryReconciliation',(SELECT count(*) FROM public.engagement_delivery_jobs WHERE status='RECONCILIATION_REQUIRED'),
      'latestAt',(SELECT max(created_at) FROM public.engagement_messages)
    ),
    'ai',jsonb_build_object(
      'requests',(SELECT count(*) FROM public.ai_usage_events),
      'requests24h',(SELECT count(*) FROM public.ai_usage_events WHERE created_at>=v_24h),
      'success24h',(SELECT count(*) FROM public.ai_usage_events WHERE created_at>=v_24h AND status='SUCCEEDED'),
      'failed24h',(SELECT count(*) FROM public.ai_usage_events WHERE created_at>=v_24h AND status IN ('FAILED','TIMED_OUT','CANCELLED')),
      'inputTokens',(SELECT COALESCE(sum(input_tokens),0) FROM public.ai_usage_events),
      'outputTokens',(SELECT COALESCE(sum(output_tokens),0) FROM public.ai_usage_events),
      'spendUsd',(SELECT COALESCE(sum(cost_usd),0) FROM public.ai_usage_events),
      'spend24hUsd',(SELECT COALESCE(sum(cost_usd),0) FROM public.ai_usage_events WHERE created_at>=v_24h),
      'latestAt',(SELECT max(created_at) FROM public.ai_usage_events),
      'latestModel',(SELECT model FROM public.ai_usage_events ORDER BY created_at DESC,id DESC LIMIT 1)
    )
  );
END;$$;

--
-- Name: marketroute_get_claim_truth_context_v1(uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_get_claim_truth_context_v1(p_claim_id uuid, p_reference_time timestamp with time zone DEFAULT NULL::timestamp with time zone) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_reference timestamptz := COALESCE(p_reference_time, now());
  v_claim public.claims%ROWTYPE;
  v_policy record;
  v_context_fingerprint text;
  v_proposition_fingerprint text;
  v_evidence jsonb;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF v_reference > now() + interval '5 minutes' THEN RAISE EXCEPTION 'MARKETROUTE_TRUTH_REFERENCE_TIME_IN_FUTURE'; END IF;

  SELECT * INTO v_claim FROM public.claims WHERE id = p_claim_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_TRUTH_CLAIM_NOT_FOUND'; END IF;
  IF EXISTS (SELECT 1 FROM public.claim_supersessions WHERE prior_claim_id = p_claim_id) THEN
    RAISE EXCEPTION 'MARKETROUTE_TRUTH_SUPERSEDED_CLAIM_FORBIDDEN';
  END IF;

  SELECT * INTO v_policy
  FROM public.marketroute_truth_policy_for_claim_v1(v_claim.subject_type, v_claim.claim_key);
  IF v_policy.policy_key IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_TRUTH_POLICY_NOT_FOUND'; END IF;

  v_context_fingerprint := public.marketroute_truth_context_fingerprint_v1(p_claim_id, v_reference);
  v_proposition_fingerprint := public.marketroute_truth_proposition_fingerprint_v1(p_claim_id);

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'evidenceItemId', e.id,
    'evidenceFingerprint', e.evidence_fingerprint,
    'polarity', l.polarity,
    'dependenceFamilyKey', l.dependence_family_key,
    'observedAt', e.observed_at,
    'originPublishedAt', e.origin_published_at,
    'sourcePublishedAt', s.published_at
  ) ORDER BY e.evidence_fingerprint, l.polarity), '[]'::jsonb)
  INTO v_evidence
  FROM public.claim_evidence_links l
  JOIN public.evidence_items e ON e.id = l.evidence_item_id
  JOIN public.source_acquisitions a ON a.id = e.acquisition_id
  JOIN public.source_records s ON s.id = a.source_id
  WHERE l.claim_id = p_claim_id;

  RETURN jsonb_build_object(
    'claimId', v_claim.id,
    'tenantScopeOrganisationId', v_claim.tenant_scope_organisation_id,
    'subjectType', v_claim.subject_type,
    'subjectId', v_claim.subject_id,
    'claimKey', v_claim.claim_key,
    'claimFingerprint', v_claim.claim_fingerprint,
    'propositionFingerprint', v_proposition_fingerprint,
    'referenceTime', v_reference,
    'contextFingerprint', v_context_fingerprint,
    'policy', jsonb_build_object(
      'policyKey', v_policy.policy_key,
      'policyVersion', v_policy.policy_version,
      'maxAgeDays', v_policy.max_age_days,
      'knownSupportFamilyRequirement', v_policy.known_support_family_requirement
    ),
    'evidence', v_evidence
  );
END;
$$;

--
-- Name: marketroute_get_current_campaign_seller_context_v1(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_get_current_campaign_seller_context_v1(p_organisation_id uuid, p_campaign_id uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.campaigns WHERE id = p_campaign_id AND organisation_id = p_organisation_id) THEN
    RAISE EXCEPTION 'MARKETROUTE_SELLER_CONTEXT_CAMPAIGN_SCOPE_INVALID';
  END IF;
  SELECT jsonb_build_object(
    'selectionId', s.id,
    'organisationId', s.organisation_id,
    'campaignId', s.campaign_id,
    'sellerBusinessId', s.seller_business_id,
    'genomeSnapshotId', s.genome_snapshot_id,
    'objectiveKey', s.objective_key,
    'selectionRequestId', s.selection_request_id,
    'inputFingerprint', s.input_fingerprint,
    'semanticContextFingerprint', s.semantic_context_fingerprint,
    'semanticFingerprint', g.semantic_fingerprint,
    'contentFingerprint', g.content_fingerprint,
    'semanticCompleteness', g.semantic_completeness,
    'missingDimensions', to_jsonb(g.missing_dimensions),
    'canonicalGenome', g.canonical_genome_json,
    'createdAt', s.created_at
  ) INTO v_result
  FROM public.campaign_seller_context_selections s
  JOIN public.seller_commercial_genome_snapshots g ON g.id = s.genome_snapshot_id
  WHERE s.organisation_id = p_organisation_id AND s.campaign_id = p_campaign_id
  ORDER BY s.created_at DESC, s.id DESC
  LIMIT 1;
  RETURN v_result;
END;
$$;

--
-- Name: marketroute_get_entity_truth_context_v1(uuid, text, uuid, text, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_get_entity_truth_context_v1(p_tenant_scope_organisation_id uuid, p_subject_type text, p_subject_id uuid, p_profile_key text, p_reference_time timestamp with time zone DEFAULT NULL::timestamp with time zone) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_reference timestamptz := COALESCE(p_reference_time, now());
  v_profile public.truth_entity_profile_registry%ROWTYPE;
  v_claims jsonb;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF v_reference > now() + interval '5 minutes' THEN RAISE EXCEPTION 'MARKETROUTE_TRUTH_REFERENCE_TIME_IN_FUTURE'; END IF;

  SELECT * INTO v_profile
  FROM public.truth_entity_profile_registry
  WHERE profile_key = p_profile_key AND active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_TRUTH_ENTITY_PROFILE_NOT_FOUND'; END IF;
  IF v_profile.subject_type IS DISTINCT FROM p_subject_type THEN RAISE EXCEPTION 'MARKETROUTE_TRUTH_ENTITY_PROFILE_SUBJECT_MISMATCH'; END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'claimKey', key.value,
    'claimIds', COALESCE((
      SELECT jsonb_agg(c.id ORDER BY c.created_at, c.id)
      FROM public.claims c
      WHERE c.subject_type = p_subject_type
        AND c.subject_id = p_subject_id
        AND c.claim_key = key.value
        AND (
          (p_tenant_scope_organisation_id IS NULL AND c.tenant_scope_organisation_id IS NULL)
          OR (p_tenant_scope_organisation_id IS NOT NULL AND (c.tenant_scope_organisation_id IS NULL OR c.tenant_scope_organisation_id = p_tenant_scope_organisation_id))
        )
        AND NOT EXISTS (SELECT 1 FROM public.claim_supersessions s WHERE s.prior_claim_id = c.id)
    ), '[]'::jsonb)
  ) ORDER BY key.ordinality), '[]'::jsonb)
  INTO v_claims
  FROM jsonb_array_elements_text(v_profile.required_claim_keys) WITH ORDINALITY AS key(value, ordinality);

  RETURN jsonb_build_object(
    'tenantScopeOrganisationId', p_tenant_scope_organisation_id,
    'subjectType', p_subject_type,
    'subjectId', p_subject_id,
    'referenceTime', v_reference,
    'profile', jsonb_build_object(
      'profileKey', v_profile.profile_key,
      'profileVersion', v_profile.profile_version,
      'subjectType', v_profile.subject_type,
      'requiredClaimKeys', v_profile.required_claim_keys
    ),
    'claims', v_claims
  );
END;
$$;

--
-- Name: marketroute_get_r4_context_v1(uuid, uuid, uuid, timestamp with time zone, uuid, uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_get_r4_context_v1(p_organisation_id uuid, p_campaign_id uuid, p_company_id uuid, p_reference_time timestamp with time zone, p_seller_context_selection_id uuid, p_target_truth_entity_snapshot_id uuid, p_constraint_truth_snapshot_map jsonb) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_selection public.campaign_seller_context_selections%ROWTYPE;
  v_latest_selection_id uuid;
  v_genome public.seller_commercial_genome_snapshots%ROWTYPE;
  v_entity public.truth_entity_snapshots%ROWTYPE;
  v_core_claims jsonb := '{}'::jsonb;
  v_constraint_claims jsonb := '{}'::jsonb;
  v_key text;
  v_ids jsonb;
  v_snapshot public.truth_claim_snapshots%ROWTYPE;
  v_expected_constraint_keys text[] := ARRAY[]::text[];
  v_supplied_constraint_keys text[] := ARRAY[]::text[];
  v_expected_claim_count integer;
  v_included_claim_count integer;
  v_latest_entity_id uuid;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF p_reference_time > now() + interval '5 minutes' THEN RAISE EXCEPTION 'MARKETROUTE_R4_REFERENCE_TIME_IN_FUTURE'; END IF;
  IF p_reference_time < now() - interval '15 minutes' THEN RAISE EXCEPTION 'MARKETROUTE_R4_REFERENCE_TIME_TOO_OLD_FOR_AUTHORITY'; END IF;
  IF jsonb_typeof(p_constraint_truth_snapshot_map) <> 'object' THEN RAISE EXCEPTION 'MARKETROUTE_R4_CONSTRAINT_SNAPSHOT_MAP_REQUIRED'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.organisation_company_scopes
    WHERE organisation_id = p_organisation_id AND company_id = p_company_id AND campaign_id = p_campaign_id AND scope_kind = 'CAMPAIGN'
  ) THEN RAISE EXCEPTION 'MARKETROUTE_R4_COMPANY_NOT_IN_CAMPAIGN_SCOPE'; END IF;

  SELECT id INTO v_latest_selection_id
  FROM public.campaign_seller_context_selections
  WHERE organisation_id = p_organisation_id AND campaign_id = p_campaign_id
  ORDER BY created_at DESC, id DESC LIMIT 1;
  IF v_latest_selection_id IS NULL OR v_latest_selection_id <> p_seller_context_selection_id THEN
    RAISE EXCEPTION 'MARKETROUTE_R4_SELLER_CONTEXT_NOT_CURRENT';
  END IF;

  SELECT * INTO v_selection FROM public.campaign_seller_context_selections WHERE id = p_seller_context_selection_id;
  SELECT * INTO v_genome FROM public.seller_commercial_genome_snapshots WHERE id = v_selection.genome_snapshot_id;
  IF v_selection.organisation_id <> p_organisation_id OR v_selection.campaign_id <> p_campaign_id THEN RAISE EXCEPTION 'MARKETROUTE_R4_SELLER_CONTEXT_SCOPE_MISMATCH'; END IF;

  SELECT * INTO v_entity FROM public.truth_entity_snapshots WHERE id = p_target_truth_entity_snapshot_id;
  IF NOT FOUND OR v_entity.subject_type <> 'COMPANY' OR v_entity.subject_id <> p_company_id
     OR v_entity.profile_key <> 'COMPANY_CORE_V1'
     OR v_entity.tenant_scope_organisation_id IS DISTINCT FROM p_organisation_id
     OR v_entity.reference_time IS DISTINCT FROM p_reference_time
     OR v_entity.semantics_version <> 'MRV2-TRUTH-SEM-1.0.0' THEN
    RAISE EXCEPTION 'MARKETROUTE_R4_TARGET_ENTITY_TRUTH_SCOPE_MISMATCH';
  END IF;

  SELECT id INTO v_latest_entity_id
  FROM public.truth_entity_snapshots
  WHERE tenant_scope_organisation_id IS NOT DISTINCT FROM p_organisation_id
    AND subject_type='COMPANY' AND subject_id=p_company_id AND profile_key='COMPANY_CORE_V1'
    AND reference_time=p_reference_time
  ORDER BY created_at DESC,id DESC LIMIT 1;
  IF v_latest_entity_id IS DISTINCT FROM p_target_truth_entity_snapshot_id THEN
    RAISE EXCEPTION 'MARKETROUTE_R4_TARGET_ENTITY_TRUTH_NOT_LATEST';
  END IF;

  SELECT COALESCE(array_agg(DISTINCT claim_key ORDER BY claim_key), ARRAY[]::text[])
  INTO v_expected_constraint_keys
  FROM (
    SELECT public.marketroute_r4_hard_constraint_claim_key_v1(x.value->>'constraintType') AS claim_key
    FROM jsonb_array_elements(v_genome.canonical_genome_json #> '{semantic,constraints,items}') x(value)
    WHERE x.value->>'mode'='HARD'
  ) q
  WHERE claim_key IS NOT NULL;
  SELECT COALESCE(array_agg(key ORDER BY key), ARRAY[]::text[]) INTO v_supplied_constraint_keys
  FROM jsonb_object_keys(p_constraint_truth_snapshot_map) k(key);
  IF v_supplied_constraint_keys IS DISTINCT FROM v_expected_constraint_keys THEN
    RAISE EXCEPTION 'MARKETROUTE_R4_CONSTRAINT_SNAPSHOT_MAP_KEYS_MISMATCH';
  END IF;

  FOREACH v_key IN ARRAY ARRAY['identity.canonical_name','identity.canonical_domain','operation.current'] LOOP
    v_ids := COALESCE(v_entity.claim_snapshot_map -> v_key, '[]'::jsonb);
    v_core_claims := v_core_claims || jsonb_build_object(v_key, COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'snapshotId', t.id,
        'snapshotFingerprint', t.snapshot_fingerprint,
        'claimId', t.claim_id,
        'claimKey', t.claim_key,
        'propositionFingerprint', t.proposition_fingerprint,
        'truthState', t.truth_state,
        'canonicalValueText', c.canonical_value_text,
        'objectJson', c.object_json,
        'nextRevalidationAt', t.next_revalidation_at
      ) ORDER BY t.id::text)
      FROM public.truth_claim_snapshots t JOIN public.claims c ON c.id = t.claim_id
      WHERE t.id IN (SELECT value::uuid FROM jsonb_array_elements_text(v_ids) x(value))
    ), '[]'::jsonb));
  END LOOP;

  FOR v_key IN SELECT key FROM jsonb_object_keys(p_constraint_truth_snapshot_map) k(key) ORDER BY key LOOP
    v_ids := p_constraint_truth_snapshot_map -> v_key;
    IF jsonb_typeof(v_ids) <> 'array' THEN RAISE EXCEPTION 'MARKETROUTE_R4_CONSTRAINT_SNAPSHOT_IDS_ARRAY_REQUIRED'; END IF;
    FOR v_snapshot IN SELECT * FROM public.truth_claim_snapshots WHERE id IN (SELECT value::uuid FROM jsonb_array_elements_text(v_ids) x(value)) LOOP
      IF v_snapshot.subject_type <> 'COMPANY' OR v_snapshot.subject_id <> p_company_id OR v_snapshot.claim_key <> v_key
         OR v_snapshot.reference_time IS DISTINCT FROM p_reference_time
         OR (v_snapshot.tenant_scope_organisation_id IS NOT NULL AND v_snapshot.tenant_scope_organisation_id <> p_organisation_id) THEN
        RAISE EXCEPTION 'MARKETROUTE_R4_CONSTRAINT_TRUTH_SCOPE_MISMATCH';
      END IF;
    END LOOP;
    IF (SELECT count(*) FROM public.truth_claim_snapshots WHERE id IN (SELECT value::uuid FROM jsonb_array_elements_text(v_ids) x(value))) <> jsonb_array_length(v_ids) THEN
      RAISE EXCEPTION 'MARKETROUTE_R4_CONSTRAINT_TRUTH_SNAPSHOT_NOT_FOUND';
    END IF;

    SELECT count(*) INTO v_expected_claim_count
    FROM public.claims c
    WHERE c.subject_type='COMPANY' AND c.subject_id=p_company_id AND c.claim_key=v_key
      AND (c.tenant_scope_organisation_id IS NULL OR c.tenant_scope_organisation_id=p_organisation_id)
      AND NOT EXISTS (SELECT 1 FROM public.claim_supersessions cs WHERE cs.prior_claim_id=c.id);
    SELECT count(DISTINCT t.claim_id) INTO v_included_claim_count
    FROM public.truth_claim_snapshots t
    WHERE t.id IN (SELECT value::uuid FROM jsonb_array_elements_text(v_ids) x(value));
    IF v_included_claim_count IS DISTINCT FROM v_expected_claim_count THEN
      RAISE EXCEPTION 'MARKETROUTE_R4_CONSTRAINT_ACTIVE_CLAIM_SET_INCOMPLETE';
    END IF;
    IF EXISTS (
      SELECT 1
      FROM public.truth_claim_snapshots t
      WHERE t.id IN (SELECT value::uuid FROM jsonb_array_elements_text(v_ids) x(value))
        AND t.id IS DISTINCT FROM (
          SELECT t2.id FROM public.truth_claim_snapshots t2
          WHERE t2.claim_id=t.claim_id AND t2.reference_time=p_reference_time
          ORDER BY t2.created_at DESC,t2.id DESC LIMIT 1
        )
    ) THEN RAISE EXCEPTION 'MARKETROUTE_R4_CONSTRAINT_TRUTH_NOT_LATEST'; END IF;

    v_constraint_claims := v_constraint_claims || jsonb_build_object(v_key, COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'snapshotId', t.id,
        'snapshotFingerprint', t.snapshot_fingerprint,
        'claimId', t.claim_id,
        'claimKey', t.claim_key,
        'propositionFingerprint', t.proposition_fingerprint,
        'truthState', t.truth_state,
        'canonicalValueText', c.canonical_value_text,
        'objectJson', c.object_json,
        'nextRevalidationAt', t.next_revalidation_at
      ) ORDER BY t.id::text)
      FROM public.truth_claim_snapshots t JOIN public.claims c ON c.id = t.claim_id
      WHERE t.id IN (SELECT value::uuid FROM jsonb_array_elements_text(v_ids) x(value))
    ), '[]'::jsonb));
  END LOOP;

  RETURN jsonb_build_object(
    'organisationId', p_organisation_id,
    'campaignId', p_campaign_id,
    'companyId', p_company_id,
    'referenceTime', to_char(p_reference_time AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    'seller', jsonb_build_object(
      'selectionId', v_selection.id,
      'semanticContextFingerprint', v_selection.semantic_context_fingerprint,
      'semanticCompleteness', v_genome.semantic_completeness,
      'objectiveKey', v_selection.objective_key,
      'semantic', public.marketroute_seller_genome_semantic_identity_v1(v_genome.canonical_genome_json)
    ),
    'targetTruth', jsonb_build_object(
      'entitySnapshotId', v_entity.id,
      'entitySnapshotFingerprint', v_entity.snapshot_fingerprint,
      'entityState', v_entity.entity_state,
      'nextRevalidationAt', v_entity.next_revalidation_at,
      'coreClaims', v_core_claims,
      'constraintClaims', v_constraint_claims
    )
  );
END;
$$;

--
-- Name: marketroute_get_r4_target_claim_ids_v1(uuid, uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_get_r4_target_claim_ids_v1(p_organisation_id uuid, p_company_id uuid, p_claim_keys jsonb) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_result jsonb := '{}'::jsonb;
  v_key text;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF jsonb_typeof(p_claim_keys) <> 'array' THEN RAISE EXCEPTION 'MARKETROUTE_R4_CLAIM_KEYS_ARRAY_REQUIRED'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.organisation_company_scopes WHERE organisation_id = p_organisation_id AND company_id = p_company_id) THEN
    RAISE EXCEPTION 'MARKETROUTE_R4_COMPANY_NOT_IN_ORGANISATION_SCOPE';
  END IF;

  FOR v_key IN SELECT DISTINCT value FROM jsonb_array_elements_text(p_claim_keys) x(value) ORDER BY value LOOP
    v_result := v_result || jsonb_build_object(v_key, COALESCE((
      SELECT jsonb_agg(c.id::text ORDER BY c.id::text)
      FROM public.claims c
      WHERE c.subject_type = 'COMPANY'
        AND c.subject_id = p_company_id
        AND c.claim_key = v_key
        AND (c.tenant_scope_organisation_id IS NULL OR c.tenant_scope_organisation_id = p_organisation_id)
        AND NOT EXISTS (SELECT 1 FROM public.claim_supersessions s WHERE s.prior_claim_id = c.id)
    ), '[]'::jsonb));
  END LOOP;
  RETURN v_result;
END;
$$;

--
-- Name: marketroute_get_r5_context_v1(uuid, uuid, uuid, timestamp with time zone, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_get_r5_context_v1(p_organisation_id uuid, p_campaign_id uuid, p_company_id uuid, p_reference_time timestamp with time zone, p_relationship_truth_snapshot_map jsonb) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_r4 record; v_target uuid; v_universe text; v_expected_keys text[]; v_given_keys text[]; v_nodes jsonb; v_relationships jsonb; v_objective text;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF (SELECT count(*) FROM public.marketroute_r5_universe_v1(p_organisation_id,p_company_id))>128 THEN RAISE EXCEPTION 'MARKETROUTE_R5_RELATIONSHIP_UNIVERSE_LIMIT_EXCEEDED'; END IF;
  IF jsonb_typeof(p_relationship_truth_snapshot_map)<>'object' THEN RAISE EXCEPTION 'MARKETROUTE_R5_SNAPSHOT_MAP_INVALID'; END IF;
  SELECT r.authority_record_id,a.authority_fingerprint,a.valid_until,a.decision_code INTO v_r4
  FROM public.commercial_reality_r4_records r JOIN public.authority_records a ON a.id=r.authority_record_id
  WHERE r.organisation_id=p_organisation_id AND r.campaign_id=p_campaign_id AND r.company_id=p_company_id AND public.marketroute_r4_authority_current_v1(a.id,p_reference_time)
  ORDER BY r.created_at DESC,r.id DESC LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_R5_CURRENT_R4_REQUIRED'; END IF;
  v_target:=public.marketroute_r5_target_node_v1(p_company_id); IF v_target IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_R5_TARGET_NODE_REQUIRED'; END IF;
  SELECT array_agg(relationship_id::text ORDER BY relationship_id::text) INTO v_expected_keys FROM public.marketroute_r5_universe_v1(p_organisation_id,p_company_id);
  SELECT array_agg(key ORDER BY key) INTO v_given_keys FROM jsonb_object_keys(p_relationship_truth_snapshot_map) key;
  IF COALESCE(v_expected_keys,'{}'::text[]) IS DISTINCT FROM COALESCE(v_given_keys,'{}'::text[]) THEN RAISE EXCEPTION 'MARKETROUTE_R5_RELATIONSHIP_UNIVERSE_OMISSION'; END IF;
  IF EXISTS(
    SELECT 1 FROM public.commercial_relationships r
    JOIN LATERAL (SELECT (p_relationship_truth_snapshot_map->>r.id::text)::uuid sid) x ON true
    LEFT JOIN public.truth_claim_snapshots ts ON ts.id=x.sid
    WHERE r.id IN (SELECT relationship_id FROM public.marketroute_r5_universe_v1(p_organisation_id,p_company_id))
      AND (ts.id IS NULL OR ts.claim_id<>r.claim_id OR ts.subject_type<>'RELATIONSHIP' OR ts.subject_id<>r.id OR ts.reference_time<>p_reference_time OR ts.input_fingerprint<>public.marketroute_truth_context_fingerprint_v1(r.claim_id,p_reference_time))
  ) THEN RAISE EXCEPTION 'MARKETROUTE_R5_RELATIONSHIP_TRUTH_SNAPSHOT_INVALID'; END IF;
  v_universe:=public.marketroute_r5_universe_fingerprint_v1(p_organisation_id,p_company_id);
  SELECT s.objective_key INTO v_objective FROM public.campaign_seller_context_selections s WHERE s.organisation_id=p_organisation_id AND s.campaign_id=p_campaign_id ORDER BY s.created_at DESC,s.id DESC LIMIT 1;
  WITH ids AS (
    SELECT v_target id UNION SELECT r.from_node_id FROM public.commercial_relationships r WHERE r.id IN (SELECT relationship_id FROM public.marketroute_r5_universe_v1(p_organisation_id,p_company_id)) UNION SELECT r.to_node_id FROM public.commercial_relationships r WHERE r.id IN (SELECT relationship_id FROM public.marketroute_r5_universe_v1(p_organisation_id,p_company_id))
  ) SELECT COALESCE(jsonb_agg(jsonb_build_object('nodeId',n.id,'nodeFingerprint',n.node_fingerprint,'nodeKind',n.node_kind,'label',n.label,'accessPointKind',n.access_point_kind,'canonicalValue',n.canonical_value) ORDER BY n.node_fingerprint),'[]'::jsonb) INTO v_nodes FROM public.commercial_graph_nodes n WHERE n.id IN(SELECT id FROM ids);
  SELECT COALESCE(jsonb_agg(jsonb_build_object('relationshipId',r.id,'relationshipFingerprint',r.relationship_fingerprint,'relationType',r.relation_type,'edgeClass',t.edge_class,'direction',t.direction,'routeTraversable',t.route_traversable,'fromNodeId',r.from_node_id,'toNodeId',r.to_node_id,'claimId',r.claim_id,'truth',jsonb_build_object('snapshotId',ts.id,'snapshotFingerprint',ts.snapshot_fingerprint,'truthState',ts.truth_state,'nextRevalidationAt',ts.next_revalidation_at)) ORDER BY r.relationship_fingerprint),'[]'::jsonb) INTO v_relationships
  FROM public.commercial_relationships r JOIN public.commercial_relationship_type_registry t ON t.relation_type=r.relation_type JOIN public.truth_claim_snapshots ts ON ts.id=(p_relationship_truth_snapshot_map->>r.id::text)::uuid
  WHERE r.id IN(SELECT relationship_id FROM public.marketroute_r5_universe_v1(p_organisation_id,p_company_id));
  RETURN jsonb_build_object('organisationId',p_organisation_id,'campaignId',p_campaign_id,'companyId',p_company_id,'referenceTime',p_reference_time,'objectiveKey',v_objective,'targetNodeId',v_target,'relationshipUniverseFingerprint',v_universe,'nodes',v_nodes,'relationships',v_relationships,'parentR4',jsonb_build_object('authorityRecordId',v_r4.authority_record_id,'authorityFingerprint',v_r4.authority_fingerprint,'decisionCode',v_r4.decision_code,'validUntil',v_r4.valid_until,'current',true));
END; $$;

--
-- Name: marketroute_get_r5_relationship_claim_ids_v1(uuid, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_get_r5_relationship_claim_ids_v1(p_organisation_id uuid, p_campaign_id uuid, p_company_id uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_result jsonb;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF NOT EXISTS(SELECT 1 FROM public.organisation_company_scopes s WHERE s.organisation_id=p_organisation_id AND s.campaign_id=p_campaign_id AND s.company_id=p_company_id) THEN RAISE EXCEPTION 'MARKETROUTE_R5_COMPANY_NOT_IN_CAMPAIGN_SCOPE'; END IF;
  IF (SELECT count(*) FROM public.marketroute_r5_universe_v1(p_organisation_id,p_company_id))>128 THEN RAISE EXCEPTION 'MARKETROUTE_R5_RELATIONSHIP_UNIVERSE_LIMIT_EXCEEDED'; END IF;
  SELECT COALESCE(jsonb_object_agg(r.id::text,r.claim_id::text ORDER BY r.id::text),'{}'::jsonb) INTO v_result
  FROM public.commercial_relationships r WHERE r.id IN (SELECT relationship_id FROM public.marketroute_r5_universe_v1(p_organisation_id,p_company_id));
  RETURN v_result;
END; $$;

--
-- Name: marketroute_get_r6_contact_claim_ids_v1(uuid, uuid, uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_get_r6_contact_claim_ids_v1(p_organisation_id uuid, p_campaign_id uuid, p_company_id uuid, p_reference_time timestamp with time zone) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_r5 uuid; v_result jsonb;
BEGIN
 PERFORM public.marketroute_require_service_role();
 v_r5:=public.marketroute_r6_current_r5_record_v1(p_organisation_id,p_campaign_id,p_company_id,p_reference_time);
 IF v_r5 IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_R6_CURRENT_R5_REQUIRED'; END IF;
 SELECT COALESCE(jsonb_object_agg(claim_id::text,claim_id::text ORDER BY claim_id::text),'{}'::jsonb) INTO v_result FROM public.marketroute_r6_claim_universe_v1(p_organisation_id,v_r5);
 RETURN v_result;
END $$;

--
-- Name: marketroute_get_r6_context_v1(uuid, uuid, uuid, timestamp with time zone, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_get_r6_context_v1(p_organisation_id uuid, p_campaign_id uuid, p_company_id uuid, p_reference_time timestamp with time zone, p_contact_truth_snapshot_map jsonb) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_r5_id uuid; v_r5 public.route_authority_r5_records%ROWTYPE; v_auth public.authority_records%ROWTYPE; v_expected text[]; v_given text[]; v_universe text; v_paths jsonb;
BEGIN
 PERFORM public.marketroute_require_service_role();
 IF jsonb_typeof(p_contact_truth_snapshot_map)<>'object' THEN RAISE EXCEPTION 'MARKETROUTE_R6_SNAPSHOT_MAP_INVALID'; END IF;
 v_r5_id:=public.marketroute_r6_current_r5_record_v1(p_organisation_id,p_campaign_id,p_company_id,p_reference_time); IF v_r5_id IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_R6_CURRENT_R5_REQUIRED'; END IF;
 SELECT * INTO v_r5 FROM public.route_authority_r5_records WHERE id=v_r5_id; SELECT * INTO v_auth FROM public.authority_records WHERE id=v_r5.authority_record_id;
 SELECT array_agg(claim_id::text ORDER BY claim_id::text) INTO v_expected FROM public.marketroute_r6_claim_universe_v1(p_organisation_id,v_r5_id); SELECT array_agg(key ORDER BY key) INTO v_given FROM jsonb_object_keys(p_contact_truth_snapshot_map) key;
 IF COALESCE(v_expected,'{}'::text[]) IS DISTINCT FROM COALESCE(v_given,'{}'::text[]) THEN RAISE EXCEPTION 'MARKETROUTE_R6_CONTACT_CLAIM_UNIVERSE_OMISSION'; END IF;
 IF EXISTS(SELECT 1 FROM public.claims c LEFT JOIN public.truth_claim_snapshots ts ON ts.id=(p_contact_truth_snapshot_map->>c.id::text)::uuid WHERE c.id IN(SELECT claim_id FROM public.marketroute_r6_claim_universe_v1(p_organisation_id,v_r5_id)) AND (ts.id IS NULL OR ts.claim_id<>c.id OR ts.reference_time<>p_reference_time OR ts.input_fingerprint<>public.marketroute_truth_context_fingerprint_v1(c.id,p_reference_time))) THEN RAISE EXCEPTION 'MARKETROUTE_R6_CONTACT_TRUTH_SNAPSHOT_INVALID'; END IF;
 v_universe:=public.marketroute_r6_claim_universe_fingerprint_v1(p_organisation_id,v_r5_id);
 SELECT COALESCE(jsonb_agg(jsonb_build_object(
   'pathFingerprint',s.path_fingerprint,'terminalAccessPointId',s.terminal_access_point_id,'r5PathState',s.r5_path_state,
   'personId',s.person_id,'expectedPersonName',CASE WHEN s.person_id IS NULL THEN NULL ELSE COALESCE(p.canonical_name,p.display_name) END,
   'personLifecycleState',p.lifecycle_state,'employerCompanyId',s.employer_company_id,'accessPointKind',ap.access_point_kind,'accessPointValue',ap.canonical_value,
   'identityClaims',CASE WHEN s.person_id IS NULL THEN '[]'::jsonb ELSE public.marketroute_r6_claim_refs_v1(p_organisation_id,s.person_id,s.employer_company_id,s.terminal_access_point_id,'IDENTITY',p_contact_truth_snapshot_map) END,
   'employmentClaims',CASE WHEN s.person_id IS NULL THEN '[]'::jsonb ELSE public.marketroute_r6_claim_refs_v1(p_organisation_id,s.person_id,s.employer_company_id,s.terminal_access_point_id,'EMPLOYMENT',p_contact_truth_snapshot_map) END,
   'roleClaims',CASE WHEN s.person_id IS NULL THEN '[]'::jsonb ELSE public.marketroute_r6_claim_refs_v1(p_organisation_id,s.person_id,s.employer_company_id,s.terminal_access_point_id,'ROLE',p_contact_truth_snapshot_map) END,
   'channelOwnershipClaims',CASE WHEN s.person_id IS NULL THEN '[]'::jsonb ELSE public.marketroute_r6_claim_refs_v1(p_organisation_id,s.person_id,s.employer_company_id,s.terminal_access_point_id,'CHANNEL',p_contact_truth_snapshot_map) END
 ) ORDER BY s.path_fingerprint),'[]'::jsonb) INTO v_paths
 FROM public.marketroute_r6_path_structure_v1(v_r5_id) s LEFT JOIN public.people p ON p.id=s.person_id LEFT JOIN public.commercial_graph_nodes ap ON ap.id=s.terminal_access_point_id;
 RETURN jsonb_build_object('organisationId',p_organisation_id,'campaignId',p_campaign_id,'companyId',p_company_id,'referenceTime',p_reference_time,'contactClaimUniverseFingerprint',v_universe,'paths',v_paths,'parentR5',jsonb_build_object('authorityRecordId',v_auth.id,'authorityFingerprint',v_auth.authority_fingerprint,'decisionCode',v_auth.decision_code,'validUntil',v_auth.valid_until,'current',true));
END $$;

--
-- Name: marketroute_graph_node_fingerprint_v1(uuid, text, uuid, uuid, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_graph_node_fingerprint_v1(p_tenant_scope_organisation_id uuid, p_node_kind text, p_company_id uuid, p_person_id uuid, p_stable_key text, p_access_point_kind text, p_canonical_value text) RETURNS text
    LANGUAGE sql IMMUTABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  SELECT encode(extensions.digest(concat_ws('|','MRV2-GRAPH-NODE-1.0.0',COALESCE(p_tenant_scope_organisation_id::text,'GLOBAL'),p_node_kind,
    COALESCE(p_company_id::text,'-'),COALESCE(p_person_id::text,'-'),CASE WHEN p_node_kind='ACCESS_POINT' THEN '-' ELSE COALESCE(lower(btrim(p_stable_key)),'-') END,COALESCE(p_access_point_kind,'-'),COALESCE(lower(btrim(p_canonical_value)),'-')),'sha256'),'hex');
$$;

--
-- Name: marketroute_growth_complete_action_v1(uuid, numeric, jsonb, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_growth_complete_action_v1(p_action_run_id uuid, p_actual_cost_usd numeric, p_result jsonb DEFAULT '{}'::jsonb, p_at timestamp with time zone DEFAULT now()) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE r public.genesis_growth_action_runs%ROWTYPE;s public.genesis_growth_settings%ROWTYPE;
BEGIN
 PERFORM public.marketroute_require_service_role(); SELECT * INTO r FROM public.genesis_growth_action_runs WHERE id=p_action_run_id FOR UPDATE; IF NOT FOUND OR r.status<>'RUNNING' THEN RAISE EXCEPTION 'MARKETROUTE_GROWTH_ACTION_NOT_RUNNING'; END IF; SELECT * INTO s FROM public.genesis_growth_settings WHERE singleton=true;
 IF p_actual_cost_usd<0 OR p_actual_cost_usd>s.max_action_cost_usd*2 THEN RAISE EXCEPTION 'MARKETROUTE_GROWTH_ACTION_COST_INVALID'; END IF;
 UPDATE public.genesis_growth_action_runs SET status='SUCCEEDED',actual_cost_usd=p_actual_cost_usd,result_json=COALESCE(p_result,'{}'::jsonb),completed_at=p_at WHERE id=p_action_run_id;
 INSERT INTO public.genesis_growth_budget_events(action_run_id,industry_key,company_id,amount_usd,occurred_at,metadata_json) VALUES(p_action_run_id,r.industry_key,r.company_id,p_actual_cost_usd,p_at,jsonb_build_object('actionKind',r.action_kind,'phase',r.phase));
END;$$;

--
-- Name: marketroute_growth_effective_spend_v1(timestamp with time zone, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_growth_effective_spend_v1(p_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_to timestamp with time zone DEFAULT NULL::timestamp with time zone) RETURNS numeric
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  SELECT COALESCE(sum(GREATEST(COALESCE(ar.actual_cost_usd,0),COALESCE(b.amount_usd,0))),0)::numeric
  FROM public.genesis_growth_action_runs AS ar
  LEFT JOIN public.genesis_growth_budget_events AS b ON b.action_run_id=ar.id
  WHERE (p_from IS NULL OR ar.started_at>=p_from)
    AND (p_to IS NULL OR ar.started_at<p_to);
$$;

--
-- Name: marketroute_growth_ensure_company_v1(text, text, text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_growth_ensure_company_v1(p_industry_key text, p_name text, p_domain text, p_website_url text, p_country_code text, p_discovery_reason text DEFAULT NULL::text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
DECLARE v_domain text:=lower(regexp_replace(btrim(COALESCE(p_domain,'')),'^www\.','','i'));v_company uuid;v_country text;
BEGIN
 PERFORM public.marketroute_require_service_role();
 IF NOT EXISTS(SELECT 1 FROM public.genesis_growth_industries WHERE industry_key=p_industry_key AND enabled) THEN RAISE EXCEPTION 'MARKETROUTE_GROWTH_INDUSTRY_INVALID'; END IF;
 IF v_domain !~ '^[a-z0-9][a-z0-9.-]*\.[a-z]{2,63}$' THEN RAISE EXCEPTION 'MARKETROUTE_GROWTH_COMPANY_DOMAIN_INVALID'; END IF;
 v_country:=CASE WHEN upper(COALESCE(p_country_code,''))~'^[A-Z]{2}$' THEN upper(p_country_code) ELSE NULL END;
 SELECT id INTO v_company FROM public.companies WHERE canonical_domain=v_domain LIMIT 1;
 IF v_company IS NULL THEN INSERT INTO public.companies(canonical_name,canonical_domain,website_url,country_code,lifecycle_state) VALUES(left(btrim(p_name),240),v_domain,COALESCE(nullif(btrim(COALESCE(p_website_url,'')),''),'https://'||v_domain),v_country,'ACTIVE') RETURNING id INTO v_company;
 ELSE UPDATE public.companies SET canonical_name=CASE WHEN length(btrim(COALESCE(p_name,'')))>0 THEN left(btrim(p_name),240) ELSE canonical_name END,website_url=COALESCE(website_url,nullif(btrim(COALESCE(p_website_url,'')),''),'https://'||v_domain),country_code=COALESCE(country_code,v_country),updated_at=now() WHERE id=v_company;
 END IF;
 INSERT INTO public.genesis_growth_company_memberships(industry_key,company_id,discovery_reason) VALUES(p_industry_key,v_company,left(nullif(btrim(COALESCE(p_discovery_reason,'')),''),500)) ON CONFLICT(industry_key,company_id) DO NOTHING;
 INSERT INTO public.genesis_growth_company_progress(company_id) VALUES(v_company) ON CONFLICT(company_id) DO NOTHING;
 RETURN v_company;
END;$_$;

--
-- Name: marketroute_growth_ensure_person_v1(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_growth_ensure_person_v1(p_company_id uuid, p_name text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_name text:=left(btrim(COALESCE(p_name,'')),240);v_key text;v_person uuid;
BEGIN
 PERFORM public.marketroute_require_service_role();
 IF v_name='' OR NOT EXISTS(SELECT 1 FROM public.companies WHERE id=p_company_id) THEN RAISE EXCEPTION 'MARKETROUTE_GROWTH_PERSON_INVALID'; END IF;
 v_key:=encode(extensions.digest(convert_to(p_company_id::text||'|'||lower(regexp_replace(v_name,'\s+',' ','g')),'UTF8'),'sha256'),'hex');
 SELECT person_id INTO v_person FROM public.genesis_growth_people WHERE identity_key=v_key;
 IF v_person IS NULL THEN INSERT INTO public.people(display_name,canonical_name,lifecycle_state) VALUES(v_name,v_name,'ACTIVE') RETURNING id INTO v_person; INSERT INTO public.genesis_growth_people(identity_key,company_id,person_id,canonical_name) VALUES(v_key,p_company_id,v_person,v_name); END IF;
 RETURN v_person;
END;$$;

--
-- Name: marketroute_growth_existing_domains_v1(text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_growth_existing_domains_v1(p_industry_key text, p_limit integer DEFAULT 1000) RETURNS text[]
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v text[];
BEGIN
 PERFORM public.marketroute_require_service_role();
 SELECT COALESCE(array_agg(c.canonical_domain ORDER BY c.canonical_domain),'{}'::text[]) INTO v FROM public.genesis_growth_company_memberships m JOIN public.companies c ON c.id=m.company_id WHERE m.industry_key=p_industry_key AND c.canonical_domain IS NOT NULL LIMIT greatest(1,least(COALESCE(p_limit,1000),5000));
 RETURN v;
END;$$;

--
-- Name: marketroute_growth_fail_action_v1(uuid, text, numeric, timestamp with time zone, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_growth_fail_action_v1(p_action_run_id uuid, p_error_code text, p_actual_cost_usd numeric DEFAULT 0, p_retry_after timestamp with time zone DEFAULT NULL::timestamp with time zone, p_at timestamp with time zone DEFAULT now()) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE r public.genesis_growth_action_runs%ROWTYPE;s public.genesis_growth_settings%ROWTYPE;
BEGIN
 PERFORM public.marketroute_require_service_role(); SELECT * INTO r FROM public.genesis_growth_action_runs WHERE id=p_action_run_id FOR UPDATE; IF NOT FOUND OR r.status<>'RUNNING' THEN RAISE EXCEPTION 'MARKETROUTE_GROWTH_ACTION_NOT_RUNNING'; END IF; SELECT * INTO s FROM public.genesis_growth_settings WHERE singleton=true;
 IF p_actual_cost_usd<0 OR p_actual_cost_usd>s.max_action_cost_usd*2 THEN RAISE EXCEPTION 'MARKETROUTE_GROWTH_ACTION_COST_INVALID'; END IF;
 UPDATE public.genesis_growth_action_runs SET status='FAILED',actual_cost_usd=p_actual_cost_usd,error_code=left(COALESCE(p_error_code,'MARKETROUTE_GROWTH_ACTION_FAILED'),300),completed_at=p_at WHERE id=p_action_run_id;
 INSERT INTO public.genesis_growth_budget_events(action_run_id,industry_key,company_id,amount_usd,occurred_at,metadata_json) VALUES(p_action_run_id,r.industry_key,r.company_id,p_actual_cost_usd,p_at,jsonb_build_object('failed',true,'errorCode',left(COALESCE(p_error_code,''),300)));
 IF r.company_id IS NOT NULL THEN UPDATE public.genesis_growth_company_progress SET retry_after=COALESCE(p_retry_after,p_at+make_interval(hours=>s.retry_hours)),last_error_code=left(COALESCE(p_error_code,''),300),updated_at=p_at WHERE company_id=r.company_id; END IF;
END;$$;

--
-- Name: marketroute_growth_mark_stage_v1(uuid, text, boolean, text, timestamp with time zone, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_growth_mark_stage_v1(p_company_id uuid, p_stage text, p_complete boolean, p_error_code text DEFAULT NULL::text, p_retry_after timestamp with time zone DEFAULT NULL::timestamp with time zone, p_at timestamp with time zone DEFAULT now()) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
 PERFORM public.marketroute_require_service_role();
 INSERT INTO public.genesis_growth_company_progress(company_id) VALUES(p_company_id) ON CONFLICT(company_id) DO NOTHING;
 IF p_stage='CORE' THEN UPDATE public.genesis_growth_company_progress SET core_scan_at=p_at,core_complete_at=CASE WHEN p_complete THEN COALESCE(core_complete_at,p_at) ELSE core_complete_at END,last_researched_at=p_at,retry_after=p_retry_after,last_error_code=left(p_error_code,300),updated_at=p_at WHERE company_id=p_company_id;
 ELSIF p_stage='PROFILE' THEN UPDATE public.genesis_growth_company_progress SET core_scan_at=COALESCE(core_scan_at,p_at),profile_complete_at=CASE WHEN p_complete THEN COALESCE(profile_complete_at,p_at) ELSE profile_complete_at END,last_researched_at=p_at,retry_after=p_retry_after,last_error_code=left(p_error_code,300),updated_at=p_at WHERE company_id=p_company_id;
 ELSIF p_stage='ROUTES' THEN UPDATE public.genesis_growth_company_progress SET routes_scan_at=p_at,routes_complete_at=CASE WHEN p_complete THEN COALESCE(routes_complete_at,p_at) ELSE routes_complete_at END,last_researched_at=p_at,retry_after=p_retry_after,last_error_code=left(p_error_code,300),updated_at=p_at WHERE company_id=p_company_id;
 ELSIF p_stage='CONTACTS' THEN UPDATE public.genesis_growth_company_progress SET contacts_scan_at=p_at,contacts_complete_at=CASE WHEN p_complete THEN COALESCE(contacts_complete_at,p_at) ELSE contacts_complete_at END,last_researched_at=p_at,retry_after=p_retry_after,last_error_code=left(p_error_code,300),updated_at=p_at WHERE company_id=p_company_id;
 ELSE RAISE EXCEPTION 'MARKETROUTE_GROWTH_STAGE_INVALID'; END IF;
END;$$;

--
-- Name: marketroute_growth_next_action_v1(uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_growth_next_action_v1(p_scheduler_run_id uuid, p_at timestamp with time zone DEFAULT now()) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  s public.genesis_growth_settings%ROWTYPE;
  v_day timestamptz:=date_trunc('day',p_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
  v_spent numeric;
  v_phase text;
  v_industry text;
  v_company uuid;
  v_action text;
  v_id uuid;
  v_seed_remaining int;
  v_launch_remaining int;
  v_incomplete int;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF NOT EXISTS(
    SELECT 1
    FROM public.scheduler_runs AS r
    JOIN public.scheduler_leases AS l
      ON l.owner_run_id=r.id AND l.lease_key='GENESIS_DATABASE_GROWTH_V1'
    WHERE r.id=p_scheduler_run_id
      AND r.runner_key='GENESIS_DATABASE_GROWTH_V1'
      AND r.status='RUNNING'
      AND l.expires_at>p_at
  ) THEN RAISE EXCEPTION 'MARKETROUTE_GROWTH_SCHEDULER_RUN_REQUIRED'; END IF;

  SELECT * INTO s FROM public.genesis_growth_settings WHERE singleton=true;
  IF NOT FOUND OR NOT s.enabled THEN RETURN NULL; END IF;

  SELECT public.marketroute_growth_effective_spend_v1(v_day,v_day+interval '1 day') INTO v_spent;
  IF v_spent+s.max_action_cost_usd>s.daily_budget_usd THEN
    RETURN jsonb_build_object('state','BUDGET_EXHAUSTED','spentTodayUsd',v_spent,'dailyBudgetUsd',s.daily_budget_usd);
  END IF;

  SELECT count(*) INTO v_seed_remaining
  FROM public.genesis_growth_industries AS i
  WHERE i.enabled
    AND (SELECT count(*) FROM public.genesis_growth_company_memberships AS m WHERE m.industry_key=i.industry_key)<i.seed_target_company_count;

  SELECT count(*) INTO v_launch_remaining
  FROM public.genesis_growth_industries AS i
  WHERE i.enabled
    AND (SELECT count(*) FROM public.genesis_growth_company_memberships AS m WHERE m.industry_key=i.industry_key)<i.launch_target_company_count;

  -- Recovery remains absolute: never buy more breadth while a paid discovery left a CORE shell
  -- that is currently eligible for repair.
  SELECT p.company_id,m.industry_key
  INTO v_company,v_industry
  FROM public.genesis_growth_company_progress AS p
  JOIN public.genesis_growth_company_memberships AS m ON m.company_id=p.company_id
  WHERE p.core_complete_at IS NULL
    AND (p.retry_after IS NULL OR p.retry_after<=p_at)
  ORDER BY COALESCE(p.last_researched_at,'epoch'::timestamptz),p.created_at,m.industry_key,p.company_id
  LIMIT 1;

  IF v_company IS NOT NULL THEN
    v_phase:=CASE WHEN v_seed_remaining>0 THEN 'SEED' ELSE 'DEPTH' END;
    v_action:='RESEARCH_CORE_PROFILE';

  -- Phase 1: establish a balanced minimum viable bank first.
  ELSIF v_seed_remaining>0 THEN
    v_phase:='SEED';
    SELECT i.industry_key INTO v_industry
    FROM public.genesis_growth_industries AS i
    WHERE i.enabled
      AND (SELECT count(*) FROM public.genesis_growth_company_memberships AS m WHERE m.industry_key=i.industry_key)<i.seed_target_company_count
    ORDER BY ((SELECT count(*) FROM public.genesis_growth_company_memberships AS m WHERE m.industry_key=i.industry_key)::numeric/greatest(1,i.seed_target_company_count)),i.priority DESC,i.industry_key
    LIMIT 1;
    v_action:='DISCOVER_COMPANIES';

  ELSE
    -- Phase 2+: once every industry has its seed floor, depth outranks new breadth.
    -- This makes routes and contacts observable around ~50 companies/industry instead of ~500.
    -- Most-advanced-first ordering finishes PROFILE -> ROUTES -> CONTACTS for a company before
    -- moving on, while retry_after prevents an unavailable route/contact from blocking expansion.
    SELECT count(*) INTO v_incomplete
    FROM public.genesis_growth_company_progress AS p
    WHERE (p.retry_after IS NULL OR p.retry_after<=p_at)
      AND (p.core_complete_at IS NULL OR p.profile_complete_at IS NULL OR p.routes_complete_at IS NULL OR p.contacts_complete_at IS NULL);

    IF v_incomplete>0 THEN
      v_phase:='DEPTH';
      SELECT p.company_id,
             CASE WHEN p.core_complete_at IS NULL OR p.profile_complete_at IS NULL THEN 'RESEARCH_CORE_PROFILE'
                  WHEN p.routes_complete_at IS NULL THEN 'RESEARCH_ROUTES'
                  ELSE 'RESEARCH_CONTACTS' END
      INTO v_company,v_action
      FROM public.genesis_growth_company_progress AS p
      WHERE (p.retry_after IS NULL OR p.retry_after<=p_at)
        AND (p.core_complete_at IS NULL OR p.profile_complete_at IS NULL OR p.routes_complete_at IS NULL OR p.contacts_complete_at IS NULL)
      ORDER BY ((CASE WHEN p.core_complete_at IS NOT NULL THEN 1 ELSE 0 END)
              +(CASE WHEN p.profile_complete_at IS NOT NULL THEN 1 ELSE 0 END)
              +(CASE WHEN p.routes_complete_at IS NOT NULL THEN 1 ELSE 0 END)
              +(CASE WHEN p.contacts_complete_at IS NOT NULL THEN 1 ELSE 0 END)) DESC,
               COALESCE(p.last_researched_at,'epoch'::timestamptz),p.company_id
      LIMIT 1;
      SELECT m.industry_key INTO v_industry
      FROM public.genesis_growth_company_memberships AS m
      WHERE m.company_id=v_company
      ORDER BY m.industry_key LIMIT 1;

    -- Only buy another breadth batch when all currently eligible companies are dense or deferred.
    ELSIF v_launch_remaining>0 THEN
      v_phase:='BREADTH';
      SELECT i.industry_key INTO v_industry
      FROM public.genesis_growth_industries AS i
      WHERE i.enabled
        AND (SELECT count(*) FROM public.genesis_growth_company_memberships AS m WHERE m.industry_key=i.industry_key)<i.launch_target_company_count
      ORDER BY ((SELECT count(*) FROM public.genesis_growth_company_memberships AS m WHERE m.industry_key=i.industry_key)::numeric/greatest(1,i.launch_target_company_count)),i.priority DESC,i.industry_key
      LIMIT 1;
      v_action:='DISCOVER_COMPANIES';

    ELSE
      v_phase:='REFRESH';
      v_action:='REFRESH_CORE';
      SELECT p.company_id INTO v_company
      FROM public.genesis_growth_company_progress AS p
      WHERE COALESCE(p.last_researched_at,'epoch'::timestamptz)<=p_at-make_interval(days=>s.refresh_days)
      ORDER BY COALESCE(p.last_researched_at,'epoch'::timestamptz),p.company_id
      LIMIT 1;
      IF v_company IS NULL THEN RETURN NULL; END IF;
      SELECT m.industry_key INTO v_industry
      FROM public.genesis_growth_company_memberships AS m
      WHERE m.company_id=v_company
      ORDER BY m.industry_key LIMIT 1;
    END IF;
  END IF;

  INSERT INTO public.genesis_growth_action_runs(scheduler_run_id,action_kind,phase,industry_key,company_id,status,started_at)
  VALUES(p_scheduler_run_id,v_action,v_phase,v_industry,v_company,'RUNNING',p_at)
  RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'state','ACTION','actionRunId',v_id,'phase',v_phase,'actionKind',v_action,'industryKey',v_industry,
    'companyId',v_company,'maxActionCostUsd',s.max_action_cost_usd,'discoveryBatchSize',s.discovery_batch_size,
    'retryHours',s.retry_hours
  );
END;
$$;

--
-- Name: marketroute_heartbeat_growth_scheduler_run_v1(uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_heartbeat_growth_scheduler_run_v1(p_scheduler_run_id uuid, p_at timestamp with time zone DEFAULT now()) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
 PERFORM public.marketroute_require_service_role();
 UPDATE public.scheduler_leases SET heartbeat_at=p_at,expires_at=p_at+interval '10 minutes' WHERE lease_key='GENESIS_DATABASE_GROWTH_V1' AND owner_run_id=p_scheduler_run_id AND expires_at>p_at AND EXISTS(SELECT 1 FROM public.scheduler_runs r WHERE r.id=p_scheduler_run_id AND r.runner_key='GENESIS_DATABASE_GROWTH_V1' AND r.status='RUNNING');
 IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_GROWTH_SCHEDULER_LEASE_NOT_OWNED'; END IF;
END;$$;

--
-- Name: marketroute_heartbeat_research_scheduler_run_v1(uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_heartbeat_research_scheduler_run_v1(p_scheduler_run_id uuid, p_at timestamp with time zone DEFAULT now()) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
 IF abs(extract(epoch from (p_at-now())))>300 THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_SCHEDULER_TIME_NOT_CURRENT'; END IF;
 UPDATE public.scheduler_leases SET heartbeat_at=p_at,expires_at=p_at+interval '30 minutes'
 WHERE lease_key='GENESIS_RESEARCH_V1' AND owner_run_id=p_scheduler_run_id AND expires_at>p_at
   AND EXISTS(SELECT 1 FROM public.scheduler_runs r WHERE r.id=p_scheduler_run_id AND r.status='RUNNING' AND r.runner_key='GENESIS_RESEARCH_V1');
 IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_SCHEDULER_LEASE_NOT_OWNED'; END IF;
END $$;

--
-- Name: marketroute_ingest_evidence_v1(text, text, text, text, timestamp with time zone, text, text, text, text, jsonb, timestamp with time zone, text, text, integer, text, text, text, jsonb, uuid, text, uuid, text, text, jsonb, timestamp with time zone, timestamp with time zone, text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_ingest_evidence_v1(p_source_kind text, p_canonical_url text, p_publisher_domain text, p_title text, p_source_published_at timestamp with time zone, p_stable_locator text, p_source_identity_fingerprint text, p_dependence_family_key text, p_normalisation_version text, p_source_metadata_json jsonb, p_acquired_at timestamp with time zone, p_acquisition_method text, p_observed_content_fingerprint text, p_http_status integer, p_raw_locator text, p_parser_version text, p_request_id text, p_acquisition_metadata_json jsonb, p_tenant_scope_organisation_id uuid, p_subject_type text, p_subject_id uuid, p_evidence_kind text, p_excerpt_text text, p_structured_value_json jsonb, p_observed_at timestamp with time zone, p_origin_published_at timestamp with time zone, p_extraction_method text, p_extraction_version text, p_evidence_fingerprint text, p_fingerprint_version text) RETURNS TABLE(source_id uuid, acquisition_id uuid, evidence_item_id uuid, source_created boolean, evidence_created boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
DECLARE
  v_source_id uuid;
  v_acquisition_id uuid;
  v_evidence_id uuid;
  v_source_created boolean := false;
  v_evidence_created boolean := false;
  v_existing public.source_records%ROWTYPE;
  v_evidence public.evidence_items%ROWTYPE;
BEGIN
  PERFORM public.marketroute_require_service_role();

  IF p_source_identity_fingerprint !~ '^[a-f0-9]{64}$' THEN RAISE EXCEPTION 'MARKETROUTE_INVALID_SOURCE_IDENTITY_FINGERPRINT'; END IF;
  IF p_evidence_fingerprint !~ '^[a-f0-9]{64}$' THEN RAISE EXCEPTION 'MARKETROUTE_INVALID_EVIDENCE_FINGERPRINT'; END IF;
  IF p_observed_content_fingerprint IS NOT NULL AND p_observed_content_fingerprint !~ '^[a-f0-9]{64}$' THEN RAISE EXCEPTION 'MARKETROUTE_INVALID_CONTENT_FINGERPRINT'; END IF;
  IF length(btrim(COALESCE(p_dependence_family_key, ''))) = 0 THEN RAISE EXCEPTION 'MARKETROUTE_DEPENDENCE_FAMILY_REQUIRED'; END IF;
  IF length(btrim(COALESCE(p_stable_locator, ''))) = 0 THEN RAISE EXCEPTION 'MARKETROUTE_STABLE_LOCATOR_REQUIRED'; END IF;
  IF length(btrim(COALESCE(p_normalisation_version, ''))) = 0 OR length(btrim(COALESCE(p_fingerprint_version, ''))) = 0 THEN
    RAISE EXCEPTION 'MARKETROUTE_EVIDENCE_VERSION_REQUIRED';
  END IF;
  IF p_excerpt_text IS NULL AND p_structured_value_json IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_EVIDENCE_CONTENT_REQUIRED'; END IF;

  INSERT INTO public.source_records(
    source_kind, canonical_url, publisher_domain, title, published_at,
    first_observed_at, last_observed_at, metadata_json,
    source_identity_fingerprint, stable_locator, dependence_family_key, normalisation_version
  ) VALUES (
    p_source_kind, p_canonical_url, p_publisher_domain, p_title, p_source_published_at,
    COALESCE(p_acquired_at, now()), COALESCE(p_acquired_at, now()), COALESCE(p_source_metadata_json, '{}'::jsonb),
    p_source_identity_fingerprint, p_stable_locator, p_dependence_family_key, p_normalisation_version
  )
  ON CONFLICT (source_identity_fingerprint) DO NOTHING
  RETURNING id INTO v_source_id;

  IF v_source_id IS NOT NULL THEN
    v_source_created := true;
  ELSE
    SELECT * INTO v_existing
    FROM public.source_records
    WHERE source_identity_fingerprint = p_source_identity_fingerprint
    FOR UPDATE;
    v_source_id := v_existing.id;

    IF v_existing.source_kind IS DISTINCT FROM p_source_kind
       OR v_existing.canonical_url IS DISTINCT FROM p_canonical_url
       OR v_existing.publisher_domain IS DISTINCT FROM p_publisher_domain
       OR v_existing.stable_locator IS DISTINCT FROM p_stable_locator
       OR v_existing.dependence_family_key IS DISTINCT FROM p_dependence_family_key
       OR v_existing.normalisation_version IS DISTINCT FROM p_normalisation_version THEN
      RAISE EXCEPTION 'MARKETROUTE_SOURCE_FINGERPRINT_COLLISION';
    END IF;

    UPDATE public.source_records
    SET last_observed_at = GREATEST(last_observed_at, COALESCE(p_acquired_at, now())),
        title = COALESCE(title, p_title),
        published_at = COALESCE(published_at, p_source_published_at),
        metadata_json = metadata_json || COALESCE(p_source_metadata_json, '{}'::jsonb)
    WHERE id = v_source_id;
  END IF;

  INSERT INTO public.source_acquisitions(
    source_id, acquired_at, acquisition_method, observed_content_fingerprint,
    http_status, raw_locator, parser_version, request_id, metadata_json
  ) VALUES (
    v_source_id, COALESCE(p_acquired_at, now()), p_acquisition_method, p_observed_content_fingerprint,
    p_http_status, p_raw_locator, p_parser_version, p_request_id, COALESCE(p_acquisition_metadata_json, '{}'::jsonb)
  ) RETURNING id INTO v_acquisition_id;

  INSERT INTO public.evidence_items(
    acquisition_id, tenant_scope_organisation_id, subject_type, subject_id,
    evidence_kind, excerpt_text, structured_value_json, observed_at, origin_published_at,
    extraction_method, extraction_version, evidence_fingerprint,
    source_identity_fingerprint, dependence_family_key, fingerprint_version
  ) VALUES (
    v_acquisition_id, p_tenant_scope_organisation_id, p_subject_type, p_subject_id,
    p_evidence_kind, p_excerpt_text, p_structured_value_json, COALESCE(p_observed_at, now()), p_origin_published_at,
    p_extraction_method, p_extraction_version, p_evidence_fingerprint,
    p_source_identity_fingerprint, p_dependence_family_key, p_fingerprint_version
  )
  ON CONFLICT (evidence_fingerprint) DO NOTHING
  RETURNING id INTO v_evidence_id;

  IF v_evidence_id IS NOT NULL THEN
    v_evidence_created := true;
  ELSE
    SELECT * INTO v_evidence
    FROM public.evidence_items
    WHERE evidence_fingerprint = p_evidence_fingerprint;
    v_evidence_id := v_evidence.id;

    IF v_evidence.source_identity_fingerprint IS DISTINCT FROM p_source_identity_fingerprint
       OR v_evidence.dependence_family_key IS DISTINCT FROM p_dependence_family_key
       OR v_evidence.tenant_scope_organisation_id IS DISTINCT FROM p_tenant_scope_organisation_id
       OR v_evidence.subject_type IS DISTINCT FROM p_subject_type
       OR v_evidence.subject_id IS DISTINCT FROM p_subject_id
       OR v_evidence.evidence_kind IS DISTINCT FROM p_evidence_kind
       OR v_evidence.excerpt_text IS DISTINCT FROM p_excerpt_text
       OR v_evidence.structured_value_json IS DISTINCT FROM p_structured_value_json
       OR v_evidence.origin_published_at IS DISTINCT FROM p_origin_published_at
       OR v_evidence.extraction_method IS DISTINCT FROM p_extraction_method
       OR v_evidence.extraction_version IS DISTINCT FROM p_extraction_version
       OR v_evidence.fingerprint_version IS DISTINCT FROM p_fingerprint_version THEN
      RAISE EXCEPTION 'MARKETROUTE_EVIDENCE_FINGERPRINT_COLLISION';
    END IF;
  END IF;

  RETURN QUERY SELECT v_source_id, v_acquisition_id, v_evidence_id, v_source_created, v_evidence_created;
END;
$_$;

--
-- Name: marketroute_is_org_admin(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_is_org_admin(p_organisation_id uuid, p_actor_user_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.organisation_memberships m
    WHERE m.organisation_id = p_organisation_id
      AND m.user_id = p_actor_user_id
      AND m.status = 'ACTIVE'
      AND m.role IN ('OWNER','ADMIN')
  );
$$;

--
-- Name: marketroute_is_org_member(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_is_org_member(p_organisation_id uuid, p_actor_user_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.organisation_memberships m
    WHERE m.organisation_id = p_organisation_id
      AND m.user_id = p_actor_user_id
      AND m.status = 'ACTIVE'
  );
$$;

--
-- Name: marketroute_jsonb_text_array_is_set_v1(jsonb, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_jsonb_text_array_is_set_v1(p_value jsonb, p_pattern text) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_total integer;
  v_distinct integer;
BEGIN
  IF jsonb_typeof(p_value) <> 'array' THEN RETURN false; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_value) e WHERE jsonb_typeof(e) <> 'string') THEN RETURN false; END IF;
  SELECT count(*), count(DISTINCT value) INTO v_total, v_distinct FROM jsonb_array_elements_text(p_value);
  IF v_total <> v_distinct THEN RETURN false; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements_text(p_value) value WHERE value !~ p_pattern) THEN RETURN false; END IF;
  RETURN true;
END;
$$;

--
-- Name: marketroute_link_anonymous_discovery_extension_company_v1(uuid, text, text, text, text, text, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_link_anonymous_discovery_extension_company_v1(p_job_id uuid, p_worker_id text, p_name text, p_domain text, p_website_url text, p_country_code text, p_at timestamp with time zone DEFAULT now()) RETURNS TABLE(company_id uuid, scoped_count integer, target_count integer, inserted_scope boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
DECLARE
  v_job public.anonymous_discovery_extension_jobs%ROWTYPE;v_run public.anonymous_discovery_runs%ROWTYPE;
  v_domain text;v_company uuid;v_before integer;v_after integer;v_seller_domain text;v_candidate_ceiling integer;
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT * INTO v_job FROM public.anonymous_discovery_extension_jobs WHERE id=p_job_id FOR UPDATE;
  IF NOT FOUND OR v_job.status<>'RUNNING' OR v_job.worker_id IS DISTINCT FROM left(btrim(COALESCE(p_worker_id,'')),200) OR v_job.lease_expires_at<=p_at THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_EXTENSION_LEASE_INVALID'; END IF;
  SELECT * INTO v_run FROM public.anonymous_discovery_runs WHERE id=v_job.run_id FOR UPDATE;
  IF v_run.status NOT IN('ACTIVE','CLAIMED') OR v_run.research_expires_at<=p_at OR public.marketroute_paid_entitlement_active_v1(v_run.organisation_id,p_at) THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_EXTENSION_RUN_NOT_ELIGIBLE'; END IF;
  IF public.marketroute_anonymous_discovery_budget_terminal_v1(v_run.id,p_at) THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_EXTENSION_RESEARCH_CAPACITY_EXHAUSTED'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.campaigns c WHERE c.id=v_job.campaign_id AND c.organisation_id=v_run.organisation_id AND c.workflow_state='ACTIVE') THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_EXTENSION_CAMPAIGN_NOT_ACTIVE'; END IF;
  SELECT lower(canonical_domain) INTO v_seller_domain FROM public.seller_businesses WHERE id=v_run.seller_business_id AND organisation_id=v_run.organisation_id;
  v_domain:=lower(regexp_replace(btrim(COALESCE(p_domain,'')),'^www[.]','','i'));
  IF v_domain !~ '^[a-z0-9][a-z0-9.-]*[.][a-z]{2,63}$' OR v_domain~'[.][.]' OR v_domain=v_seller_domain THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_EXTENSION_DOMAIN_INVALID'; END IF;
  v_candidate_ceiling:=LEAST(40,GREATEST(v_run.target_count,v_run.target_count*4));
  SELECT count(DISTINCT s.company_id)::int INTO v_before FROM public.organisation_company_scopes s WHERE s.organisation_id=v_run.organisation_id AND s.campaign_id=v_job.campaign_id AND s.scope_kind='CAMPAIGN';
  IF v_before>=v_candidate_ceiling THEN RETURN; END IF;
  SELECT id INTO v_company FROM public.companies WHERE canonical_domain=v_domain LIMIT 1;
  IF v_company IS NULL THEN
    INSERT INTO public.companies(canonical_name,canonical_domain,website_url,country_code,lifecycle_state)
    VALUES(left(btrim(COALESCE(p_name,'')),240),v_domain,COALESCE(NULLIF(btrim(COALESCE(p_website_url,'')),''),'https://' || v_domain),CASE WHEN upper(COALESCE(p_country_code,''))~'^[A-Z]{2}$' THEN upper(p_country_code) ELSE NULL END,'ACTIVE')
    RETURNING id INTO v_company;
  END IF;
  INSERT INTO public.organisation_company_scopes(organisation_id,company_id,campaign_id,scope_kind)
  VALUES(v_run.organisation_id,v_company,v_job.campaign_id,'CAMPAIGN') ON CONFLICT DO NOTHING;
  SELECT count(DISTINCT s.company_id)::int INTO v_after FROM public.organisation_company_scopes s WHERE s.organisation_id=v_run.organisation_id AND s.campaign_id=v_job.campaign_id AND s.scope_kind='CAMPAIGN';
  IF v_after>v_candidate_ceiling THEN RAISE EXCEPTION 'MARKETROUTE_ANONYMOUS_EXTENSION_CANDIDATE_CEILING_EXCEEDED'; END IF;
  RETURN QUERY SELECT v_company,v_after,v_run.target_count,(v_after>v_before);
END;
$_$;

--
-- Name: marketroute_link_paid_campaign_refill_company_v1(uuid, text, text, text, text, text, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_link_paid_campaign_refill_company_v1(p_job_id uuid, p_worker_id text, p_name text, p_domain text, p_website_url text, p_country_code text, p_at timestamp with time zone DEFAULT now()) RETURNS TABLE(company_id uuid, scoped_count integer, target_count integer, inserted_scope boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
DECLARE v_job public.paid_campaign_refill_jobs%ROWTYPE;v_domain text;v_company uuid;v_before integer;v_after integer;v_seller_domain text;
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT * INTO v_job FROM public.paid_campaign_refill_jobs WHERE id=p_job_id FOR UPDATE;
  IF NOT FOUND OR v_job.status<>'RUNNING' OR v_job.worker_id IS DISTINCT FROM left(btrim(COALESCE(p_worker_id,'')),200) OR v_job.lease_expires_at<=p_at THEN RAISE EXCEPTION 'MARKETROUTE_PAID_REFILL_LEASE_INVALID'; END IF;
  IF NOT public.marketroute_paid_entitlement_active_v1(v_job.organisation_id,p_at) OR NOT public.marketroute_campaign_research_entitled_v1(v_job.organisation_id,v_job.campaign_id,p_at) THEN RAISE EXCEPTION 'MARKETROUTE_PAID_REFILL_ENTITLEMENT_INACTIVE'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.campaigns c JOIN public.research_budget_policies rp ON rp.organisation_id=c.organisation_id AND rp.campaign_id=c.id WHERE c.id=v_job.campaign_id AND c.organisation_id=v_job.organisation_id AND c.workflow_state='ACTIVE' AND rp.enabled=true) THEN RAISE EXCEPTION 'MARKETROUTE_PAID_REFILL_CAMPAIGN_NOT_ACTIVE'; END IF;
  SELECT lower(s.canonical_domain) INTO v_seller_domain FROM public.campaigns c JOIN public.seller_businesses s ON s.id=c.seller_business_id AND s.organisation_id=c.organisation_id WHERE c.id=v_job.campaign_id AND c.organisation_id=v_job.organisation_id;
  v_domain:=lower(regexp_replace(btrim(COALESCE(p_domain,'')),'^www[.]','','i'));
  IF v_domain !~ '^[a-z0-9][a-z0-9.-]*[.][a-z]{2,63}$' OR v_domain~'[.][.]' OR v_domain=v_seller_domain THEN RAISE EXCEPTION 'MARKETROUTE_PAID_REFILL_DOMAIN_INVALID'; END IF;
  SELECT count(DISTINCT s.company_id)::int INTO v_before FROM public.organisation_company_scopes s WHERE s.organisation_id=v_job.organisation_id AND s.campaign_id=v_job.campaign_id AND s.scope_kind='CAMPAIGN';
  IF v_before>=v_job.candidate_ceiling THEN RETURN; END IF;
  SELECT id INTO v_company FROM public.companies WHERE canonical_domain=v_domain LIMIT 1;
  IF v_company IS NULL THEN
    INSERT INTO public.companies(canonical_name,canonical_domain,website_url,country_code,lifecycle_state)
    VALUES(left(btrim(COALESCE(p_name,'')),240),v_domain,COALESCE(NULLIF(btrim(COALESCE(p_website_url,'')),''),'https://'||v_domain),CASE WHEN upper(COALESCE(p_country_code,''))~'^[A-Z]{2}$' THEN upper(p_country_code) ELSE NULL END,'ACTIVE') RETURNING id INTO v_company;
  END IF;
  INSERT INTO public.organisation_company_scopes(organisation_id,company_id,campaign_id,scope_kind) VALUES(v_job.organisation_id,v_company,v_job.campaign_id,'CAMPAIGN') ON CONFLICT DO NOTHING;
  SELECT count(DISTINCT s.company_id)::int INTO v_after FROM public.organisation_company_scopes s WHERE s.organisation_id=v_job.organisation_id AND s.campaign_id=v_job.campaign_id AND s.scope_kind='CAMPAIGN';
  IF v_after>v_job.candidate_ceiling THEN RAISE EXCEPTION 'MARKETROUTE_PAID_REFILL_CANDIDATE_CEILING_EXCEEDED'; END IF;
  RETURN QUERY SELECT v_company,v_after,v_job.target_count,(v_after>v_before);
END;$_$;

--
-- Name: marketroute_link_relationship_evidence_v1(uuid, uuid, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_link_relationship_evidence_v1(p_relationship_id uuid, p_evidence_item_id uuid, p_polarity text, p_link_method text, p_link_version text DEFAULT NULL::text) RETURNS TABLE(relationship_id uuid, claim_id uuid, claim_evidence_link_id uuid, link_created boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_rel public.commercial_relationships%ROWTYPE; v_e public.evidence_items%ROWTYPE; v_link uuid;
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT * INTO v_rel FROM public.commercial_relationships WHERE id=p_relationship_id; IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_RELATIONSHIP_NOT_FOUND'; END IF;
  SELECT * INTO v_e FROM public.evidence_items WHERE id=p_evidence_item_id; IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_RELATIONSHIP_EVIDENCE_NOT_FOUND'; END IF;
  IF v_e.subject_type<>'RELATIONSHIP' OR v_e.subject_id<>v_rel.id OR v_e.tenant_scope_organisation_id IS DISTINCT FROM v_rel.tenant_scope_organisation_id THEN RAISE EXCEPTION 'MARKETROUTE_RELATIONSHIP_EVIDENCE_SCOPE_MISMATCH'; END IF;
  IF p_polarity NOT IN ('SUPPORTS','CONTRADICTS') THEN RAISE EXCEPTION 'MARKETROUTE_RELATIONSHIP_POLARITY_INVALID'; END IF;
  IF p_link_method NOT IN ('DETERMINISTIC','AI_EXTRACTED','USER_PROVIDED','MIGRATED') THEN RAISE EXCEPTION 'MARKETROUTE_RELATIONSHIP_LINK_METHOD_INVALID'; END IF;
  SELECT l.id INTO v_link FROM public.claim_evidence_links l WHERE l.claim_id=v_rel.claim_id AND l.evidence_item_id=p_evidence_item_id;
  IF FOUND THEN
    IF EXISTS(SELECT 1 FROM public.claim_evidence_links WHERE id=v_link AND polarity<>p_polarity) THEN RAISE EXCEPTION 'MARKETROUTE_RELATIONSHIP_EVIDENCE_POLARITY_CONFLICT'; END IF;
    RETURN QUERY SELECT v_rel.id,v_rel.claim_id,v_link,false; RETURN;
  END IF;
  INSERT INTO public.claim_evidence_links(claim_id,evidence_item_id,polarity,dependence_family_key,link_method,link_version)
  VALUES(v_rel.claim_id,p_evidence_item_id,p_polarity,v_e.dependence_family_key,p_link_method,p_link_version) RETURNING id INTO v_link;
  RETURN QUERY SELECT v_rel.id,v_rel.claim_id,v_link,true;
END; $$;

--
-- Name: marketroute_list_opportunity_profiles_v1(uuid, uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_list_opportunity_profiles_v1(p_organisation_id uuid, p_campaign_id uuid, p_at timestamp with time zone DEFAULT now()) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_result jsonb;
BEGIN
 PERFORM public.marketroute_require_service_role();
 IF NOT EXISTS(SELECT 1 FROM public.campaigns c WHERE c.id=p_campaign_id AND c.organisation_id=p_organisation_id) THEN RAISE EXCEPTION 'MARKETROUTE_OPPORTUNITY_LIST_CAMPAIGN_SCOPE_MISMATCH'; END IF;
 SELECT COALESCE(jsonb_agg(public.marketroute_opportunity_profile_v1(o.organisation_id,o.campaign_id,o.company_id,p_at) ORDER BY c.canonical_name,o.company_id),'[]'::jsonb) INTO v_result
 FROM public.opportunities o JOIN public.companies c ON c.id=o.company_id WHERE o.organisation_id=p_organisation_id AND o.campaign_id=p_campaign_id;
 RETURN v_result;
END $$;

--
-- Name: marketroute_manage_campaign_v1(uuid, uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_manage_campaign_v1(p_organisation_id uuid, p_campaign_id uuid, p_action text, p_actor_user_id uuid, p_confirmation_name text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_user uuid := p_actor_user_id;
  v_campaign public.campaigns%ROWTYPE;
  v_action text := upper(btrim(COALESCE(p_action, '')));
  v_resulting_state text;
  v_policy_was_enabled boolean := true;
  v_deduplicated boolean := false;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'MARKETROUTE_AUTH_REQUIRED';
  END IF;
  IF NOT public.marketroute_is_org_admin(p_organisation_id, p_actor_user_id) THEN
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

  IF v_action = 'RESUME' AND NOT public.marketroute_campaign_research_entitled_v1(p_organisation_id,p_campaign_id,now()) THEN
    RAISE EXCEPTION 'MARKETROUTE_CAMPAIGN_RESUME_RESEARCH_ENTITLEMENT_REQUIRED';
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
$$;

--
-- Name: marketroute_mark_billing_recovery_attempt_v1(uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_mark_billing_recovery_attempt_v1(p_organisation_id uuid, p_at timestamp with time zone DEFAULT now()) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
  PERFORM public.marketroute_require_service_role();
  UPDATE public.organisation_commercial_entitlements SET metadata_json=metadata_json||jsonb_build_object('lastRecoveryAttemptAt',p_at) WHERE organisation_id=p_organisation_id AND source='BILLING';
  RETURN FOUND;
END;$$;

--
-- Name: marketroute_materialised_ready_opportunities_v1(uuid, uuid, integer, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_materialised_ready_opportunities_v1(p_organisation_id uuid, p_campaign_id uuid, p_limit integer DEFAULT 250, p_at timestamp with time zone DEFAULT now()) RETURNS TABLE(opportunity_id uuid, company_id uuid, company_name text, canonical_domain text, discovered_at timestamp with time zone)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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
$$;

--
-- Name: marketroute_opportunity_disposition_v1(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_opportunity_disposition_v1(p_lifecycle_state text) RETURNS text
    LANGUAGE sql IMMUTABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
 SELECT CASE
  WHEN p_lifecycle_state='AUTHORITY_READY' THEN 'ACTIONABLE'
  WHEN p_lifecycle_state='NOT_ADMISSIBLE' THEN 'NOT_ADMISSIBLE'
  WHEN p_lifecycle_state IN('ROUTE_NOT_APPLICABLE','CONTACT_NOT_APPLICABLE') THEN 'NOT_APPLICABLE'
  WHEN p_lifecycle_state IN('R4_REVALIDATION_REQUIRED','R5_REVALIDATION_REQUIRED','R6_REVALIDATION_REQUIRED') THEN 'REVALIDATION_REQUIRED'
  WHEN p_lifecycle_state IN('COMMERCIAL_RESEARCH_REQUIRED','ROUTE_RESEARCH_REQUIRED','CONTACT_RESEARCH_REQUIRED') THEN 'RESEARCH_REQUIRED'
  ELSE NULL
 END;
$$;

--
-- Name: marketroute_opportunity_executable_now_v1(uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_opportunity_executable_now_v1(p_opportunity_id uuid, p_at timestamp with time zone DEFAULT now()) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
 SELECT COALESCE((SELECT o.workflow_state IN('REVIEWABLE','APPROVED') AND public.marketroute_authority_ready_v1(o.organisation_id,o.campaign_id,o.company_id,p_at) FROM public.opportunities o WHERE o.id=p_opportunity_id),false);
$$;

--
-- Name: marketroute_opportunity_profile_v1(uuid, uuid, uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_opportunity_profile_v1(p_organisation_id uuid, p_campaign_id uuid, p_company_id uuid, p_at timestamp with time zone DEFAULT now()) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_company public.companies%ROWTYPE; v_opp public.opportunities%ROWTYPE; v_env jsonb;
  v_r4 public.commercial_reality_r4_records%ROWTYPE; v_r5 public.route_authority_r5_records%ROWTYPE; v_r6 public.contact_authority_r6_records%ROWTYPE;
  v_truth public.truth_entity_snapshots%ROWTYPE; v_ready boolean; v_state text; v_workflow text; v_struct int:=0; v_auth int:=0;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF p_at IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_OPPORTUNITY_PROFILE_TIME_REQUIRED'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.campaigns c WHERE c.id=p_campaign_id AND c.organisation_id=p_organisation_id) THEN RAISE EXCEPTION 'MARKETROUTE_OPPORTUNITY_PROFILE_CAMPAIGN_SCOPE_MISMATCH'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.organisation_company_scopes s WHERE s.organisation_id=p_organisation_id AND s.campaign_id=p_campaign_id AND s.company_id=p_company_id AND s.scope_kind='CAMPAIGN') THEN RAISE EXCEPTION 'MARKETROUTE_OPPORTUNITY_PROFILE_COMPANY_NOT_IN_CAMPAIGN'; END IF;
  SELECT * INTO v_company FROM public.companies WHERE id=p_company_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_OPPORTUNITY_PROFILE_COMPANY_NOT_FOUND'; END IF;
  SELECT * INTO v_opp FROM public.opportunities WHERE organisation_id=p_organisation_id AND campaign_id=p_campaign_id AND company_id=p_company_id LIMIT 1;
  v_workflow:=CASE WHEN v_opp.id IS NULL THEN NULL ELSE v_opp.workflow_state END;
  v_env:=public.marketroute_authority_envelope_v1(p_organisation_id,p_campaign_id,p_company_id,p_at);
  v_ready:=COALESCE((v_env->>'authorityReady')::boolean,false); v_state:=v_env->>'lifecycleState';
  IF public.marketroute_opportunity_disposition_v1(v_state) IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_OPPORTUNITY_LIFECYCLE_STATE_UNKNOWN'; END IF;
  IF NULLIF(v_env->'r4'->>'authorityRecordId','') IS NOT NULL THEN
    SELECT r.* INTO v_r4 FROM public.commercial_reality_r4_records r WHERE r.authority_record_id=(v_env->'r4'->>'authorityRecordId')::uuid;
    IF v_r4.id IS NOT NULL THEN SELECT * INTO v_truth FROM public.truth_entity_snapshots WHERE id=v_r4.target_truth_entity_snapshot_id; END IF;
  END IF;
  IF NULLIF(v_env->'r5'->>'authorityRecordId','') IS NOT NULL THEN SELECT r.* INTO v_r5 FROM public.route_authority_r5_records r WHERE r.authority_record_id=(v_env->'r5'->>'authorityRecordId')::uuid; END IF;
  IF NULLIF(v_env->'r6'->>'authorityRecordId','') IS NOT NULL THEN SELECT r.* INTO v_r6 FROM public.contact_authority_r6_records r WHERE r.authority_record_id=(v_env->'r6'->>'authorityRecordId')::uuid; END IF;
  v_struct:=COALESCE(v_r5.distinct_access_point_count,0); v_auth:=COALESCE(v_r6.distinct_authorised_access_point_count,0);
  IF v_auth>v_struct THEN RAISE EXCEPTION 'MARKETROUTE_OPPORTUNITY_AUTHORISED_ROUTE_COUNT_EXCEEDS_STRUCTURE'; END IF;
  IF v_ready AND (COALESCE(v_r4.decision_code,'')<>'COMMERCIAL_CANDIDATE' OR COALESCE(v_r5.decision_code,'')<>'ROUTE_STRUCTURALLY_OPEN' OR COALESCE(v_r6.decision_code,'')<>'CONTACT_AUTHORISED' OR v_struct<1 OR v_auth<1 OR v_truth.id IS NULL) THEN RAISE EXCEPTION 'MARKETROUTE_OPPORTUNITY_ACTIONABLE_PROFILE_INCONSISTENT'; END IF;
  RETURN jsonb_build_object(
    'engineVersion','MRV2-OPPORTUNITY-ENGINE-1.0.0','semanticsVersion','MRV2-OPPORTUNITY-SEMANTICS-1.0.0',
    'organisationId',p_organisation_id::text,'campaignId',p_campaign_id::text,'companyId',p_company_id::text,
    'opportunityId',v_opp.id,'companyName',v_company.canonical_name,'canonicalDomain',v_company.canonical_domain,'evaluatedAt',to_jsonb(p_at),
    'workflowState',v_workflow,'lifecycleState',v_state,'disposition',public.marketroute_opportunity_disposition_v1(v_state),
    'researchPressure',public.marketroute_opportunity_research_pressure_v1(v_state),'authorityReady',v_ready,
    'reviewableNow',COALESCE(v_workflow='REVIEWABLE' AND v_ready,false),
    'executableNow',CASE WHEN v_opp.id IS NULL THEN false ELSE public.marketroute_opportunity_executable_now_v1(v_opp.id,p_at) END,
    'reasonCode',v_env->>'reasonCode','nextRevalidationAt',v_env->'nextRevalidationAt',
    'commercialReality',v_env->'r4'->>'decision','routeAuthority',v_env->'r5'->>'decision','contactAuthority',v_env->'r6'->>'decision',
    'truth',jsonb_build_object(
      'entityState',v_truth.entity_state,'currentCoverage',v_truth.current_coverage,'evidenceSufficiency',v_truth.evidence_sufficiency,
      'freshnessCoverage',v_truth.freshness_coverage,'coherence',v_truth.coherence,'truthIndex',v_truth.truth_index,
      'probabilityState',CASE WHEN v_truth.id IS NULL THEN NULL ELSE v_truth.probability_state END
    ),
    'structurallyOpenAccessPointCount',v_struct,'authorisedAccessPointCount',v_auth,
    'routeRedundancy',CASE WHEN v_auth=0 THEN 'NONE' WHEN v_auth=1 THEN 'SINGLE' ELSE 'MULTIPLE' END,
    'authorityEnvelope',v_env
  );
END $$;

--
-- Name: marketroute_opportunity_research_pressure_v1(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_opportunity_research_pressure_v1(p_lifecycle_state text) RETURNS text
    LANGUAGE sql IMMUTABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
 SELECT CASE
  WHEN p_lifecycle_state IN('R4_REVALIDATION_REQUIRED','COMMERCIAL_RESEARCH_REQUIRED') THEN 'R4'
  WHEN p_lifecycle_state IN('R5_REVALIDATION_REQUIRED','ROUTE_RESEARCH_REQUIRED') THEN 'R5'
  WHEN p_lifecycle_state IN('R6_REVALIDATION_REQUIRED','CONTACT_RESEARCH_REQUIRED') THEN 'R6'
  ELSE 'NONE'
 END;
$$;

--
-- Name: marketroute_opportunity_sync_targets_v1(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_opportunity_sync_targets_v1(p_limit integer DEFAULT 250) RETURNS TABLE(organisation_id uuid, campaign_id uuid, company_id uuid)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
 SELECT DISTINCT s.organisation_id,s.campaign_id,s.company_id
 FROM public.organisation_company_scopes s
 JOIN public.campaigns c ON c.id=s.campaign_id AND c.organisation_id=s.organisation_id AND c.workflow_state='ACTIVE'
 LEFT JOIN public.opportunities o ON o.organisation_id=s.organisation_id AND o.campaign_id=s.campaign_id AND o.company_id=s.company_id
 WHERE s.scope_kind='CAMPAIGN' AND s.campaign_id IS NOT NULL
   AND (o.id IS NOT NULL OR public.marketroute_authority_ready_v1(s.organisation_id,s.campaign_id,s.company_id,now()))
 ORDER BY s.organisation_id,s.campaign_id,s.company_id
 LIMIT greatest(0,least(COALESCE(p_limit,250),2000));
$$;

--
-- Name: marketroute_paid_entitlement_active_v1(uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_paid_entitlement_active_v1(p_organisation_id uuid, p_at timestamp with time zone DEFAULT now()) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
 SELECT EXISTS(
   SELECT 1 FROM public.organisation_commercial_entitlements e
   WHERE e.organisation_id=p_organisation_id
     AND e.status='ACTIVE'
     AND e.plan_code IN('STARTER','GROWTH','SCALE','LEGACY_FULL')
     AND (e.current_period_start IS NULL OR e.current_period_start<=p_at)
     AND (e.current_period_end IS NULL OR e.current_period_end>p_at)
 );
$$;

--
-- Name: marketroute_persist_claim_truth_v1(uuid, timestamp with time zone, text, text, text, text, integer, integer, integer, integer, numeric, numeric, numeric, numeric, numeric, numeric, text, timestamp with time zone, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_persist_claim_truth_v1(p_claim_id uuid, p_reference_time timestamp with time zone, p_context_fingerprint text, p_engine_version text, p_semantics_version text, p_truth_state text, p_current_support_family_count integer, p_current_contradiction_family_count integer, p_stale_family_count integer, p_temporal_anomaly_count integer, p_evidence_sufficiency numeric, p_support_strength numeric, p_contradiction_strength numeric, p_evidence_balance numeric, p_freshness_coverage numeric, p_truth_probability numeric, p_probability_state text, p_next_revalidation_at timestamp with time zone, p_payload_json jsonb) RETURNS TABLE(snapshot_id uuid, reasoning_run_id uuid, reasoning_artifact_id uuid, snapshot_fingerprint text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_claim public.claims%ROWTYPE;
  v_facts record;
  v_current_context text;
  v_proposition_fingerprint text;
  v_snapshot_fingerprint text;
  v_existing public.truth_claim_snapshots%ROWTYPE;
  v_run_id uuid;
  v_artifact_id uuid;
  v_snapshot_id uuid;
  v_metric_tolerance numeric := 0.000001;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF p_reference_time > now() + interval '5 minutes' THEN RAISE EXCEPTION 'MARKETROUTE_TRUTH_REFERENCE_TIME_IN_FUTURE'; END IF;
  IF p_engine_version IS DISTINCT FROM 'MRV2-TRUTH-1.0.0' OR p_semantics_version IS DISTINCT FROM 'MRV2-TRUTH-SEM-1.0.0' THEN
    RAISE EXCEPTION 'MARKETROUTE_TRUTH_ENGINE_VERSION_MISMATCH';
  END IF;
  IF p_truth_probability IS NOT NULL OR p_probability_state IS DISTINCT FROM 'UNCALIBRATED' THEN
    RAISE EXCEPTION 'MARKETROUTE_TRUTH_PROBABILITY_FORBIDDEN_UNTIL_CALIBRATED';
  END IF;

  SELECT * INTO v_claim FROM public.claims WHERE id = p_claim_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_TRUTH_CLAIM_NOT_FOUND'; END IF;

  v_current_context := public.marketroute_truth_context_fingerprint_v1(p_claim_id, p_reference_time);
  v_proposition_fingerprint := public.marketroute_truth_proposition_fingerprint_v1(p_claim_id);
  IF v_current_context IS DISTINCT FROM p_context_fingerprint THEN
    RAISE EXCEPTION 'MARKETROUTE_TRUTH_CONTEXT_CHANGED';
  END IF;

  SELECT * INTO v_facts FROM public.marketroute_truth_claim_facts_v1(p_claim_id, p_reference_time);

  IF p_truth_state IS DISTINCT FROM v_facts.truth_state
     OR p_current_support_family_count IS DISTINCT FROM v_facts.current_support_family_count
     OR p_current_contradiction_family_count IS DISTINCT FROM v_facts.current_contradiction_family_count
     OR p_stale_family_count IS DISTINCT FROM v_facts.stale_family_count
     OR p_temporal_anomaly_count IS DISTINCT FROM v_facts.temporal_anomaly_count
     OR abs(p_evidence_sufficiency - v_facts.evidence_sufficiency) > v_metric_tolerance
     OR abs(p_support_strength - v_facts.support_strength) > v_metric_tolerance
     OR abs(p_contradiction_strength - v_facts.contradiction_strength) > v_metric_tolerance
     OR abs(p_evidence_balance - v_facts.evidence_balance) > v_metric_tolerance
     OR abs(p_freshness_coverage - v_facts.freshness_coverage) > v_metric_tolerance
     OR (p_next_revalidation_at IS NULL) IS DISTINCT FROM (v_facts.next_revalidation_at IS NULL)
     OR (p_next_revalidation_at IS NOT NULL AND v_facts.next_revalidation_at IS NOT NULL
         AND abs(extract(epoch FROM (p_next_revalidation_at - v_facts.next_revalidation_at))) > 0.002) THEN
    RAISE EXCEPTION 'MARKETROUTE_TRUTH_OUTPUT_DOES_NOT_MATCH_EVIDENCE';
  END IF;

  v_snapshot_fingerprint := encode(extensions.digest(
    concat_ws('|',
      'MRV2-TRUTH-SNAPSHOT-1.0.0',
      p_context_fingerprint,
      v_proposition_fingerprint,
      p_engine_version,
      p_semantics_version,
      v_facts.policy_key,
      v_facts.policy_version,
      p_truth_state,
      p_current_support_family_count::text,
      p_current_contradiction_family_count::text,
      p_stale_family_count::text,
      p_temporal_anomaly_count::text,
      round(p_evidence_sufficiency, 6)::text,
      round(p_support_strength, 6)::text,
      round(p_contradiction_strength, 6)::text,
      round(p_evidence_balance, 6)::text,
      round(p_freshness_coverage, 6)::text,
      p_probability_state,
      COALESCE(to_char(v_facts.next_revalidation_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'), '-')
    ), 'sha256'
  ), 'hex');

  SELECT * INTO v_existing
  FROM public.truth_claim_snapshots
  WHERE claim_id = p_claim_id AND input_fingerprint = p_context_fingerprint;

  IF FOUND THEN
    IF v_existing.snapshot_fingerprint IS DISTINCT FROM v_snapshot_fingerprint THEN
      RAISE EXCEPTION 'MARKETROUTE_TRUTH_SNAPSHOT_COLLISION';
    END IF;
    RETURN QUERY SELECT v_existing.id, v_existing.reasoning_run_id, v_existing.reasoning_artifact_id, v_existing.snapshot_fingerprint;
    RETURN;
  END IF;

  INSERT INTO public.reasoning_runs(
    organisation_id, campaign_id, reasoning_kind, engine_version, input_fingerprint,
    status, started_at, completed_at, metadata_json
  ) VALUES (
    v_claim.tenant_scope_organisation_id, NULL, 'TRUTH', p_engine_version, p_context_fingerprint,
    'SUCCEEDED', p_reference_time, p_reference_time,
    jsonb_build_object('semanticsVersion', p_semantics_version, 'artifact', 'CLAIM_TRUTH')
  ) RETURNING id INTO v_run_id;

  INSERT INTO public.reasoning_artifacts(
    reasoning_run_id, artifact_kind, subject_type, subject_id,
    artifact_fingerprint, payload_json, evaluated_at
  ) VALUES (
    v_run_id, 'TRUTH_CLAIM_SNAPSHOT', v_claim.subject_type, v_claim.subject_id,
    v_snapshot_fingerprint,
    jsonb_build_object(
      'engineVersion', p_engine_version,
      'semanticsVersion', p_semantics_version,
      'claimId', v_claim.id,
      'claimKey', v_claim.claim_key,
      'claimFingerprint', v_claim.claim_fingerprint,
      'propositionFingerprint', v_proposition_fingerprint,
      'truthState', p_truth_state,
      'currentSupportFamilyCount', p_current_support_family_count,
      'currentContradictionFamilyCount', p_current_contradiction_family_count,
      'staleFamilyCount', p_stale_family_count,
      'temporalAnomalyCount', p_temporal_anomaly_count,
      'evidenceSufficiency', round(p_evidence_sufficiency,6),
      'supportStrength', round(p_support_strength,6),
      'contradictionStrength', round(p_contradiction_strength,6),
      'evidenceBalance', round(p_evidence_balance,6),
      'freshnessCoverage', round(p_freshness_coverage,6),
      'truthProbability', NULL,
      'probabilityState', p_probability_state,
      'referenceTime', p_reference_time,
      'nextRevalidationAt', v_facts.next_revalidation_at,
      'familyDiagnostics', COALESCE(p_payload_json->'familyDiagnostics', '[]'::jsonb)
    ),
    p_reference_time
  ) RETURNING id INTO v_artifact_id;

  INSERT INTO public.truth_claim_snapshots(
    reasoning_run_id, reasoning_artifact_id, claim_id, tenant_scope_organisation_id,
    subject_type, subject_id, claim_key, proposition_fingerprint,
    policy_key, policy_version, engine_version, semantics_version,
    input_fingerprint, snapshot_fingerprint, truth_state,
    current_support_family_count, current_contradiction_family_count, stale_family_count, temporal_anomaly_count,
    evidence_sufficiency, support_strength, contradiction_strength, evidence_balance, freshness_coverage,
    truth_probability, probability_state, reference_time, next_revalidation_at, payload_json
  ) VALUES (
    v_run_id, v_artifact_id, v_claim.id, v_claim.tenant_scope_organisation_id,
    v_claim.subject_type, v_claim.subject_id, v_claim.claim_key, v_proposition_fingerprint,
    v_facts.policy_key, v_facts.policy_version, p_engine_version, p_semantics_version,
    p_context_fingerprint, v_snapshot_fingerprint, p_truth_state,
    p_current_support_family_count, p_current_contradiction_family_count, p_stale_family_count, p_temporal_anomaly_count,
    round(p_evidence_sufficiency, 6), round(p_support_strength, 6), round(p_contradiction_strength, 6), round(p_evidence_balance, 6), round(p_freshness_coverage, 6),
    NULL, p_probability_state, p_reference_time, v_facts.next_revalidation_at,
    jsonb_build_object(
      'engineVersion', p_engine_version,
      'semanticsVersion', p_semantics_version,
      'claimId', v_claim.id,
      'claimKey', v_claim.claim_key,
      'claimFingerprint', v_claim.claim_fingerprint,
      'propositionFingerprint', v_proposition_fingerprint,
      'truthState', p_truth_state,
      'currentSupportFamilyCount', p_current_support_family_count,
      'currentContradictionFamilyCount', p_current_contradiction_family_count,
      'staleFamilyCount', p_stale_family_count,
      'temporalAnomalyCount', p_temporal_anomaly_count,
      'evidenceSufficiency', round(p_evidence_sufficiency,6),
      'supportStrength', round(p_support_strength,6),
      'contradictionStrength', round(p_contradiction_strength,6),
      'evidenceBalance', round(p_evidence_balance,6),
      'freshnessCoverage', round(p_freshness_coverage,6),
      'truthProbability', NULL,
      'probabilityState', p_probability_state,
      'referenceTime', p_reference_time,
      'nextRevalidationAt', v_facts.next_revalidation_at,
      'familyDiagnostics', COALESCE(p_payload_json->'familyDiagnostics', '[]'::jsonb)
    )
  ) RETURNING id INTO v_snapshot_id;

  RETURN QUERY SELECT v_snapshot_id, v_run_id, v_artifact_id, v_snapshot_fingerprint;
END;
$$;

--
-- Name: marketroute_persist_commercial_reality_r4_v1(uuid, uuid, uuid, timestamp with time zone, uuid, uuid, jsonb, text, text, text, text, text, jsonb, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_persist_commercial_reality_r4_v1(p_organisation_id uuid, p_campaign_id uuid, p_company_id uuid, p_reference_time timestamp with time zone, p_seller_context_selection_id uuid, p_target_truth_entity_snapshot_id uuid, p_constraint_truth_snapshot_map jsonb, p_engine_version text, p_semantics_version text, p_boundary_constitution_version text, p_reality_class text, p_decision_code text, p_boundaries_json jsonb, p_next_revalidation_at timestamp with time zone) RETURNS TABLE(r4_record_id uuid, authority_record_id uuid, reasoning_run_id uuid, reasoning_artifact_id uuid, input_fingerprint text, authority_fingerprint text, valid_until timestamp with time zone, deduplicated boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_context jsonb;
  v_expected jsonb;
  v_constitution public.commercial_reality_boundary_constitutions%ROWTYPE;
  v_selection public.campaign_seller_context_selections%ROWTYPE;
  v_entity public.truth_entity_snapshots%ROWTYPE;
  v_constraint_identity text := '';
  v_key text;
  v_snapshot_fps text;
  v_input_fingerprint text;
  v_artifact_fingerprint text;
  v_authority_fingerprint text;
  v_reasoning_run_id uuid;
  v_reasoning_artifact_id uuid;
  v_authority_id uuid;
  v_r4_id uuid;
  v_existing public.commercial_reality_r4_records%ROWTYPE;
  v_previous_authority_id uuid;
  v_valid_until timestamptz;
  v_payload jsonb;
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT * INTO v_constitution FROM public.commercial_reality_boundary_constitutions WHERE constitution_key='SELLER_TO_TARGET_V1' AND active=true;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_R4_CONSTITUTION_NOT_ACTIVE'; END IF;
  IF p_engine_version <> 'MRV2-R4-1.0.0' OR p_semantics_version <> 'MRV2-R4-SEM-1.0.0'
     OR p_boundary_constitution_version <> v_constitution.constitution_version OR p_reality_class <> v_constitution.reality_class THEN
    RAISE EXCEPTION 'MARKETROUTE_R4_VERSION_CONTRACT_MISMATCH';
  END IF;

  v_context := public.marketroute_get_r4_context_v1(
    p_organisation_id,p_campaign_id,p_company_id,p_reference_time,p_seller_context_selection_id,p_target_truth_entity_snapshot_id,p_constraint_truth_snapshot_map
  );
  v_expected := public.marketroute_r4_expected_v1(v_context);

  IF p_decision_code IS DISTINCT FROM v_expected->>'decision' THEN RAISE EXCEPTION 'MARKETROUTE_R4_DECISION_MISMATCH'; END IF;
  IF p_boundaries_json IS DISTINCT FROM v_expected->'boundaries' THEN RAISE EXCEPTION 'MARKETROUTE_R4_BOUNDARIES_MISMATCH'; END IF;
  IF p_next_revalidation_at IS DISTINCT FROM (v_expected->>'nextRevalidationAt')::timestamptz THEN RAISE EXCEPTION 'MARKETROUTE_R4_REVALIDATION_MISMATCH'; END IF;
  IF p_decision_code = 'COMMERCIAL_CANDIDATE' AND EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_boundaries_json) b WHERE b->>'state' <> 'SATISFIED'
  ) THEN RAISE EXCEPTION 'MARKETROUTE_R4_CANDIDATE_WITH_OPEN_BOUNDARY'; END IF;

  SELECT * INTO v_selection FROM public.campaign_seller_context_selections WHERE id = p_seller_context_selection_id;
  SELECT * INTO v_entity FROM public.truth_entity_snapshots WHERE id = p_target_truth_entity_snapshot_id;

  FOR v_key IN SELECT key FROM jsonb_object_keys(p_constraint_truth_snapshot_map) k(key) ORDER BY key LOOP
    SELECT string_agg(t.snapshot_fingerprint, ',' ORDER BY t.snapshot_fingerprint) INTO v_snapshot_fps
    FROM public.truth_claim_snapshots t
    WHERE t.id IN (SELECT value::uuid FROM jsonb_array_elements_text(p_constraint_truth_snapshot_map->v_key) x(value));
    v_constraint_identity := v_constraint_identity || v_key || ':' || COALESCE(v_snapshot_fps,'') || ';';
  END LOOP;

  v_input_fingerprint := encode(extensions.digest(concat_ws('|',
    'MRV2-R4-INPUT-1.0.0', p_organisation_id::text, p_campaign_id::text, p_company_id::text,
    v_selection.semantic_context_fingerprint, v_entity.snapshot_fingerprint, v_constraint_identity,
    v_constitution.constitution_version, v_constitution.reality_class,
    to_char(p_reference_time AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
  ),'sha256'),'hex');

  SELECT r.*
  INTO v_existing
  FROM public.commercial_reality_r4_records AS r
  WHERE r.organisation_id=p_organisation_id
    AND r.campaign_id=p_campaign_id
    AND r.company_id=p_company_id
    AND r.input_fingerprint=v_input_fingerprint;
  IF FOUND THEN
    IF v_existing.decision_code IS DISTINCT FROM p_decision_code OR v_existing.boundaries_json IS DISTINCT FROM p_boundaries_json THEN
      RAISE EXCEPTION 'MARKETROUTE_R4_INPUT_FINGERPRINT_COLLISION';
    END IF;
    RETURN QUERY SELECT v_existing.id,v_existing.authority_record_id,
      a.reasoning_run_id,a.reasoning_artifact_id,v_existing.input_fingerprint,v_existing.authority_fingerprint,a.valid_until,true
    FROM public.authority_records a WHERE a.id=v_existing.authority_record_id;
    RETURN;
  END IF;

  v_valid_until := p_next_revalidation_at;
  IF v_valid_until <= p_reference_time OR v_valid_until > p_reference_time + make_interval(hours => v_constitution.max_authority_hours) THEN
    RAISE EXCEPTION 'MARKETROUTE_R4_VALIDITY_WINDOW_INVALID';
  END IF;

  INSERT INTO public.reasoning_runs(organisation_id,campaign_id,reasoning_kind,engine_version,input_fingerprint,status,started_at,completed_at,metadata_json)
  VALUES(p_organisation_id,p_campaign_id,'COMMERCIAL_REALITY',p_engine_version,v_input_fingerprint,'SUCCEEDED',p_reference_time,now(),jsonb_build_object('realityClass',p_reality_class,'boundaryConstitutionVersion',p_boundary_constitution_version))
  RETURNING id INTO v_reasoning_run_id;

  v_payload := jsonb_build_object(
    'realityClass',p_reality_class,
    'boundaryConstitutionVersion',p_boundary_constitution_version,
    'decision',p_decision_code,
    'boundaries',p_boundaries_json,
    'sellerContextSelectionId',p_seller_context_selection_id,
    'sellerSemanticContextFingerprint',v_selection.semantic_context_fingerprint,
    'targetTruthEntitySnapshotId',p_target_truth_entity_snapshot_id,
    'targetTruthEntitySnapshotFingerprint',v_entity.snapshot_fingerprint,
    'constraintTruthSnapshotMap',p_constraint_truth_snapshot_map,
    'nextRevalidationAt',p_next_revalidation_at
  );
  v_artifact_fingerprint := encode(extensions.digest('MRV2-R4-ARTIFACT-1.0.0|'||v_input_fingerprint||'|'||v_payload::text,'sha256'),'hex');

  INSERT INTO public.reasoning_artifacts(reasoning_run_id,artifact_kind,subject_type,subject_id,artifact_fingerprint,payload_json,evaluated_at)
  VALUES(v_reasoning_run_id,'COMMERCIAL_REALITY_R4','COMPANY',p_company_id,v_artifact_fingerprint,v_payload,p_reference_time)
  RETURNING id INTO v_reasoning_artifact_id;

  v_authority_fingerprint := encode(extensions.digest(concat_ws('|',
    'MRV2-R4-AUTHORITY-1.0.0',v_input_fingerprint,p_decision_code,p_boundaries_json::text,
    to_char(v_valid_until AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
  ),'sha256'),'hex');

  SELECT a.id INTO v_previous_authority_id
  FROM public.authority_records a
  WHERE a.organisation_id=p_organisation_id AND a.campaign_id=p_campaign_id
    AND a.authority_stage='COMMERCIAL_REALITY' AND a.subject_type='COMPANY' AND a.subject_id=p_company_id
    AND a.writer_key='marketroute.r4.commercial-reality'
    AND NOT EXISTS (SELECT 1 FROM public.authority_events e WHERE e.authority_record_id=a.id AND e.event_type IN ('SUPERSEDED','INVALIDATED','REVOKED'))
  ORDER BY a.created_at DESC,a.id DESC LIMIT 1;

  PERFORM set_config('marketroute.authority_writer','marketroute.r4.commercial-reality',true);

  IF v_previous_authority_id IS NOT NULL THEN
    INSERT INTO public.authority_events(authority_record_id,event_type,writer_key,reason_code,metadata_json,occurred_at)
    VALUES(v_previous_authority_id,'SUPERSEDED','marketroute.r4.commercial-reality','R4_NEW_INPUT',jsonb_build_object('newInputFingerprint',v_input_fingerprint),p_reference_time);
  END IF;

  INSERT INTO public.authority_records(
    organisation_id,campaign_id,reasoning_run_id,reasoning_artifact_id,authority_stage,subject_type,subject_id,decision_code,
    writer_key,writer_version,input_fingerprint,authority_fingerprint,parent_authority_fingerprints,payload_json,valid_from,valid_until
  ) VALUES (
    p_organisation_id,p_campaign_id,v_reasoning_run_id,v_reasoning_artifact_id,'COMMERCIAL_REALITY','COMPANY',p_company_id,p_decision_code,
    'marketroute.r4.commercial-reality','1.0.0',v_input_fingerprint,v_authority_fingerprint,'[]'::jsonb,v_payload,p_reference_time,v_valid_until
  ) RETURNING id INTO v_authority_id;

  INSERT INTO public.authority_events(authority_record_id,event_type,writer_key,reason_code,metadata_json,occurred_at)
  VALUES(v_authority_id,'GRANTED','marketroute.r4.commercial-reality','R4_EVIDENCE_QUALIFIED_DECISION',jsonb_build_object('decision',p_decision_code),p_reference_time);

  INSERT INTO public.commercial_reality_r4_records(
    organisation_id,campaign_id,company_id,authority_record_id,seller_context_selection_id,target_truth_entity_snapshot_id,
    constraint_truth_snapshot_map,boundary_constitution_key,boundary_constitution_version,reality_class,engine_version,semantics_version,
    decision_code,boundaries_json,input_fingerprint,authority_fingerprint,reference_time,next_revalidation_at
  ) VALUES (
    p_organisation_id,p_campaign_id,p_company_id,v_authority_id,p_seller_context_selection_id,p_target_truth_entity_snapshot_id,
    p_constraint_truth_snapshot_map,'SELLER_TO_TARGET_V1',p_boundary_constitution_version,p_reality_class,p_engine_version,p_semantics_version,
    p_decision_code,p_boundaries_json,v_input_fingerprint,v_authority_fingerprint,p_reference_time,p_next_revalidation_at
  ) RETURNING id INTO v_r4_id;

  RETURN QUERY SELECT v_r4_id,v_authority_id,v_reasoning_run_id,v_reasoning_artifact_id,v_input_fingerprint,v_authority_fingerprint,v_valid_until,false;
END;
$$;

--
-- Name: marketroute_persist_contact_authority_r6_v1(uuid, uuid, uuid, timestamp with time zone, text, text, jsonb, text, text, text, jsonb, jsonb, jsonb, jsonb, integer, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_persist_contact_authority_r6_v1(p_organisation_id uuid, p_campaign_id uuid, p_company_id uuid, p_reference_time timestamp with time zone, p_parent_authority_fingerprint text, p_contact_claim_universe_fingerprint text, p_contact_truth_snapshot_map jsonb, p_engine_version text, p_semantics_version text, p_decision_code text, p_bindings_json jsonb, p_authorised_path_fingerprints jsonb, p_authorised_access_point_ids jsonb, p_research_required_access_point_ids jsonb, p_distinct_authorised_access_point_count integer, p_next_revalidation_at timestamp with time zone) RETURNS TABLE(r6_record_id uuid, authority_record_id uuid, reasoning_run_id uuid, reasoning_artifact_id uuid, input_fingerprint text, authority_fingerprint text, valid_until timestamp with time zone, deduplicated boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_context jsonb; v_expected jsonb; v_r5_id uuid; v_r5 public.route_authority_r5_records%ROWTYPE; v_r5_auth public.authority_records%ROWTYPE; v_universe text; v_expected_next timestamptz; v_input text; v_artfp text; v_authfp text; v_run uuid; v_art uuid; v_auth uuid; v_r6 uuid; v_prev uuid; v_payload jsonb; v_existing public.contact_authority_r6_records%ROWTYPE;
BEGIN
 PERFORM public.marketroute_require_service_role();
 IF p_reference_time>now()+interval '5 minutes' THEN RAISE EXCEPTION 'MARKETROUTE_R6_REFERENCE_TIME_IN_FUTURE'; END IF; IF p_reference_time<now()-interval '15 minutes' THEN RAISE EXCEPTION 'MARKETROUTE_R6_REFERENCE_TIME_TOO_OLD_FOR_AUTHORITY'; END IF;
 IF p_engine_version<>'MRV2-R6-ENGINE-1.0.0' OR p_semantics_version<>'MRV2-R6-SEMANTICS-1.0.0' THEN RAISE EXCEPTION 'MARKETROUTE_R6_VERSION_MISMATCH'; END IF;
 IF jsonb_typeof(p_bindings_json)<>'array' OR jsonb_typeof(p_authorised_path_fingerprints)<>'array' OR jsonb_typeof(p_authorised_access_point_ids)<>'array' OR jsonb_typeof(p_research_required_access_point_ids)<>'array' THEN RAISE EXCEPTION 'MARKETROUTE_R6_PAYLOAD_SHAPE_INVALID'; END IF;
 v_context:=public.marketroute_get_r6_context_v1(p_organisation_id,p_campaign_id,p_company_id,p_reference_time,p_contact_truth_snapshot_map); v_expected:=public.marketroute_r6_expected_v1(v_context);
 v_r5_id:=(v_context#>>'{parentR5,authorityRecordId}')::uuid; SELECT * INTO v_r5 FROM public.route_authority_r5_records AS r WHERE r.authority_record_id=v_r5_id; IF NOT FOUND THEN SELECT * INTO v_r5 FROM public.route_authority_r5_records WHERE id=public.marketroute_r6_current_r5_record_v1(p_organisation_id,p_campaign_id,p_company_id,p_reference_time); END IF; SELECT * INTO v_r5_auth FROM public.authority_records WHERE id=v_r5.authority_record_id;
 v_universe:=v_context->>'contactClaimUniverseFingerprint'; IF p_parent_authority_fingerprint IS DISTINCT FROM v_r5_auth.authority_fingerprint THEN RAISE EXCEPTION 'MARKETROUTE_R6_PARENT_FINGERPRINT_MISMATCH'; END IF; IF p_contact_claim_universe_fingerprint IS DISTINCT FROM v_universe THEN RAISE EXCEPTION 'MARKETROUTE_R6_CONTACT_CLAIM_UNIVERSE_FINGERPRINT_MISMATCH'; END IF;
 SELECT COALESCE(jsonb_agg(value ORDER BY value->>'pathFingerprint'),'[]'::jsonb) INTO p_bindings_json FROM jsonb_array_elements(p_bindings_json) value;
 SELECT COALESCE(jsonb_agg(DISTINCT value ORDER BY value),'[]'::jsonb) INTO p_authorised_path_fingerprints FROM jsonb_array_elements_text(p_authorised_path_fingerprints) value; SELECT COALESCE(jsonb_agg(DISTINCT value ORDER BY value),'[]'::jsonb) INTO p_authorised_access_point_ids FROM jsonb_array_elements_text(p_authorised_access_point_ids) value; SELECT COALESCE(jsonb_agg(DISTINCT value ORDER BY value),'[]'::jsonb) INTO p_research_required_access_point_ids FROM jsonb_array_elements_text(p_research_required_access_point_ids) value;
 IF p_decision_code IS DISTINCT FROM v_expected->>'decision' THEN RAISE EXCEPTION 'MARKETROUTE_R6_DECISION_MISMATCH'; END IF; IF p_bindings_json IS DISTINCT FROM v_expected->'bindings' THEN RAISE EXCEPTION 'MARKETROUTE_R6_BINDINGS_MISMATCH'; END IF; IF p_authorised_path_fingerprints IS DISTINCT FROM v_expected->'authorisedPathFingerprints' THEN RAISE EXCEPTION 'MARKETROUTE_R6_AUTHORISED_PATH_SET_MISMATCH'; END IF; IF p_authorised_access_point_ids IS DISTINCT FROM v_expected->'authorisedAccessPointIds' THEN RAISE EXCEPTION 'MARKETROUTE_R6_AUTHORISED_ACCESS_POINT_SET_MISMATCH'; END IF; IF p_research_required_access_point_ids IS DISTINCT FROM v_expected->'researchRequiredAccessPointIds' THEN RAISE EXCEPTION 'MARKETROUTE_R6_RESEARCH_REQUIRED_SET_MISMATCH'; END IF; IF p_distinct_authorised_access_point_count<>(v_expected->>'distinctAuthorisedAccessPointCount')::integer THEN RAISE EXCEPTION 'MARKETROUTE_R6_ACCESS_POINT_COUNT_MISMATCH'; END IF;
 SELECT LEAST(v_r5_auth.valid_until,p_reference_time+interval '8 hours',COALESCE(MIN(ts.next_revalidation_at),p_reference_time+interval '8 hours')) INTO v_expected_next FROM public.truth_claim_snapshots ts WHERE ts.id IN(SELECT value::uuid FROM jsonb_each_text(p_contact_truth_snapshot_map));
 IF v_expected_next IS NULL THEN v_expected_next:=LEAST(v_r5_auth.valid_until,p_reference_time+interval '8 hours'); END IF; IF p_next_revalidation_at IS DISTINCT FROM v_expected_next THEN RAISE EXCEPTION 'MARKETROUTE_R6_REVALIDATION_MISMATCH'; END IF; IF v_expected_next<=p_reference_time THEN RAISE EXCEPTION 'MARKETROUTE_R6_VALIDITY_INVALID'; END IF;
 v_input:=encode(extensions.digest(concat_ws('|','MRV2-R6-INPUT-1.0.0',p_organisation_id::text,p_campaign_id::text,p_company_id::text,to_char(p_reference_time AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),v_r5_auth.authority_fingerprint,v_universe,p_contact_truth_snapshot_map::text),'sha256'),'hex');
 SELECT * INTO v_existing FROM public.contact_authority_r6_records r WHERE r.organisation_id=p_organisation_id AND r.campaign_id=p_campaign_id AND r.company_id=p_company_id AND r.input_fingerprint=v_input ORDER BY r.created_at DESC LIMIT 1; IF FOUND THEN SELECT a.id,a.reasoning_run_id,a.reasoning_artifact_id,a.authority_fingerprint,a.valid_until INTO v_auth,v_run,v_art,v_authfp,v_expected_next FROM public.authority_records a WHERE a.id=v_existing.authority_record_id; RETURN QUERY SELECT v_existing.id,v_auth,v_run,v_art,v_input,v_authfp,v_expected_next,true; RETURN; END IF;
 INSERT INTO public.reasoning_runs(organisation_id,campaign_id,reasoning_kind,engine_version,input_fingerprint,status,started_at,completed_at,metadata_json) VALUES(p_organisation_id,p_campaign_id,'CONTACT_TRUTH',p_engine_version,v_input,'SUCCEEDED',p_reference_time,p_reference_time,jsonb_build_object('semanticsVersion',p_semantics_version)) RETURNING id INTO v_run;
 v_payload:=jsonb_build_object('decision',p_decision_code,'parentR5AuthorityFingerprint',v_r5_auth.authority_fingerprint,'contactClaimUniverseFingerprint',v_universe,'contactTruthSnapshotMap',p_contact_truth_snapshot_map,'bindings',p_bindings_json,'authorisedPathFingerprints',p_authorised_path_fingerprints,'authorisedAccessPointIds',p_authorised_access_point_ids,'researchRequiredAccessPointIds',p_research_required_access_point_ids,'distinctAuthorisedAccessPointCount',p_distinct_authorised_access_point_count,'nextRevalidationAt',v_expected_next);
 v_artfp:=encode(extensions.digest('MRV2-R6-ARTIFACT-1.0.0|'||v_input||'|'||v_payload::text,'sha256'),'hex'); INSERT INTO public.reasoning_artifacts(reasoning_run_id,artifact_kind,subject_type,subject_id,artifact_fingerprint,payload_json,evaluated_at) VALUES(v_run,'CONTACT_AUTHORITY_R6','COMPANY',p_company_id,v_artfp,v_payload,p_reference_time) RETURNING id INTO v_art;
 v_authfp:=encode(extensions.digest(concat_ws('|','MRV2-R6-AUTHORITY-1.0.0',v_input,p_decision_code,p_bindings_json::text,p_authorised_path_fingerprints::text,p_authorised_access_point_ids::text,to_char(v_expected_next AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"')),'sha256'),'hex');
 SELECT a.id INTO v_prev FROM public.authority_records a JOIN public.contact_authority_r6_records r ON r.authority_record_id=a.id WHERE r.organisation_id=p_organisation_id AND r.campaign_id=p_campaign_id AND r.company_id=p_company_id AND NOT EXISTS(SELECT 1 FROM public.authority_events e WHERE e.authority_record_id=a.id AND e.event_type IN('SUPERSEDED','INVALIDATED','REVOKED')) ORDER BY a.created_at DESC LIMIT 1;
 PERFORM set_config('marketroute.authority_writer','marketroute.r6.contact-truth',true); IF v_prev IS NOT NULL THEN INSERT INTO public.authority_events(authority_record_id,event_type,writer_key,reason_code,metadata_json,occurred_at) VALUES(v_prev,'SUPERSEDED','marketroute.r6.contact-truth','R6_NEW_CONTACT_TRUTH_INPUT',jsonb_build_object('newInputFingerprint',v_input),p_reference_time); END IF;
 INSERT INTO public.authority_records(organisation_id,campaign_id,reasoning_run_id,reasoning_artifact_id,authority_stage,subject_type,subject_id,decision_code,writer_key,writer_version,input_fingerprint,authority_fingerprint,parent_authority_fingerprints,payload_json,valid_from,valid_until) VALUES(p_organisation_id,p_campaign_id,v_run,v_art,'CONTACT_AUTHORITY','COMPANY',p_company_id,p_decision_code,'marketroute.r6.contact-truth','1.0.0',v_input,v_authfp,jsonb_build_array(v_r5_auth.authority_fingerprint),v_payload,p_reference_time,v_expected_next) RETURNING id INTO v_auth;
 INSERT INTO public.authority_events(authority_record_id,event_type,writer_key,reason_code,metadata_json,occurred_at) VALUES(v_auth,'GRANTED','marketroute.r6.contact-truth','R6_CONTACT_TRUTH_QUALIFIED',jsonb_build_object('decision',p_decision_code),p_reference_time);
 INSERT INTO public.contact_authority_r6_records(organisation_id,campaign_id,company_id,authority_record_id,parent_r5_authority_record_id,parent_r5_authority_fingerprint,contact_claim_universe_fingerprint,contact_truth_snapshot_map,engine_version,semantics_version,decision_code,bindings_json,authorised_path_fingerprints,authorised_access_point_ids,research_required_access_point_ids,distinct_authorised_access_point_count,input_fingerprint,authority_fingerprint,reference_time,next_revalidation_at) VALUES(p_organisation_id,p_campaign_id,p_company_id,v_auth,v_r5.authority_record_id,v_r5_auth.authority_fingerprint,v_universe,p_contact_truth_snapshot_map,p_engine_version,p_semantics_version,p_decision_code,p_bindings_json,p_authorised_path_fingerprints,p_authorised_access_point_ids,p_research_required_access_point_ids,p_distinct_authorised_access_point_count,v_input,v_authfp,p_reference_time,v_expected_next) RETURNING id INTO v_r6;
 RETURN QUERY SELECT v_r6,v_auth,v_run,v_art,v_input,v_authfp,v_expected_next,false;
END $$;

--
-- Name: marketroute_persist_entity_truth_v1(uuid, text, uuid, text, timestamp with time zone, jsonb, text, text, text, integer, integer, integer, integer, integer, integer, numeric, numeric, numeric, numeric, numeric, numeric, numeric, text, timestamp with time zone, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_persist_entity_truth_v1(p_tenant_scope_organisation_id uuid, p_subject_type text, p_subject_id uuid, p_profile_key text, p_reference_time timestamp with time zone, p_claim_snapshot_map jsonb, p_aggregation_version text, p_semantics_version text, p_entity_state text, p_required_claim_count integer, p_known_claim_count integer, p_supported_claim_count integer, p_contradicted_claim_count integer, p_stale_claim_count integer, p_unresolved_claim_count integer, p_coverage numeric, p_current_coverage numeric, p_evidence_sufficiency numeric, p_freshness_coverage numeric, p_coherence numeric, p_truth_index numeric, p_truth_probability numeric, p_probability_state text, p_next_revalidation_at timestamp with time zone, p_payload_json jsonb) RETURNS TABLE(snapshot_id uuid, reasoning_run_id uuid, reasoning_artifact_id uuid, input_fingerprint text, snapshot_fingerprint text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_profile public.truth_entity_profile_registry%ROWTYPE;
  v_required_keys text[];
  v_map_keys text[];
  v_key text;
  v_snapshot_id_text text;
  v_snapshot public.truth_claim_snapshots%ROWTYPE;
  v_positive integer;
  v_contradicted_candidates integer;
  v_stale_candidates integer;
  v_known integer := 0;
  v_supported integer := 0;
  v_contradicted integer := 0;
  v_stale integer := 0;
  v_unresolved integer := 0;
  v_current integer := 0;
  v_represented integer := 0;
  v_sufficiency numeric := 0;
  v_freshness numeric := 0;
  v_next timestamptz;
  v_expected_state text;
  v_expected_coverage numeric;
  v_expected_current_coverage numeric;
  v_expected_sufficiency numeric;
  v_expected_freshness numeric;
  v_expected_coherence numeric;
  v_expected_truth_index numeric;
  v_input_identity text := '';
  v_input_fingerprint text;
  v_snapshot_fingerprint text;
  v_run_id uuid;
  v_artifact_id uuid;
  v_entity_snapshot_id uuid;
  v_existing public.truth_entity_snapshots%ROWTYPE;
  v_metric_tolerance numeric := 0.000001;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF p_reference_time > now() + interval '5 minutes' THEN RAISE EXCEPTION 'MARKETROUTE_TRUTH_REFERENCE_TIME_IN_FUTURE'; END IF;
  IF p_aggregation_version IS DISTINCT FROM 'MRV2-TRUTH-ENTITY-1.0.0' OR p_semantics_version IS DISTINCT FROM 'MRV2-TRUTH-SEM-1.0.0' THEN
    RAISE EXCEPTION 'MARKETROUTE_TRUTH_ENTITY_VERSION_MISMATCH';
  END IF;
  IF p_truth_probability IS NOT NULL OR p_probability_state IS DISTINCT FROM 'UNCALIBRATED' THEN
    RAISE EXCEPTION 'MARKETROUTE_TRUTH_PROBABILITY_FORBIDDEN_UNTIL_CALIBRATED';
  END IF;
  IF jsonb_typeof(p_claim_snapshot_map) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'MARKETROUTE_TRUTH_ENTITY_SNAPSHOT_MAP_REQUIRED'; END IF;

  SELECT * INTO v_profile FROM public.truth_entity_profile_registry WHERE profile_key = p_profile_key AND active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_TRUTH_ENTITY_PROFILE_NOT_FOUND'; END IF;
  IF v_profile.subject_type IS DISTINCT FROM p_subject_type THEN RAISE EXCEPTION 'MARKETROUTE_TRUTH_ENTITY_PROFILE_SUBJECT_MISMATCH'; END IF;

  SELECT array_agg(value ORDER BY ordinality) INTO v_required_keys
  FROM jsonb_array_elements_text(v_profile.required_claim_keys) WITH ORDINALITY AS r(value, ordinality);
  SELECT array_agg(k.key ORDER BY k.key) INTO v_map_keys FROM jsonb_object_keys(p_claim_snapshot_map) AS k(key);

  IF cardinality(v_required_keys) IS DISTINCT FROM p_required_claim_count THEN RAISE EXCEPTION 'MARKETROUTE_TRUTH_ENTITY_REQUIRED_COUNT_MISMATCH'; END IF;
  IF v_map_keys IS NULL OR cardinality(v_map_keys) IS DISTINCT FROM cardinality(v_required_keys)
     OR EXISTS (SELECT unnest(v_required_keys) EXCEPT SELECT unnest(v_map_keys))
     OR EXISTS (SELECT unnest(v_map_keys) EXCEPT SELECT unnest(v_required_keys)) THEN
    RAISE EXCEPTION 'MARKETROUTE_TRUTH_ENTITY_SNAPSHOT_MAP_KEYS_MISMATCH';
  END IF;

  FOREACH v_key IN ARRAY v_required_keys LOOP
    v_snapshot_id_text := p_claim_snapshot_map ->> v_key;
    v_positive := 0;
    v_contradicted_candidates := 0;
    v_stale_candidates := 0;

    IF v_snapshot_id_text IS NULL OR v_snapshot_id_text = '' THEN
      v_unresolved := v_unresolved + 1;
      v_input_identity := v_input_identity || v_key || ':UNRESOLVED;';
      CONTINUE;
    END IF;

    -- A profile key can map to one or more claim truth snapshots. The JSON value is an array of snapshot UUIDs.
    IF jsonb_typeof(p_claim_snapshot_map -> v_key) IS DISTINCT FROM 'array' THEN
      RAISE EXCEPTION 'MARKETROUTE_TRUTH_ENTITY_SNAPSHOT_MAP_VALUE_MUST_BE_ARRAY';
    END IF;
    IF jsonb_array_length(p_claim_snapshot_map -> v_key) = 0 THEN
      v_unresolved := v_unresolved + 1;
      v_input_identity := v_input_identity || v_key || ':UNRESOLVED;';
      CONTINUE;
    END IF;
    IF (SELECT COUNT(*) FROM jsonb_array_elements_text(p_claim_snapshot_map -> v_key))
       IS DISTINCT FROM
       (SELECT COUNT(DISTINCT value) FROM jsonb_array_elements_text(p_claim_snapshot_map -> v_key) AS d(value)) THEN
      RAISE EXCEPTION 'MARKETROUTE_TRUTH_ENTITY_DUPLICATE_CLAIM_SNAPSHOT';
    END IF;

    FOR v_snapshot_id_text IN
      SELECT value FROM jsonb_array_elements_text(p_claim_snapshot_map -> v_key) AS x(value) ORDER BY value
    LOOP
      SELECT * INTO v_snapshot FROM public.truth_claim_snapshots WHERE id = v_snapshot_id_text::uuid;
      IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_TRUTH_ENTITY_CLAIM_SNAPSHOT_NOT_FOUND'; END IF;
      IF v_snapshot.subject_type IS DISTINCT FROM p_subject_type
         OR v_snapshot.subject_id IS DISTINCT FROM p_subject_id
         OR v_snapshot.claim_key IS DISTINCT FROM v_key
         OR (p_tenant_scope_organisation_id IS NULL AND v_snapshot.tenant_scope_organisation_id IS NOT NULL)
         OR (p_tenant_scope_organisation_id IS NOT NULL AND v_snapshot.tenant_scope_organisation_id IS NOT NULL
             AND v_snapshot.tenant_scope_organisation_id <> p_tenant_scope_organisation_id)
         OR v_snapshot.reference_time IS DISTINCT FROM p_reference_time THEN
        RAISE EXCEPTION 'MARKETROUTE_TRUTH_ENTITY_CLAIM_SNAPSHOT_SCOPE_MISMATCH';
      END IF;
      IF v_snapshot.truth_state IN ('KNOWN','SUPPORTED') THEN v_positive := v_positive + 1; END IF;
      IF v_snapshot.truth_state = 'CONTRADICTED' THEN v_contradicted_candidates := v_contradicted_candidates + 1; END IF;
      IF v_snapshot.truth_state = 'STALE' THEN v_stale_candidates := v_stale_candidates + 1; END IF;
      v_input_identity := v_input_identity || v_key || ':' || v_snapshot.snapshot_fingerprint || ';';
      IF v_snapshot.next_revalidation_at IS NOT NULL THEN
        v_next := CASE WHEN v_next IS NULL THEN v_snapshot.next_revalidation_at ELSE LEAST(v_next, v_snapshot.next_revalidation_at) END;
      END IF;
    END LOOP;

    SELECT COUNT(DISTINCT proposition_fingerprint)::integer
    INTO v_positive
    FROM public.truth_claim_snapshots
    WHERE id IN (SELECT z.value::uuid FROM jsonb_array_elements_text(p_claim_snapshot_map -> v_key) AS z(value))
      AND truth_state IN ('KNOWN','SUPPORTED');

    -- Explicit contradiction at a required boundary always outranks positive evidence.
    -- This mirrors claim-level semantics and prevents a KNOWN/SUPPORTED copy from masking a conflicted premise.
    IF v_contradicted_candidates > 0 THEN
      v_contradicted := v_contradicted + 1;
      v_represented := v_represented + 1;
      v_current := v_current + 1;
      SELECT COALESCE(MAX(evidence_sufficiency),0), COALESCE(MAX(freshness_coverage),0)
      INTO v_expected_sufficiency, v_expected_freshness
      FROM public.truth_claim_snapshots
      WHERE id IN (SELECT z.value::uuid FROM jsonb_array_elements_text(p_claim_snapshot_map -> v_key) AS z(value))
        AND truth_state IN ('KNOWN','SUPPORTED','CONTRADICTED');
      v_sufficiency := v_sufficiency + v_expected_sufficiency;
      v_freshness := v_freshness + v_expected_freshness;
    ELSIF v_positive > 1 THEN
      v_contradicted := v_contradicted + 1;
      v_represented := v_represented + 1;
      v_current := v_current + 1;
      SELECT GREATEST(COALESCE(MAX(evidence_sufficiency),0),0), GREATEST(COALESCE(MAX(freshness_coverage),0),0)
      INTO STRICT v_expected_sufficiency, v_expected_freshness
      FROM public.truth_claim_snapshots
      WHERE id IN (SELECT z.value::uuid FROM jsonb_array_elements_text(p_claim_snapshot_map -> v_key) AS z(value))
        AND truth_state IN ('KNOWN','SUPPORTED');
      v_sufficiency := v_sufficiency + v_expected_sufficiency;
      v_freshness := v_freshness + v_expected_freshness;
    ELSIF v_positive = 1 THEN
      SELECT * INTO v_snapshot
      FROM public.truth_claim_snapshots
      WHERE id IN (SELECT z.value::uuid FROM jsonb_array_elements_text(p_claim_snapshot_map -> v_key) AS z(value))
        AND truth_state IN ('KNOWN','SUPPORTED')
      ORDER BY CASE WHEN truth_state = 'KNOWN' THEN 0 ELSE 1 END, evidence_sufficiency DESC, freshness_coverage DESC, id
      LIMIT 1;
      IF v_snapshot.truth_state = 'KNOWN' THEN v_known := v_known + 1; ELSE v_supported := v_supported + 1; END IF;
      v_represented := v_represented + 1;
      v_current := v_current + 1;
      v_sufficiency := v_sufficiency + v_snapshot.evidence_sufficiency;
      v_freshness := v_freshness + v_snapshot.freshness_coverage;
    ELSIF v_stale_candidates > 0 THEN
      v_stale := v_stale + 1;
      v_represented := v_represented + 1;
      SELECT COALESCE(MAX(evidence_sufficiency),0), COALESCE(MAX(freshness_coverage),0)
      INTO v_expected_sufficiency, v_expected_freshness
      FROM public.truth_claim_snapshots
      WHERE id IN (SELECT z.value::uuid FROM jsonb_array_elements_text(p_claim_snapshot_map -> v_key) AS z(value))
        AND truth_state = 'STALE';
      v_sufficiency := v_sufficiency + v_expected_sufficiency;
      v_freshness := v_freshness + v_expected_freshness;
    ELSE
      v_unresolved := v_unresolved + 1;
    END IF;
  END LOOP;

  v_expected_coverage := v_represented::numeric / p_required_claim_count::numeric;
  v_expected_current_coverage := v_current::numeric / p_required_claim_count::numeric;
  v_expected_sufficiency := v_sufficiency / p_required_claim_count::numeric;
  v_expected_freshness := v_freshness / p_required_claim_count::numeric;
  v_expected_coherence := 1::numeric - v_contradicted::numeric / p_required_claim_count::numeric;
  v_expected_truth_index := round(LEAST(v_expected_current_coverage, v_expected_sufficiency, v_expected_freshness, v_expected_coherence) * 100, 2);
  v_expected_state := CASE
    WHEN v_contradicted > 0 THEN 'CONTRADICTED'
    WHEN v_known = p_required_claim_count THEN 'KNOWN'
    WHEN v_known + v_supported = p_required_claim_count THEN 'SUPPORTED'
    WHEN v_current = 0 AND v_stale > 0 THEN 'STALE'
    WHEN v_represented = 0 THEN 'UNRESOLVED'
    ELSE 'PARTIAL'
  END;

  IF p_entity_state IS DISTINCT FROM v_expected_state
     OR p_known_claim_count IS DISTINCT FROM v_known
     OR p_supported_claim_count IS DISTINCT FROM v_supported
     OR p_contradicted_claim_count IS DISTINCT FROM v_contradicted
     OR p_stale_claim_count IS DISTINCT FROM v_stale
     OR p_unresolved_claim_count IS DISTINCT FROM v_unresolved
     OR abs(p_coverage - v_expected_coverage) > v_metric_tolerance
     OR abs(p_current_coverage - v_expected_current_coverage) > v_metric_tolerance
     OR abs(p_evidence_sufficiency - v_expected_sufficiency) > v_metric_tolerance
     OR abs(p_freshness_coverage - v_expected_freshness) > v_metric_tolerance
     OR abs(p_coherence - v_expected_coherence) > v_metric_tolerance
     OR abs(p_truth_index - v_expected_truth_index) > 0.01
     OR (p_next_revalidation_at IS NULL) IS DISTINCT FROM (v_next IS NULL)
     OR (p_next_revalidation_at IS NOT NULL AND v_next IS NOT NULL
         AND abs(extract(epoch FROM (p_next_revalidation_at - v_next))) > 0.002) THEN
    RAISE EXCEPTION 'MARKETROUTE_TRUTH_ENTITY_OUTPUT_DOES_NOT_MATCH_CLAIM_TRUTH';
  END IF;

  v_input_fingerprint := encode(extensions.digest(concat_ws('|',
    'MRV2-TRUTH-ENTITY-CONTEXT-1.0.0',
    COALESCE(p_tenant_scope_organisation_id::text, '-'),
    p_subject_type,
    p_subject_id::text,
    v_profile.profile_key,
    v_profile.profile_version,
    to_char(p_reference_time AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
    v_input_identity
  ), 'sha256'), 'hex');

  v_snapshot_fingerprint := encode(extensions.digest(concat_ws('|',
    'MRV2-TRUTH-ENTITY-SNAPSHOT-1.0.0',
    v_input_fingerprint,
    p_aggregation_version,
    p_semantics_version,
    p_entity_state,
    round(p_coverage,6)::text,
    round(p_current_coverage,6)::text,
    round(p_evidence_sufficiency,6)::text,
    round(p_freshness_coverage,6)::text,
    round(p_coherence,6)::text,
    round(p_truth_index,2)::text,
    p_probability_state,
    COALESCE(to_char(v_next AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'), '-')
  ), 'sha256'), 'hex');

  SELECT tes.* INTO v_existing
  FROM public.truth_entity_snapshots AS tes
  WHERE tes.tenant_scope_organisation_id IS NOT DISTINCT FROM p_tenant_scope_organisation_id
    AND tes.subject_type = p_subject_type
    AND tes.subject_id = p_subject_id
    AND tes.profile_key = p_profile_key
    AND tes.input_fingerprint = v_input_fingerprint;
  IF FOUND THEN
    IF v_existing.snapshot_fingerprint IS DISTINCT FROM v_snapshot_fingerprint THEN
      RAISE EXCEPTION 'MARKETROUTE_TRUTH_ENTITY_SNAPSHOT_COLLISION';
    END IF;
    RETURN QUERY SELECT v_existing.id, v_existing.reasoning_run_id, v_existing.reasoning_artifact_id, v_existing.input_fingerprint, v_existing.snapshot_fingerprint;
    RETURN;
  END IF;

  INSERT INTO public.reasoning_runs(
    organisation_id, campaign_id, reasoning_kind, engine_version, input_fingerprint,
    status, started_at, completed_at, metadata_json
  ) VALUES (
    p_tenant_scope_organisation_id, NULL, 'TRUTH', p_aggregation_version, v_input_fingerprint,
    'SUCCEEDED', p_reference_time, p_reference_time,
    jsonb_build_object('semanticsVersion', p_semantics_version, 'artifact', 'ENTITY_TRUTH', 'profileKey', p_profile_key)
  ) RETURNING id INTO v_run_id;

  INSERT INTO public.reasoning_artifacts(
    reasoning_run_id, artifact_kind, subject_type, subject_id,
    artifact_fingerprint, payload_json, evaluated_at
  ) VALUES (
    v_run_id, 'TRUTH_ENTITY_SNAPSHOT', p_subject_type, p_subject_id,
    v_snapshot_fingerprint,
    jsonb_build_object(
      'aggregationVersion', p_aggregation_version,
      'semanticsVersion', p_semantics_version,
      'subjectType', p_subject_type,
      'subjectId', p_subject_id,
      'profileKey', p_profile_key,
      'profileVersion', v_profile.profile_version,
      'entityState', p_entity_state,
      'truthIndex', round(p_truth_index,2),
      'coverage', round(p_coverage,6),
      'currentCoverage', round(p_current_coverage,6),
      'evidenceSufficiency', round(p_evidence_sufficiency,6),
      'freshnessCoverage', round(p_freshness_coverage,6),
      'coherence', round(p_coherence,6),
      'truthProbability', NULL,
      'probabilityState', p_probability_state,
      'referenceTime', p_reference_time,
      'nextRevalidationAt', v_next
    ),
    p_reference_time
  ) RETURNING id INTO v_artifact_id;

  INSERT INTO public.truth_entity_snapshots(
    reasoning_run_id, reasoning_artifact_id, tenant_scope_organisation_id,
    subject_type, subject_id, profile_key, profile_version,
    aggregation_version, semantics_version, input_fingerprint, snapshot_fingerprint,
    entity_state, required_claim_count, known_claim_count, supported_claim_count,
    contradicted_claim_count, stale_claim_count, unresolved_claim_count,
    coverage, current_coverage, evidence_sufficiency, freshness_coverage, coherence, truth_index,
    truth_probability, probability_state, reference_time, next_revalidation_at,
    claim_snapshot_map, payload_json
  ) VALUES (
    v_run_id, v_artifact_id, p_tenant_scope_organisation_id,
    p_subject_type, p_subject_id, p_profile_key, v_profile.profile_version,
    p_aggregation_version, p_semantics_version, v_input_fingerprint, v_snapshot_fingerprint,
    p_entity_state, p_required_claim_count, p_known_claim_count, p_supported_claim_count,
    p_contradicted_claim_count, p_stale_claim_count, p_unresolved_claim_count,
    round(p_coverage,6), round(p_current_coverage,6), round(p_evidence_sufficiency,6), round(p_freshness_coverage,6), round(p_coherence,6), round(p_truth_index,2),
    NULL, p_probability_state, p_reference_time, v_next,
    p_claim_snapshot_map,
    jsonb_build_object(
      'aggregationVersion', p_aggregation_version,
      'semanticsVersion', p_semantics_version,
      'subjectType', p_subject_type,
      'subjectId', p_subject_id,
      'profileKey', p_profile_key,
      'profileVersion', v_profile.profile_version,
      'entityState', p_entity_state,
      'truthIndex', round(p_truth_index,2),
      'coverage', round(p_coverage,6),
      'currentCoverage', round(p_current_coverage,6),
      'evidenceSufficiency', round(p_evidence_sufficiency,6),
      'freshnessCoverage', round(p_freshness_coverage,6),
      'coherence', round(p_coherence,6),
      'truthProbability', NULL,
      'probabilityState', p_probability_state,
      'referenceTime', p_reference_time,
      'nextRevalidationAt', v_next
    )
  ) RETURNING id INTO v_entity_snapshot_id;

  RETURN QUERY SELECT v_entity_snapshot_id, v_run_id, v_artifact_id, v_input_fingerprint, v_snapshot_fingerprint;
END;
$$;

--
-- Name: marketroute_persist_research_plan_v1(jsonb, text, text, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_persist_research_plan_v1(p_context jsonb, p_planner_version text, p_semantics_version text, p_gap_set_fingerprint text, p_work_units jsonb) RETURNS TABLE(plan_id uuid, created_work_units integer, plan_fingerprint text, deduplicated boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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
$$;

--
-- Name: marketroute_persist_route_authority_r5_v1(uuid, uuid, uuid, timestamp with time zone, text, text, jsonb, text, text, text, jsonb, jsonb, jsonb, integer, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_persist_route_authority_r5_v1(p_organisation_id uuid, p_campaign_id uuid, p_company_id uuid, p_reference_time timestamp with time zone, p_parent_authority_fingerprint text, p_relationship_universe_fingerprint text, p_relationship_truth_snapshot_map jsonb, p_engine_version text, p_semantics_version text, p_decision_code text, p_paths_json jsonb, p_open_access_point_ids jsonb, p_contact_truth_required_access_point_ids jsonb, p_distinct_access_point_count integer, p_next_revalidation_at timestamp with time zone) RETURNS TABLE(r5_record_id uuid, authority_record_id uuid, reasoning_run_id uuid, reasoning_artifact_id uuid, input_fingerprint text, authority_fingerprint text, valid_until timestamp with time zone, deduplicated boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_context jsonb; v_r4_id uuid; v_r4_fp text; v_r4_decision text; v_r4_until timestamptz; v_universe text; v_expected_decision text; v_expected_open jsonb; v_expected_contact jsonb; v_expected_next timestamptz; v_valid_until timestamptz; v_input_fp text; v_payload jsonb; v_run uuid; v_art uuid; v_auth uuid; v_r5 uuid; v_auth_fp text; v_art_fp text; v_previous uuid; v_existing public.route_authority_r5_records%ROWTYPE;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF abs(extract(epoch FROM (now()-p_reference_time)))>600 THEN RAISE EXCEPTION 'MARKETROUTE_R5_REFERENCE_TIME_TOO_OLD_FOR_AUTHORITY'; END IF;
  IF p_engine_version<>'MRV2-R5-ENGINE-1.0.0' OR p_semantics_version<>'MRV2-R5-SEMANTICS-1.0.0' THEN RAISE EXCEPTION 'MARKETROUTE_R5_VERSION_MISMATCH'; END IF;
  IF jsonb_typeof(p_paths_json)<>'array' OR jsonb_typeof(p_open_access_point_ids)<>'array' OR jsonb_typeof(p_contact_truth_required_access_point_ids)<>'array' THEN RAISE EXCEPTION 'MARKETROUTE_R5_PAYLOAD_SHAPE_INVALID'; END IF;
  IF jsonb_array_length(p_paths_json)>512 THEN RAISE EXCEPTION 'MARKETROUTE_R5_PATH_LIMIT_EXCEEDED'; END IF;
  v_context:=public.marketroute_get_r5_context_v1(p_organisation_id,p_campaign_id,p_company_id,p_reference_time,p_relationship_truth_snapshot_map);
  v_r4_id:=(v_context#>>'{parentR4,authorityRecordId}')::uuid; v_r4_fp:=v_context#>>'{parentR4,authorityFingerprint}'; v_r4_decision:=v_context#>>'{parentR4,decisionCode}'; v_r4_until:=(v_context#>>'{parentR4,validUntil}')::timestamptz; v_universe:=v_context->>'relationshipUniverseFingerprint';
  IF p_parent_authority_fingerprint IS DISTINCT FROM v_r4_fp THEN RAISE EXCEPTION 'MARKETROUTE_R5_PARENT_FINGERPRINT_MISMATCH'; END IF;
  IF p_relationship_universe_fingerprint IS DISTINCT FROM v_universe THEN RAISE EXCEPTION 'MARKETROUTE_R5_UNIVERSE_FINGERPRINT_MISMATCH'; END IF;
  v_expected_decision:=public.marketroute_r5_expected_decision_v1(v_r4_decision,p_organisation_id,p_company_id,p_reference_time,p_relationship_truth_snapshot_map);
  IF p_decision_code IS DISTINCT FROM v_expected_decision THEN RAISE EXCEPTION 'MARKETROUTE_R5_DECISION_MISMATCH'; END IF;
  IF v_r4_decision<>'COMMERCIAL_CANDIDATE' THEN
    v_expected_open:='[]'::jsonb; v_expected_contact:='[]'::jsonb;
  ELSE
    SELECT COALESCE(jsonb_agg(access_point_id::text ORDER BY access_point_id::text),'[]'::jsonb) INTO v_expected_open FROM public.marketroute_r5_access_points_v1(p_organisation_id,p_company_id,p_reference_time,p_relationship_truth_snapshot_map);
    SELECT COALESCE(jsonb_agg(access_point_id::text ORDER BY access_point_id::text),'[]'::jsonb) INTO v_expected_contact FROM public.marketroute_r5_access_points_v1(p_organisation_id,p_company_id,p_reference_time,p_relationship_truth_snapshot_map) WHERE requires_contact_truth;
  END IF;
  SELECT COALESCE(jsonb_agg(value ORDER BY value),'[]'::jsonb) INTO p_open_access_point_ids FROM jsonb_array_elements_text(p_open_access_point_ids) value;
  SELECT COALESCE(jsonb_agg(value ORDER BY value),'[]'::jsonb) INTO p_contact_truth_required_access_point_ids FROM jsonb_array_elements_text(p_contact_truth_required_access_point_ids) value;
  IF p_open_access_point_ids IS DISTINCT FROM v_expected_open THEN RAISE EXCEPTION 'MARKETROUTE_R5_OPEN_ACCESS_POINT_SET_MISMATCH'; END IF;
  IF p_contact_truth_required_access_point_ids IS DISTINCT FROM v_expected_contact THEN RAISE EXCEPTION 'MARKETROUTE_R5_CONTACT_REQUIRED_SET_MISMATCH'; END IF;
  IF p_distinct_access_point_count<>jsonb_array_length(v_expected_open) THEN RAISE EXCEPTION 'MARKETROUTE_R5_ACCESS_POINT_COUNT_MISMATCH'; END IF;
  SELECT LEAST(v_r4_until,p_reference_time+interval '12 hours',COALESCE(MIN(ts.next_revalidation_at),p_reference_time+interval '12 hours')) INTO v_expected_next
  FROM public.commercial_relationships cr JOIN public.truth_claim_snapshots ts ON ts.id=(p_relationship_truth_snapshot_map->>cr.id::text)::uuid
  WHERE cr.id IN(SELECT relationship_id FROM public.marketroute_r5_universe_v1(p_organisation_id,p_company_id));
  IF p_next_revalidation_at IS DISTINCT FROM v_expected_next THEN RAISE EXCEPTION 'MARKETROUTE_R5_REVALIDATION_MISMATCH'; END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_paths_json) p WHERE NOT (p ? 'pathFingerprint' AND p ? 'nodeIds' AND p ? 'relationshipIds' AND p ? 'terminalAccessPointId' AND p ? 'pathState' AND p ? 'knowledgeState' AND p ? 'canonicalRelations')) THEN RAISE EXCEPTION 'MARKETROUTE_R5_PATH_PROVENANCE_INCOMPLETE'; END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_paths_json) p WHERE NOT public.marketroute_r5_path_valid_v1(p_organisation_id,p_company_id,p_reference_time,p_relationship_truth_snapshot_map,p)) THEN RAISE EXCEPTION 'MARKETROUTE_R5_PATH_PROVENANCE_INVALID'; END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_paths_json) p WHERE (p->>'terminalAccessPointId') NOT IN (SELECT jsonb_array_elements_text(v_expected_open))) THEN RAISE EXCEPTION 'MARKETROUTE_R5_PATH_TERMINAL_NOT_OPEN'; END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements_text(v_expected_open) a WHERE NOT EXISTS(SELECT 1 FROM jsonb_array_elements(p_paths_json) p WHERE p->>'terminalAccessPointId'=a)) THEN RAISE EXCEPTION 'MARKETROUTE_R5_PATH_SET_OMITS_ACCESS_POINT'; END IF;
  v_valid_until:=v_expected_next;
  IF v_valid_until<=p_reference_time THEN RAISE EXCEPTION 'MARKETROUTE_R5_VALIDITY_INVALID'; END IF;
  v_input_fp:=encode(extensions.digest(concat_ws('|','MRV2-R5-INPUT-1.0.0',p_organisation_id::text,p_campaign_id::text,p_company_id::text,to_char(p_reference_time AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),v_r4_fp,v_universe,p_relationship_truth_snapshot_map::text),'sha256'),'hex');
  SELECT * INTO v_existing FROM public.route_authority_r5_records rr WHERE rr.organisation_id=p_organisation_id AND rr.campaign_id=p_campaign_id AND rr.company_id=p_company_id AND rr.input_fingerprint=v_input_fp ORDER BY rr.created_at DESC LIMIT 1;
  IF FOUND THEN SELECT a.id,a.reasoning_run_id,a.reasoning_artifact_id,a.authority_fingerprint,a.valid_until INTO v_auth,v_run,v_art,v_auth_fp,v_valid_until FROM public.authority_records a WHERE a.id=v_existing.authority_record_id; RETURN QUERY SELECT v_existing.id,v_auth,v_run,v_art,v_input_fp,v_auth_fp,v_valid_until,true; RETURN; END IF;
  INSERT INTO public.reasoning_runs(organisation_id,campaign_id,reasoning_kind,engine_version,input_fingerprint,status,started_at,completed_at,metadata_json) VALUES(p_organisation_id,p_campaign_id,'RELATIONSHIP_GRAPH',p_engine_version,v_input_fp,'SUCCEEDED',p_reference_time,p_reference_time,jsonb_build_object('semanticsVersion',p_semantics_version)) RETURNING id INTO v_run;
  v_payload:=jsonb_build_object('decision',p_decision_code,'parentR4AuthorityFingerprint',v_r4_fp,'relationshipUniverseFingerprint',v_universe,'relationshipTruthSnapshotMap',p_relationship_truth_snapshot_map,'paths',p_paths_json,'openAccessPointIds',v_expected_open,'contactTruthRequiredAccessPointIds',v_expected_contact,'distinctAccessPointCount',p_distinct_access_point_count,'nextRevalidationAt',v_valid_until);
  v_art_fp:=encode(extensions.digest('MRV2-R5-ARTIFACT-1.0.0|'||v_input_fp||'|'||v_payload::text,'sha256'),'hex');
  INSERT INTO public.reasoning_artifacts(reasoning_run_id,artifact_kind,subject_type,subject_id,artifact_fingerprint,payload_json,evaluated_at) VALUES(v_run,'ROUTE_AUTHORITY_R5','COMPANY',p_company_id,v_art_fp,v_payload,p_reference_time) RETURNING id INTO v_art;
  v_auth_fp:=encode(extensions.digest(concat_ws('|','MRV2-R5-AUTHORITY-1.0.0',v_input_fp,p_decision_code,p_paths_json::text,v_expected_open::text,v_expected_contact::text,to_char(v_valid_until AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"')),'sha256'),'hex');
  SELECT a.id INTO v_previous FROM public.authority_records a JOIN public.route_authority_r5_records r ON r.authority_record_id=a.id WHERE r.organisation_id=p_organisation_id AND r.campaign_id=p_campaign_id AND r.company_id=p_company_id AND NOT EXISTS(SELECT 1 FROM public.authority_events e WHERE e.authority_record_id=a.id AND e.event_type IN('SUPERSEDED','INVALIDATED','REVOKED')) ORDER BY a.created_at DESC LIMIT 1;
  PERFORM set_config('marketroute.authority_writer','marketroute.r5.relationship-graph',true);
  IF v_previous IS NOT NULL THEN INSERT INTO public.authority_events(authority_record_id,event_type,writer_key,reason_code,metadata_json,occurred_at) VALUES(v_previous,'SUPERSEDED','marketroute.r5.relationship-graph','R5_NEW_GRAPH_INPUT',jsonb_build_object('newInputFingerprint',v_input_fp),p_reference_time); END IF;
  INSERT INTO public.authority_records(organisation_id,campaign_id,reasoning_run_id,reasoning_artifact_id,authority_stage,subject_type,subject_id,decision_code,writer_key,writer_version,input_fingerprint,authority_fingerprint,parent_authority_fingerprints,payload_json,valid_from,valid_until)
  VALUES(p_organisation_id,p_campaign_id,v_run,v_art,'ROUTE_AUTHORITY','COMPANY',p_company_id,p_decision_code,'marketroute.r5.relationship-graph','1.0.0',v_input_fp,v_auth_fp,jsonb_build_array(v_r4_fp),v_payload,p_reference_time,v_valid_until) RETURNING id INTO v_auth;
  INSERT INTO public.authority_events(authority_record_id,event_type,writer_key,reason_code,metadata_json,occurred_at) VALUES(v_auth,'GRANTED','marketroute.r5.relationship-graph','R5_TRUTH_QUALIFIED_GRAPH',jsonb_build_object('decision',p_decision_code),p_reference_time);
  INSERT INTO public.route_authority_r5_records(organisation_id,campaign_id,company_id,authority_record_id,parent_r4_authority_record_id,parent_r4_authority_fingerprint,relationship_universe_fingerprint,relationship_truth_snapshot_map,engine_version,semantics_version,decision_code,paths_json,open_access_point_ids,contact_truth_required_access_point_ids,distinct_access_point_count,input_fingerprint,authority_fingerprint,reference_time,next_revalidation_at)
  VALUES(p_organisation_id,p_campaign_id,p_company_id,v_auth,v_r4_id,v_r4_fp,v_universe,p_relationship_truth_snapshot_map,p_engine_version,p_semantics_version,p_decision_code,p_paths_json,v_expected_open,v_expected_contact,p_distinct_access_point_count,v_input_fp,v_auth_fp,p_reference_time,v_valid_until) RETURNING id INTO v_r5;
  RETURN QUERY SELECT v_r5,v_auth,v_run,v_art,v_input_fp,v_auth_fp,v_valid_until,false;
END; $$;

--
-- Name: marketroute_persist_seller_genome_v1(uuid, uuid, uuid, text, text, text, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_persist_seller_genome_v1(p_organisation_id uuid, p_seller_business_id uuid, p_source_material_id uuid, p_schema_version text, p_canonicalisation_version text, p_extraction_contract_version text, p_extractor_version text, p_canonical_genome_json jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp', 'extensions'
    AS $$
DECLARE
  v_source public.seller_genome_source_materials%ROWTYPE;
  v_content_fingerprint text;
  v_semantic_fingerprint text;
  v_existing public.seller_commercial_genome_snapshots%ROWTYPE;
  v_id uuid;
  v_missing text[];
  v_unknown_count integer;
  v_offering_count integer;
  v_objective_count integer;
  v_completeness text;
BEGIN
  IF p_schema_version <> 'MRV2-SELLER-GENOME-1.0.0' OR p_canonicalisation_version <> 'MRV2-SELLER-CANON-1.0.0' OR p_extraction_contract_version <> 'MRV2-SELLER-EXTRACT-1.0.0' THEN
    RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_VERSION_MISMATCH';
  END IF;
  IF length(btrim(p_extractor_version)) NOT BETWEEN 1 AND 160 THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_EXTRACTOR_VERSION_INVALID'; END IF;
  SELECT * INTO v_source FROM public.seller_genome_source_materials WHERE id = p_source_material_id;
  IF NOT FOUND OR v_source.organisation_id <> p_organisation_id OR v_source.seller_business_id <> p_seller_business_id THEN
    RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_SOURCE_SCOPE_INVALID';
  END IF;
  PERFORM public.marketroute_seller_genome_validate_v1(p_seller_business_id, p_canonical_genome_json);

  SELECT COALESCE(array_agg(d ORDER BY d), '{}') INTO v_missing
  FROM (
    SELECT key AS d FROM jsonb_each(p_canonical_genome_json->'semantic') WHERE value->>'state' = 'UNKNOWN'
  ) q;
  v_unknown_count := jsonb_array_length(p_canonical_genome_json->'explicitUnknowns');
  v_offering_count := jsonb_array_length(p_canonical_genome_json#>'{semantic,offerings,items}');
  v_objective_count := jsonb_array_length(p_canonical_genome_json#>'{semantic,commercialObjectives,items}');
  v_completeness := CASE WHEN cardinality(v_missing) = 0 THEN 'COMPLETE' ELSE 'PARTIAL' END;

  v_semantic_fingerprint := encode(extensions.digest(concat_ws('|',
    'MRV2-SELLER-GENOME-SEMANTIC-1.0.0',
    p_seller_business_id::text,
    p_schema_version,
    p_canonicalisation_version,
    public.marketroute_seller_genome_semantic_identity_v1(p_canonical_genome_json)::text
  ), 'sha256'), 'hex');
  v_content_fingerprint := encode(extensions.digest(concat_ws('|',
    'MRV2-SELLER-GENOME-CONTENT-1.0.0',
    p_seller_business_id::text,
    v_source.material_fingerprint,
    p_schema_version,
    p_canonicalisation_version,
    p_extraction_contract_version,
    btrim(p_extractor_version),
    p_canonical_genome_json::text
  ), 'sha256'), 'hex');

  SELECT * INTO v_existing FROM public.seller_commercial_genome_snapshots WHERE content_fingerprint = v_content_fingerprint;
  IF FOUND THEN
    IF v_existing.organisation_id <> p_organisation_id OR v_existing.seller_business_id <> p_seller_business_id OR v_existing.source_material_id <> p_source_material_id OR v_existing.canonical_genome_json <> p_canonical_genome_json THEN
      RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_CONTENT_FINGERPRINT_COLLISION';
    END IF;
    RETURN jsonb_build_object('genomeSnapshotId', v_existing.id, 'contentFingerprint', v_existing.content_fingerprint, 'semanticFingerprint', v_existing.semantic_fingerprint, 'semanticCompleteness', v_existing.semantic_completeness, 'deduplicated', true);
  END IF;

  INSERT INTO public.seller_commercial_genome_snapshots(
    organisation_id, seller_business_id, source_material_id,
    schema_version, canonicalisation_version, extraction_contract_version, extractor_version,
    canonical_genome_json, content_fingerprint, semantic_fingerprint,
    semantic_completeness, missing_dimensions, explicit_unknown_count, offering_count, objective_count
  ) VALUES (
    p_organisation_id, p_seller_business_id, p_source_material_id,
    p_schema_version, p_canonicalisation_version, p_extraction_contract_version, btrim(p_extractor_version),
    p_canonical_genome_json, v_content_fingerprint, v_semantic_fingerprint,
    v_completeness, v_missing, v_unknown_count, v_offering_count, v_objective_count
  ) RETURNING id INTO v_id;

  RETURN jsonb_build_object('genomeSnapshotId', v_id, 'contentFingerprint', v_content_fingerprint, 'semanticFingerprint', v_semantic_fingerprint, 'semanticCompleteness', v_completeness, 'deduplicated', false);
END;
$$;

--
-- Name: marketroute_prevent_contact_claim_supersession_v1(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_prevent_contact_claim_supersession_v1() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_claim public.claims%ROWTYPE;
BEGIN
 SELECT * INTO v_claim FROM public.claims WHERE id=NEW.prior_claim_id;
 IF FOUND AND ((v_claim.subject_type='PERSON' AND v_claim.claim_key IN('identity.canonical_name','employment.current','role.current')) OR (v_claim.subject_type='CHANNEL' AND v_claim.claim_key='ownership.current')) THEN
   RAISE EXCEPTION 'MARKETROUTE_CANONICAL_CONTACT_CLAIM_SUPERSESSION_FORBIDDEN';
 END IF;
 RETURN NEW;
END $$;

--
-- Name: marketroute_prevent_relationship_claim_supersession_v1(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_prevent_relationship_claim_supersession_v1() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
  IF EXISTS(SELECT 1 FROM public.commercial_relationships r WHERE r.claim_id=NEW.prior_claim_id) THEN
    RAISE EXCEPTION 'MARKETROUTE_CANONICAL_RELATIONSHIP_CLAIM_SUPERSESSION_FORBIDDEN';
  END IF;
  RETURN NEW;
END; $$;

--
-- Name: marketroute_product_economics_snapshot_v1(timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_product_economics_snapshot_v1(p_at timestamp with time zone DEFAULT now()) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_30d timestamptz:=p_at-interval '30 days';
  v_runs integer:=0; v_claimed integer:=0; v_checkouts integer:=0; v_checkout_completed integer:=0;
  v_paid integer:=0; v_mrr numeric:=0; v_anon_spend numeric:=0; v_ai_30d numeric:=0; v_paid_ai_30d numeric:=0;
  v_plan_counts jsonb:='{}'::jsonb;
BEGIN
  PERFORM public.marketroute_require_service_role();

  SELECT count(*)::int, count(*) FILTER (WHERE status='CLAIMED')::int
  INTO v_runs,v_claimed FROM public.anonymous_discovery_runs;

  SELECT count(*)::int, count(*) FILTER (WHERE status='COMPLETED')::int
  INTO v_checkouts,v_checkout_completed FROM public.marketroute_billing_checkout_attempts;

  SELECT count(*)::int,
         COALESCE(sum(p.monthly_price_gbp),0),
         COALESCE((SELECT jsonb_object_agg(plan_code,cnt) FROM (
           SELECT e.plan_code,count(*)::int cnt
           FROM public.organisation_commercial_entitlements e
           WHERE e.status='ACTIVE' AND e.plan_code IN('STARTER','GROWTH','SCALE')
             AND (e.current_period_start IS NULL OR e.current_period_start<=p_at)
             AND (e.current_period_end IS NULL OR e.current_period_end>p_at)
           GROUP BY e.plan_code
         ) q),'{}'::jsonb)
  INTO v_paid,v_mrr,v_plan_counts
  FROM public.organisation_commercial_entitlements e
  JOIN public.marketroute_plan_catalog p ON p.plan_code=e.plan_code
  WHERE e.status='ACTIVE' AND e.plan_code IN('STARTER','GROWTH','SCALE')
    AND (e.current_period_start IS NULL OR e.current_period_start<=p_at)
    AND (e.current_period_end IS NULL OR e.current_period_end>p_at);

  SELECT COALESCE(sum(a.cost_usd),0) INTO v_anon_spend
  FROM public.ai_usage_events a
  JOIN public.anonymous_discovery_runs d ON d.organisation_id=a.organisation_id;

  SELECT COALESCE(sum(cost_usd),0) INTO v_ai_30d
  FROM public.ai_usage_events WHERE created_at>=v_30d AND created_at<=p_at;

  SELECT COALESCE(sum(a.cost_usd),0) INTO v_paid_ai_30d
  FROM public.ai_usage_events a
  JOIN public.organisation_commercial_entitlements e ON e.organisation_id=a.organisation_id
  WHERE a.created_at>=v_30d AND a.created_at<=p_at
    AND e.status='ACTIVE' AND e.plan_code IN('STARTER','GROWTH','SCALE')
    AND (e.current_period_start IS NULL OR e.current_period_start<=p_at)
    AND (e.current_period_end IS NULL OR e.current_period_end>p_at);

  RETURN jsonb_build_object(
    'generatedAt',p_at,
    'anonymousRuns',v_runs,
    'claimedRuns',v_claimed,
    'claimRatePct',CASE WHEN v_runs=0 THEN 0 ELSE round((v_claimed::numeric/v_runs::numeric)*100,1) END,
    'checkoutAttempts',v_checkouts,
    'checkoutCompleted',v_checkout_completed,
    'checkoutCompletionPct',CASE WHEN v_checkouts=0 THEN 0 ELSE round((v_checkout_completed::numeric/v_checkouts::numeric)*100,1) END,
    'activePaidWorkspaces',v_paid,
    'mrrGbp',v_mrr,
    'activePlanCounts',v_plan_counts,
    'anonymousAiSpendUsd',v_anon_spend,
    'averageAnonymousRunCostUsd',CASE WHEN v_runs=0 THEN 0 ELSE round(v_anon_spend/v_runs,4) END,
    'aiSpend30dUsd',v_ai_30d,
    'paidWorkspaceAiSpend30dUsd',v_paid_ai_30d
  );
END;
$$;

--
-- Name: marketroute_protect_source_identity(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_protect_source_identity() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.source_kind IS DISTINCT FROM OLD.source_kind
     OR NEW.canonical_url IS DISTINCT FROM OLD.canonical_url
     OR NEW.publisher_domain IS DISTINCT FROM OLD.publisher_domain
     OR NEW.source_identity_fingerprint IS DISTINCT FROM OLD.source_identity_fingerprint
     OR NEW.stable_locator IS DISTINCT FROM OLD.stable_locator
     OR NEW.dependence_family_key IS DISTINCT FROM OLD.dependence_family_key
     OR NEW.normalisation_version IS DISTINCT FROM OLD.normalisation_version THEN
    RAISE EXCEPTION 'MARKETROUTE_SOURCE_IDENTITY_IMMUTABLE';
  END IF;
  RETURN NEW;
END;
$$;

--
-- Name: marketroute_public_plan_catalog_v1(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_public_plan_catalog_v1() RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_result jsonb;
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'planCode',p.plan_code,'displayName',p.display_name,'monthlyPriceGbp',p.monthly_price_gbp,
    'researchCapacityUnits',p.research_capacity_units,'activeMarketLimit',p.active_market_limit,
    'teamSeatLimit',p.team_seat_limit,'metadata',p.metadata_json
  ) ORDER BY p.sort_order,p.plan_code),'[]'::jsonb)
  INTO v_result
  FROM public.marketroute_plan_catalog p WHERE p.public_visible=true;
  RETURN v_result;
END;
$$;

--
-- Name: marketroute_queue_engagement_v1(uuid, uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_queue_engagement_v1(p_message_id uuid, p_request_id uuid, p_at timestamp with time zone DEFAULT now()) RETURNS TABLE(queue_item_id uuid, job_id uuid, approval_mode text, deduplicated boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_existing public.engagement_queue_items%ROWTYPE; v_message public.engagement_messages%ROWTYPE; v_strategy public.engagement_strategies%ROWTYPE; v_review public.engagement_ai_reviews%ROWTYPE; v_approval public.engagement_message_approvals%ROWTYPE; v_policy text; v_env jsonb; v_envfp text; v_queue uuid; v_job uuid; v_auto uuid;
BEGIN
 PERFORM public.marketroute_require_service_role(); IF p_request_id IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_QUEUE_REQUEST_ID_REQUIRED'; END IF;
 SELECT * INTO v_existing FROM public.engagement_queue_items WHERE queue_request_id=p_request_id;
 IF FOUND THEN IF v_existing.message_id IS DISTINCT FROM p_message_id THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_QUEUE_IDEMPOTENCY_COLLISION'; END IF; SELECT id INTO v_job FROM public.engagement_delivery_jobs WHERE queue_item_id=v_existing.id; RETURN QUERY SELECT v_existing.id,v_job,v_existing.approval_mode,true; RETURN; END IF;
 IF EXISTS(SELECT 1 FROM public.engagement_queue_items WHERE message_id=p_message_id) THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_MESSAGE_ALREADY_QUEUED'; END IF;
 IF p_at IS NULL OR abs(extract(epoch FROM(now()-p_at)))>300 THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_QUEUE_TIME_NOT_CURRENT'; END IF;
 SELECT * INTO v_message FROM public.engagement_messages WHERE id=p_message_id; IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_MESSAGE_NOT_FOUND'; END IF; SELECT * INTO v_strategy FROM public.engagement_strategies WHERE id=v_message.strategy_id;
 IF NOT public.marketroute_engagement_strategy_current_v1(v_strategy.id,p_at) THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_QUEUE_STRATEGY_NOT_CURRENT'; END IF;
 SELECT * INTO v_review FROM public.engagement_ai_reviews WHERE message_id=p_message_id; IF NOT FOUND OR v_review.verdict<>'PASS' OR v_review.review_contract_version<>'MRV2-ENGAGEMENT-REVIEW-1.0.0' THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_QUEUE_REQUIRES_CATEGORICAL_PASS'; END IF;
 v_policy:=public.marketroute_current_engagement_policy_v1(v_strategy.organisation_id,v_strategy.campaign_id);
 IF v_policy='HUMAN_ONLY' THEN SELECT * INTO v_approval FROM public.engagement_message_approvals WHERE message_id=p_message_id AND approval_mode='HUMAN' ORDER BY created_at DESC,id DESC LIMIT 1; IF v_approval.id IS NULL OR v_approval.decision<>'APPROVE' THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_QUEUE_REQUIRES_HUMAN_APPROVAL'; END IF;
 ELSE
  v_env:=public.marketroute_authority_envelope_v1(v_strategy.organisation_id,v_strategy.campaign_id,v_strategy.company_id,p_at); v_envfp:=public.marketroute_authority_envelope_fingerprint_v1(v_env); v_auto:=gen_random_uuid();
  INSERT INTO public.engagement_message_approvals(approval_request_id,message_id,review_id,approval_mode,actor_user_id,decision,policy_version,authority_envelope_json,authority_envelope_fingerprint,created_at)
  VALUES(v_auto,p_message_id,v_review.id,'AUTOPILOT',NULL,'APPROVE','MRV2-ENGAGEMENT-POLICY-1.0.0',v_env,v_envfp,p_at) RETURNING * INTO v_approval;
 END IF;
 v_env:=public.marketroute_authority_envelope_v1(v_strategy.organisation_id,v_strategy.campaign_id,v_strategy.company_id,p_at); v_envfp:=public.marketroute_authority_envelope_fingerprint_v1(v_env);
 IF v_envfp IS DISTINCT FROM v_strategy.authority_envelope_fingerprint OR NOT public.marketroute_opportunity_executable_now_v1(v_strategy.opportunity_id,p_at) THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_QUEUE_AUTHORITY_CHANGED'; END IF;
 INSERT INTO public.engagement_queue_items(queue_request_id,opportunity_id,organisation_id,campaign_id,company_id,strategy_id,message_id,review_id,approval_id,approval_mode,authority_envelope_json,authority_envelope_fingerprint,queued_at)
 VALUES(p_request_id,v_strategy.opportunity_id,v_strategy.organisation_id,v_strategy.campaign_id,v_strategy.company_id,v_strategy.id,v_message.id,v_review.id,v_approval.id,v_approval.approval_mode,v_env,v_envfp,p_at) RETURNING id INTO v_queue;
 INSERT INTO public.engagement_delivery_jobs(queue_item_id,status,attempt_number,created_at,updated_at) VALUES(v_queue,'PENDING',0,p_at,p_at) RETURNING id INTO v_job;
 INSERT INTO public.engagement_delivery_events(queue_item_id,job_id,event_type,metadata_json,occurred_at) VALUES(v_queue,v_job,'QUEUED',jsonb_build_object('approvalMode',v_approval.approval_mode,'reviewVerdict',v_review.verdict),p_at);
 RETURN QUERY SELECT v_queue,v_job,v_approval.approval_mode,false;
END $$;

--
-- Name: marketroute_r4_authority_current_v1(uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_r4_authority_current_v1(p_authority_record_id uuid, p_at timestamp with time zone DEFAULT now()) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.authority_records a
    JOIN public.commercial_reality_r4_records r ON r.authority_record_id=a.id
    JOIN public.campaign_seller_context_selections s ON s.id=r.seller_context_selection_id
    JOIN public.truth_entity_snapshots t ON t.id=r.target_truth_entity_snapshot_id
    WHERE a.id=p_authority_record_id
      AND a.writer_key='marketroute.r4.commercial-reality'
      AND a.writer_version='1.0.0'
      AND a.authority_stage='COMMERCIAL_REALITY'
      AND a.valid_from <= p_at AND p_at < a.valid_until
      AND r.next_revalidation_at > p_at
      AND s.id = (
        SELECT s2.id FROM public.campaign_seller_context_selections s2
        WHERE s2.organisation_id=r.organisation_id AND s2.campaign_id=r.campaign_id
        ORDER BY s2.created_at DESC,s2.id DESC LIMIT 1
      )
      AND t.snapshot_fingerprint = (a.payload_json->>'targetTruthEntitySnapshotFingerprint')
      -- Premise mutation fails closed immediately, even before an invalidation worker runs.
      AND NOT EXISTS (
        SELECT 1
        FROM public.claims c
        WHERE c.subject_type='COMPANY' AND c.subject_id=r.company_id
          AND c.claim_key IN (SELECT DISTINCT b->>'claimKey' FROM jsonb_array_elements(r.boundaries_json) b WHERE b->>'claimKey' IS NOT NULL)
          AND (c.tenant_scope_organisation_id IS NULL OR c.tenant_scope_organisation_id=r.organisation_id)
          AND c.created_at > r.created_at
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.claim_evidence_links l JOIN public.claims c ON c.id=l.claim_id
        WHERE c.subject_type='COMPANY' AND c.subject_id=r.company_id
          AND c.claim_key IN (SELECT DISTINCT b->>'claimKey' FROM jsonb_array_elements(r.boundaries_json) b WHERE b->>'claimKey' IS NOT NULL)
          AND (c.tenant_scope_organisation_id IS NULL OR c.tenant_scope_organisation_id=r.organisation_id)
          AND l.created_at > r.created_at
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.claim_supersessions x JOIN public.claims c ON c.id=x.prior_claim_id
        WHERE c.subject_type='COMPANY' AND c.subject_id=r.company_id
          AND c.claim_key IN (SELECT DISTINCT b->>'claimKey' FROM jsonb_array_elements(r.boundaries_json) b WHERE b->>'claimKey' IS NOT NULL)
          AND (c.tenant_scope_organisation_id IS NULL OR c.tenant_scope_organisation_id=r.organisation_id)
          AND x.created_at > r.created_at
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.authority_events e
        WHERE e.authority_record_id=a.id AND e.event_type IN ('SUPERSEDED','INVALIDATED','REVOKED') AND e.occurred_at <= p_at
      )
  );
$$;

--
-- Name: marketroute_r4_expected_v1(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_r4_expected_v1(p_context jsonb) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_boundaries jsonb := '[]'::jsonb;
  v_semantic jsonb := p_context #> '{seller,semantic}';
  v_objective_key text := p_context #>> '{seller,objectiveKey}';
  v_state text;
  v_reason text;
  v_set jsonb;
  v_value text;
  v_constraint jsonb;
  v_constraint_key text;
  v_constraint_type text;
  v_claim_key text;
  v_allowed jsonb;
  v_unsatisfied integer := 0;
  v_open integer := 0;
  v_decision text;
  v_reference timestamptz := (p_context->>'referenceTime')::timestamptz;
  v_next timestamptz := v_reference + interval '24 hours';
  v_candidate_next timestamptz;
BEGIN
  -- Seller offering
  IF v_semantic #>> '{offerings,state}' = 'DECLARED' AND jsonb_array_length(v_semantic #> '{offerings,items}') > 0 THEN v_state := 'SATISFIED'; v_reason := 'SELLER_OFFERING_DECLARED';
  ELSE v_state := 'UNRESOLVED'; v_reason := 'SELLER_OFFERING_UNRESOLVED'; v_open := v_open + 1; END IF;
  v_boundaries := v_boundaries || jsonb_build_array(jsonb_build_object('boundaryKey','seller.offering_present','category','MANDATORY','required',true,'state',v_state,'reasonCode',v_reason,'claimKey',NULL,'observedValue',NULL,'expectedValues','[]'::jsonb,'sourceFingerprints','[]'::jsonb,'nextRevalidationAt',NULL));

  -- Seller objective
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_semantic #> '{commercialObjectives,items}') x WHERE x->>'objectiveKey' = v_objective_key) THEN v_state := 'SATISFIED'; v_reason := 'SELLER_OBJECTIVE_SELECTED';
  ELSE v_state := 'UNRESOLVED'; v_reason := 'SELLER_OBJECTIVE_UNRESOLVED'; v_open := v_open + 1; END IF;
  v_boundaries := v_boundaries || jsonb_build_array(jsonb_build_object('boundaryKey','seller.objective_selected','category','MANDATORY','required',true,'state',v_state,'reasonCode',v_reason,'claimKey',NULL,'observedValue',NULL,'expectedValues','[]'::jsonb,'sourceFingerprints','[]'::jsonb,'nextRevalidationAt',NULL));

  -- Seller constraint knowledge
  IF v_semantic #>> '{constraints,state}' = 'UNKNOWN' THEN v_state := 'UNRESOLVED'; v_reason := 'SELLER_CONSTRAINTS_UNKNOWN'; v_open := v_open + 1;
  ELSE v_state := 'SATISFIED'; v_reason := 'SELLER_CONSTRAINTS_REPRESENTED'; END IF;
  v_boundaries := v_boundaries || jsonb_build_array(jsonb_build_object('boundaryKey','seller.constraints_known','category','MANDATORY','required',true,'state',v_state,'reasonCode',v_reason,'claimKey',NULL,'observedValue',NULL,'expectedValues','[]'::jsonb,'sourceFingerprints','[]'::jsonb,'nextRevalidationAt',NULL));

  -- Target identity
  FOR v_constraint_key, v_claim_key IN
    SELECT * FROM (VALUES
      ('target.identity','identity.canonical_name'),
      ('target.canonical_domain','identity.canonical_domain'),
      ('target.current_operation','operation.current')
    ) AS fixed(boundary_key, claim_key)
  LOOP
    v_set := public.marketroute_r4_truth_set_v1(COALESCE(p_context #> ARRAY['targetTruth','coreClaims',v_claim_key], '[]'::jsonb));
    v_candidate_next := NULLIF(v_set->>'nextRevalidationAt','')::timestamptz;
    IF v_candidate_next IS NOT NULL THEN v_next := LEAST(v_next, v_candidate_next); END IF;
    IF v_set->>'state' <> 'RESOLVED' THEN
      v_state := v_set->>'state'; v_reason := 'TARGET_' || v_state; v_value := NULL; v_open := v_open + 1;
    ELSE
      v_value := v_set->>'value';
      IF v_claim_key = 'identity.canonical_name' THEN
        IF length(btrim(COALESCE(v_value,''))) > 0 THEN v_state := 'SATISFIED'; ELSE v_state := 'UNSATISFIED'; END IF;
      ELSIF v_claim_key = 'identity.canonical_domain' THEN
        IF length(btrim(COALESCE(v_value,''))) > 2 AND position('.' in v_value) > 1 THEN v_state := 'SATISFIED'; ELSE v_state := 'UNSATISFIED'; END IF;
      ELSE
        IF lower(btrim(COALESCE(v_value,''))) = 'true' THEN v_state := 'SATISFIED'; ELSE v_state := 'UNSATISFIED'; END IF;
      END IF;
      IF v_state = 'SATISFIED' THEN v_reason := 'TARGET_TRUTH_SATISFIES_BOUNDARY'; ELSE v_reason := 'TARGET_TRUTH_VIOLATES_BOUNDARY'; v_unsatisfied := v_unsatisfied + 1; END IF;
    END IF;
    v_boundaries := v_boundaries || jsonb_build_array(jsonb_build_object(
      'boundaryKey',v_constraint_key,'category','MANDATORY','required',true,'state',v_state,'reasonCode',v_reason,'claimKey',v_claim_key,
      'observedValue',v_value,'expectedValues',CASE WHEN v_claim_key='operation.current' THEN '["true"]'::jsonb ELSE '[]'::jsonb END,
      'sourceFingerprints',COALESCE(v_set->'sourceFingerprints','[]'::jsonb),'nextRevalidationAt',v_set->'nextRevalidationAt'
    ));
  END LOOP;

  -- Dynamic HARD seller constraints.
  IF v_semantic #>> '{constraints,state}' = 'DECLARED' THEN
    FOR v_constraint IN SELECT value FROM jsonb_array_elements(v_semantic #> '{constraints,items}') x(value) WHERE value->>'mode' = 'HARD' ORDER BY value->>'constraintKey' LOOP
      v_constraint_key := v_constraint->>'constraintKey';
      v_constraint_type := lower(btrim(v_constraint->>'constraintType'));
      v_claim_key := public.marketroute_r4_hard_constraint_claim_key_v1(v_constraint_type);
      v_allowed := COALESCE(v_constraint->'valueCodes','[]'::jsonb);
      IF v_claim_key IS NULL THEN
        v_state := 'UNRESOLVED'; v_reason := 'UNSUPPORTED_HARD_CONSTRAINT_TYPE'; v_value := NULL; v_open := v_open + 1;
        v_set := jsonb_build_object('sourceFingerprints','[]'::jsonb,'nextRevalidationAt',NULL);
      ELSE
        v_set := public.marketroute_r4_truth_set_v1(COALESCE(p_context #> ARRAY['targetTruth','constraintClaims',v_claim_key], '[]'::jsonb));
        v_candidate_next := NULLIF(v_set->>'nextRevalidationAt','')::timestamptz;
        IF v_candidate_next IS NOT NULL THEN v_next := LEAST(v_next, v_candidate_next); END IF;
        IF v_set->>'state' <> 'RESOLVED' THEN
          v_state := v_set->>'state'; v_reason := 'HARD_CONSTRAINT_TARGET_' || v_state; v_value := NULL; v_open := v_open + 1;
        ELSE
          v_value := v_set->>'value';
          IF EXISTS (SELECT 1 FROM jsonb_array_elements_text(v_allowed) a(value) WHERE lower(btrim(a.value)) = lower(btrim(COALESCE(v_value,'')))) THEN
            v_state := 'SATISFIED'; v_reason := 'HARD_CONSTRAINT_SATISFIED';
          ELSE
            v_state := 'UNSATISFIED'; v_reason := 'HARD_CONSTRAINT_VIOLATED'; v_unsatisfied := v_unsatisfied + 1;
          END IF;
        END IF;
      END IF;
      v_boundaries := v_boundaries || jsonb_build_array(jsonb_build_object(
        'boundaryKey','hard_constraint.'||v_constraint_key,'category','HARD_CONSTRAINT','required',true,'state',v_state,'reasonCode',v_reason,
        'claimKey',v_claim_key,'observedValue',v_value,'expectedValues',v_allowed,
        'sourceFingerprints',COALESCE(v_set->'sourceFingerprints','[]'::jsonb),'nextRevalidationAt',v_set->'nextRevalidationAt'
      ));
    END LOOP;
  END IF;

  IF v_unsatisfied > 0 THEN v_decision := 'NOT_ADMISSIBLE';
  ELSIF v_open > 0 THEN v_decision := 'RESEARCH_REQUIRED';
  ELSE v_decision := 'COMMERCIAL_CANDIDATE'; END IF;

  RETURN jsonb_build_object('decision',v_decision,'boundaries',v_boundaries,'nextRevalidationAt',public.marketroute_r4_iso_v1(v_next));
END;
$$;

--
-- Name: marketroute_r4_hard_constraint_claim_key_v1(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_r4_hard_constraint_claim_key_v1(p_constraint_type text) RETURNS text
    LANGUAGE sql IMMUTABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  SELECT CASE lower(btrim(p_constraint_type))
    WHEN 'geography' THEN 'profile.country_code'
    WHEN 'country' THEN 'profile.country_code'
    WHEN 'country_code' THEN 'profile.country_code'
    WHEN 'industry' THEN 'profile.industry_code'
    WHEN 'company_size' THEN 'profile.company_size_band'
    WHEN 'company_size_band' THEN 'profile.company_size_band'
    WHEN 'business_model' THEN 'profile.business_model_code'
    ELSE NULL
  END;
$$;

--
-- Name: marketroute_r4_iso_v1(timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_r4_iso_v1(p_value timestamp with time zone) RETURNS text
    LANGUAGE sql IMMUTABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  SELECT CASE WHEN p_value IS NULL THEN NULL ELSE to_char(p_value AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') END;
$$;

--
-- Name: marketroute_r4_scalar_value_v1(text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_r4_scalar_value_v1(p_canonical_value_text text, p_object_json jsonb) RETURNS text
    LANGUAGE sql IMMUTABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  SELECT COALESCE(
    NULLIF(btrim(p_canonical_value_text), ''),
    CASE jsonb_typeof(p_object_json)
      WHEN 'string' THEN p_object_json #>> '{}'
      WHEN 'boolean' THEN p_object_json #>> '{}'
      WHEN 'number' THEN p_object_json #>> '{}'
      WHEN 'object' THEN p_object_json ->> 'value'
      ELSE NULL
    END
  );
$$;

--
-- Name: marketroute_r4_truth_set_v1(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_r4_truth_set_v1(p_snapshot_ids jsonb) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
DECLARE
  v_result jsonb;
  v_total integer := 0;
  v_contradicted integer := 0;
  v_stale integer := 0;
  v_positive integer := 0;
  v_propositions integer := 0;
  v_selected record;
  v_fingerprints jsonb := '[]'::jsonb;
  v_next timestamptz;
BEGIN
  IF p_snapshot_ids IS NULL OR jsonb_typeof(p_snapshot_ids) <> 'array' THEN
    p_snapshot_ids := '[]'::jsonb;
  END IF;

  -- marketroute_get_r4_context_v1 deliberately returns full snapshot objects
  -- to the deterministic TypeScript engine. The database verifier consumes
  -- the same context, so reduce that shape back to its authoritative IDs.
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_snapshot_ids) AS e(value)
    WHERE jsonb_typeof(e.value) = 'object'
  ) THEN
    IF EXISTS (
      SELECT 1
      FROM jsonb_array_elements(p_snapshot_ids) AS e(value)
      WHERE jsonb_typeof(e.value) IS DISTINCT FROM 'object'
         OR jsonb_typeof(e.value -> 'snapshotId') IS DISTINCT FROM 'string'
         OR (e.value ->> 'snapshotId') !~ '^[0-9a-fA-F-]{36}$'
    ) THEN
      RAISE EXCEPTION 'MARKETROUTE_R4_SNAPSHOT_ID_ARRAY_INVALID';
    END IF;

    SELECT COALESCE(
      jsonb_agg(e.value ->> 'snapshotId' ORDER BY e.value ->> 'snapshotId'),
      '[]'::jsonb
    )
    INTO p_snapshot_ids
    FROM jsonb_array_elements(p_snapshot_ids) AS e(value);
  END IF;

  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_snapshot_ids) e
    WHERE jsonb_typeof(e) <> 'string' OR (e #>> '{}') !~ '^[0-9a-fA-F-]{36}$'
  ) THEN
    RAISE EXCEPTION 'MARKETROUTE_R4_SNAPSHOT_ID_ARRAY_INVALID';
  END IF;
  IF (SELECT count(*) FROM jsonb_array_elements_text(p_snapshot_ids))
     <> (SELECT count(DISTINCT value) FROM jsonb_array_elements_text(p_snapshot_ids) x(value)) THEN
    RAISE EXCEPTION 'MARKETROUTE_R4_DUPLICATE_SNAPSHOT_ID';
  END IF;

  SELECT count(*),
         count(*) FILTER (WHERE t.truth_state = 'CONTRADICTED'),
         count(*) FILTER (WHERE t.truth_state = 'STALE'),
         count(*) FILTER (WHERE t.truth_state IN ('KNOWN','SUPPORTED')),
         count(DISTINCT t.proposition_fingerprint) FILTER (WHERE t.truth_state IN ('KNOWN','SUPPORTED')),
         COALESCE(jsonb_agg(DISTINCT t.snapshot_fingerprint ORDER BY t.snapshot_fingerprint), '[]'::jsonb),
         min(t.next_revalidation_at) FILTER (WHERE t.truth_state IN ('KNOWN','SUPPORTED','CONTRADICTED'))
  INTO v_total, v_contradicted, v_stale, v_positive, v_propositions, v_fingerprints, v_next
  FROM public.truth_claim_snapshots t
  WHERE t.id IN (SELECT value::uuid FROM jsonb_array_elements_text(p_snapshot_ids) x(value));

  IF v_total <> jsonb_array_length(p_snapshot_ids) THEN
    RAISE EXCEPTION 'MARKETROUTE_R4_TRUTH_SNAPSHOT_NOT_FOUND';
  END IF;

  IF v_contradicted > 0 OR v_propositions > 1 THEN
    RETURN jsonb_build_object('state','CONTRADICTED','value',NULL,'sourceFingerprints',v_fingerprints,'nextRevalidationAt',public.marketroute_r4_iso_v1(v_next));
  END IF;

  IF v_positive > 0 THEN
    SELECT t.id, t.truth_state, t.snapshot_fingerprint, t.proposition_fingerprint, t.next_revalidation_at,
           c.canonical_value_text, c.object_json
    INTO v_selected
    FROM public.truth_claim_snapshots t
    JOIN public.claims c ON c.id = t.claim_id
    WHERE t.id IN (SELECT value::uuid FROM jsonb_array_elements_text(p_snapshot_ids) x(value))
      AND t.truth_state IN ('KNOWN','SUPPORTED')
    ORDER BY CASE WHEN t.truth_state = 'KNOWN' THEN 0 ELSE 1 END, t.id
    LIMIT 1;

    RETURN jsonb_build_object(
      'state','RESOLVED',
      'value',public.marketroute_r4_scalar_value_v1(v_selected.canonical_value_text, v_selected.object_json),
      'sourceFingerprints',v_fingerprints,
      'nextRevalidationAt',public.marketroute_r4_iso_v1(v_next)
    );
  END IF;

  IF v_stale > 0 THEN
    RETURN jsonb_build_object('state','STALE','value',NULL,'sourceFingerprints',v_fingerprints,'nextRevalidationAt',NULL);
  END IF;

  RETURN jsonb_build_object('state','UNRESOLVED','value',NULL,'sourceFingerprints',v_fingerprints,'nextRevalidationAt',NULL);
END;
$_$;

--
-- Name: marketroute_r5_access_points_v1(uuid, uuid, timestamp with time zone, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_r5_access_points_v1(p_organisation_id uuid, p_company_id uuid, p_reference_time timestamp with time zone, p_snapshot_map jsonb) RETURNS TABLE(access_point_id uuid, requires_contact_truth boolean)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  WITH RECURSIVE target AS (SELECT public.marketroute_r5_target_node_v1(p_company_id) node_id),
  positive AS (
    SELECT r.*,t.direction,t.route_traversable,ts.truth_state
    FROM public.commercial_relationships r
    JOIN public.commercial_relationship_type_registry t ON t.relation_type=r.relation_type
    JOIN public.truth_claim_snapshots ts ON ts.id=(p_snapshot_map->>r.id::text)::uuid
    WHERE r.id IN (SELECT relationship_id FROM public.marketroute_r5_universe_v1(p_organisation_id,p_company_id))
      AND t.route_traversable=true AND ts.truth_state IN ('KNOWN','SUPPORTED')
      AND ts.reference_time=p_reference_time AND ts.next_revalidation_at>p_reference_time
  ), walk(node_id,depth,visited,requires_contact_truth) AS (
    SELECT node_id,0,ARRAY[node_id]::uuid[],false FROM target WHERE node_id IS NOT NULL
    UNION ALL
    SELECT CASE WHEN p.direction='DIRECTED' THEN p.to_node_id WHEN p.from_node_id=w.node_id THEN p.to_node_id ELSE p.from_node_id END,
           w.depth+1,
           w.visited || CASE WHEN p.direction='DIRECTED' THEN p.to_node_id WHEN p.from_node_id=w.node_id THEN p.to_node_id ELSE p.from_node_id END,
           w.requires_contact_truth OR n.node_kind='PERSON'
    FROM walk w JOIN positive p ON ((p.direction='DIRECTED' AND p.from_node_id=w.node_id) OR (p.direction='UNDIRECTED' AND (p.from_node_id=w.node_id OR p.to_node_id=w.node_id)))
    JOIN public.commercial_graph_nodes n ON n.id=CASE WHEN p.direction='DIRECTED' THEN p.to_node_id WHEN p.from_node_id=w.node_id THEN p.to_node_id ELSE p.from_node_id END
    WHERE w.depth<4 AND NOT (n.id=ANY(w.visited))
  )
  SELECT n.id,
    bool_and(w.requires_contact_truth OR n.access_point_kind IN ('PERSONAL_EMAIL','LINKEDIN','PERSONAL_PHONE'))
  FROM walk w JOIN public.commercial_graph_nodes n ON n.id=w.node_id
  WHERE n.node_kind='ACCESS_POINT'
  GROUP BY n.id;
$$;

--
-- Name: marketroute_r5_authority_current_v1(uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_r5_authority_current_v1(p_authority_record_id uuid, p_at timestamp with time zone DEFAULT now()) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  SELECT EXISTS(
    SELECT 1 FROM public.authority_records a JOIN public.route_authority_r5_records r ON r.authority_record_id=a.id
    WHERE a.id=p_authority_record_id AND a.writer_key='marketroute.r5.relationship-graph' AND a.writer_version='1.0.0' AND a.authority_stage='ROUTE_AUTHORITY'
      AND a.valid_from<=p_at AND p_at<a.valid_until AND r.next_revalidation_at>p_at
      AND public.marketroute_r4_authority_current_v1(r.parent_r4_authority_record_id,p_at)
      AND r.parent_r4_authority_fingerprint=(SELECT authority_fingerprint FROM public.authority_records WHERE id=r.parent_r4_authority_record_id)
      AND r.relationship_universe_fingerprint=public.marketroute_r5_universe_fingerprint_v1(r.organisation_id,r.company_id)
      AND NOT EXISTS(
        SELECT 1 FROM public.commercial_relationships cr
        JOIN public.truth_claim_snapshots ts ON ts.id=(r.relationship_truth_snapshot_map->>cr.id::text)::uuid
        WHERE cr.id IN(SELECT relationship_id FROM public.marketroute_r5_universe_v1(r.organisation_id,r.company_id))
          AND (ts.input_fingerprint<>public.marketroute_truth_context_fingerprint_v1(cr.claim_id,ts.reference_time) OR (ts.next_revalidation_at IS NOT NULL AND ts.next_revalidation_at<=p_at))
      )
      AND NOT EXISTS(SELECT 1 FROM public.authority_events e WHERE e.authority_record_id=a.id AND e.event_type IN('SUPERSEDED','INVALIDATED','REVOKED') AND e.occurred_at<=p_at)
  );
$$;

--
-- Name: marketroute_r5_expected_decision_v1(text, uuid, uuid, timestamp with time zone, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_r5_expected_decision_v1(p_r4_decision text, p_organisation_id uuid, p_company_id uuid, p_reference_time timestamp with time zone, p_snapshot_map jsonb) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  SELECT CASE WHEN p_r4_decision<>'COMMERCIAL_CANDIDATE' THEN 'ROUTE_NOT_APPLICABLE'
              WHEN EXISTS(SELECT 1 FROM public.marketroute_r5_access_points_v1(p_organisation_id,p_company_id,p_reference_time,p_snapshot_map)) THEN 'ROUTE_STRUCTURALLY_OPEN'
              ELSE 'ROUTE_RESEARCH_REQUIRED' END;
$$;

--
-- Name: marketroute_r5_path_valid_v1(uuid, uuid, timestamp with time zone, jsonb, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_r5_path_valid_v1(p_organisation_id uuid, p_company_id uuid, p_reference_time timestamp with time zone, p_snapshot_map jsonb, p_path jsonb) RETURNS boolean
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
DECLARE v_nodes text[]; v_rels text[]; v_target uuid; v_terminal public.commercial_graph_nodes%ROWTYPE; v_rel public.commercial_relationships%ROWTYPE; v_type public.commercial_relationship_type_registry%ROWTYPE; v_ts public.truth_claim_snapshots%ROWTYPE; v_from uuid; v_to uuid; v_i integer; v_all_known boolean:=true; v_contact boolean:=false; v_node public.commercial_graph_nodes%ROWTYPE; v_canon jsonb; v_expected_state text; v_expected_knowledge text;
BEGIN
  IF jsonb_typeof(p_path)<>'object' OR jsonb_typeof(p_path->'nodeIds')<>'array' OR jsonb_typeof(p_path->'relationshipIds')<>'array' OR jsonb_typeof(p_path->'canonicalRelations')<>'array' THEN RETURN false; END IF;
  SELECT array_agg(value ORDER BY ord) INTO v_nodes FROM jsonb_array_elements_text(p_path->'nodeIds') WITH ORDINALITY x(value,ord);
  SELECT array_agg(value ORDER BY ord) INTO v_rels FROM jsonb_array_elements_text(p_path->'relationshipIds') WITH ORDINALITY x(value,ord);
  IF COALESCE(array_length(v_nodes,1),0)<2 OR COALESCE(array_length(v_rels,1),0)<>array_length(v_nodes,1)-1 OR jsonb_array_length(p_path->'canonicalRelations')<>COALESCE(array_length(v_rels,1),0) THEN RETURN false; END IF;
  IF (SELECT count(DISTINCT value) FROM unnest(v_nodes) u(value))<>array_length(v_nodes,1) THEN RETURN false; END IF;
  v_target:=public.marketroute_r5_target_node_v1(p_company_id); IF v_nodes[1]::uuid<>v_target THEN RETURN false; END IF;
  FOR v_i IN 1..array_length(v_rels,1) LOOP
    SELECT * INTO v_rel FROM public.commercial_relationships WHERE id=v_rels[v_i]::uuid AND (tenant_scope_organisation_id IS NULL OR tenant_scope_organisation_id=p_organisation_id);
    IF NOT FOUND OR NOT (v_rel.id IN (SELECT relationship_id FROM public.marketroute_r5_universe_v1(p_organisation_id,p_company_id))) THEN RETURN false; END IF;
    SELECT * INTO v_type FROM public.commercial_relationship_type_registry WHERE relation_type=v_rel.relation_type; IF NOT FOUND OR NOT v_type.route_traversable THEN RETURN false; END IF;
    SELECT * INTO v_ts FROM public.truth_claim_snapshots WHERE id=(p_snapshot_map->>v_rel.id::text)::uuid;
    IF NOT FOUND OR v_ts.claim_id<>v_rel.claim_id OR v_ts.reference_time<>p_reference_time OR v_ts.truth_state NOT IN ('KNOWN','SUPPORTED') OR v_ts.next_revalidation_at IS NULL OR v_ts.next_revalidation_at<=p_reference_time THEN RETURN false; END IF;
    v_from:=v_nodes[v_i]::uuid; v_to:=v_nodes[v_i+1]::uuid;
    IF v_type.direction='DIRECTED' THEN IF v_rel.from_node_id<>v_from OR v_rel.to_node_id<>v_to THEN RETURN false; END IF;
    ELSE IF NOT ((v_rel.from_node_id=v_from AND v_rel.to_node_id=v_to) OR (v_rel.from_node_id=v_to AND v_rel.to_node_id=v_from)) THEN RETURN false; END IF; END IF;
    IF v_ts.truth_state<>'KNOWN' THEN v_all_known:=false; END IF;
    SELECT * INTO v_node FROM public.commercial_graph_nodes WHERE id=v_to; IF NOT FOUND THEN RETURN false; END IF;
    IF v_node.node_kind='PERSON' THEN v_contact:=true; END IF;
    v_canon:=p_path->'canonicalRelations'->(v_i-1);
    IF v_canon->>'relationType' IS DISTINCT FROM v_rel.relation_type OR v_canon->>'edgeClass' IS DISTINCT FROM v_type.edge_class OR v_canon->>'direction' IS DISTINCT FROM v_type.direction THEN RETURN false; END IF;
  END LOOP;
  SELECT * INTO v_terminal FROM public.commercial_graph_nodes WHERE id=v_nodes[array_length(v_nodes,1)]::uuid;
  IF NOT FOUND OR v_terminal.node_kind<>'ACCESS_POINT' OR p_path->>'terminalAccessPointId' IS DISTINCT FROM v_terminal.id::text THEN RETURN false; END IF;
  IF v_terminal.access_point_kind IN ('PERSONAL_EMAIL','LINKEDIN','PERSONAL_PHONE') THEN v_contact:=true; END IF;
  v_expected_state:=CASE WHEN v_contact THEN 'CONTACT_TRUTH_REQUIRED' ELSE 'ORGANISATIONAL_OPEN' END;
  v_expected_knowledge:=CASE WHEN v_all_known THEN 'KNOWN' ELSE 'SUPPORTED' END;
  IF p_path->>'pathState' IS DISTINCT FROM v_expected_state OR p_path->>'knowledgeState' IS DISTINCT FROM v_expected_knowledge THEN RETURN false; END IF;
  IF COALESCE(p_path->>'pathFingerprint','') !~ '^[a-f0-9]{64}$' THEN RETURN false; END IF;
  RETURN true;
EXCEPTION WHEN OTHERS THEN RETURN false;
END; $_$;

--
-- Name: marketroute_r5_target_node_v1(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_r5_target_node_v1(p_company_id uuid) RETURNS uuid
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  SELECT id FROM public.commercial_graph_nodes WHERE node_kind='COMPANY' AND company_id=p_company_id AND tenant_scope_organisation_id IS NULL ORDER BY created_at,id LIMIT 1;
$$;

--
-- Name: marketroute_r5_universe_fingerprint_v1(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_r5_universe_fingerprint_v1(p_organisation_id uuid, p_company_id uuid) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  SELECT encode(extensions.digest('MRV2-R5-UNIVERSE-1.0.0|'||COALESCE(string_agg(r.relationship_fingerprint,';' ORDER BY r.relationship_fingerprint),''),'sha256'),'hex')
  FROM public.commercial_relationships r WHERE r.id IN (SELECT relationship_id FROM public.marketroute_r5_universe_v1(p_organisation_id,p_company_id));
$$;

--
-- Name: marketroute_r5_universe_v1(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_r5_universe_v1(p_organisation_id uuid, p_company_id uuid) RETURNS TABLE(relationship_id uuid)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  WITH RECURSIVE target AS (
    SELECT public.marketroute_r5_target_node_v1(p_company_id) AS node_id
  ), walk(node_id,depth,visited) AS (
    SELECT node_id,0,ARRAY[node_id]::uuid[] FROM target WHERE node_id IS NOT NULL
    UNION ALL
    SELECT CASE WHEN t.direction='DIRECTED' THEN r.to_node_id WHEN r.from_node_id=w.node_id THEN r.to_node_id ELSE r.from_node_id END,
           w.depth+1,
           w.visited || CASE WHEN t.direction='DIRECTED' THEN r.to_node_id WHEN r.from_node_id=w.node_id THEN r.to_node_id ELSE r.from_node_id END
    FROM walk w
    JOIN public.commercial_relationships r ON (r.tenant_scope_organisation_id IS NULL OR r.tenant_scope_organisation_id=p_organisation_id)
    JOIN public.commercial_relationship_type_registry t ON t.relation_type=r.relation_type AND t.route_traversable=true
    WHERE w.depth<4
      AND ((t.direction='DIRECTED' AND r.from_node_id=w.node_id) OR (t.direction='UNDIRECTED' AND (r.from_node_id=w.node_id OR r.to_node_id=w.node_id)))
      AND NOT (CASE WHEN t.direction='DIRECTED' THEN r.to_node_id WHEN r.from_node_id=w.node_id THEN r.to_node_id ELSE r.from_node_id END = ANY(w.visited))
  )
  SELECT DISTINCT r.id
  FROM walk w
  JOIN public.commercial_relationships r ON (r.tenant_scope_organisation_id IS NULL OR r.tenant_scope_organisation_id=p_organisation_id)
  JOIN public.commercial_relationship_type_registry t ON t.relation_type=r.relation_type AND t.route_traversable=true
  WHERE w.depth<4 AND ((t.direction='DIRECTED' AND r.from_node_id=w.node_id) OR (t.direction='UNDIRECTED' AND (r.from_node_id=w.node_id OR r.to_node_id=w.node_id)));
$$;

--
-- Name: marketroute_r6_authority_current_v1(uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_r6_authority_current_v1(p_authority_record_id uuid, p_at timestamp with time zone DEFAULT now()) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
 SELECT EXISTS(SELECT 1 FROM public.authority_records a JOIN public.contact_authority_r6_records r ON r.authority_record_id=a.id WHERE a.id=p_authority_record_id AND a.writer_key='marketroute.r6.contact-truth' AND a.writer_version='1.0.0' AND a.authority_stage='CONTACT_AUTHORITY' AND a.valid_from<=p_at AND p_at<a.valid_until AND r.next_revalidation_at>p_at AND public.marketroute_r5_authority_current_v1(r.parent_r5_authority_record_id,p_at) AND r.parent_r5_authority_fingerprint=(SELECT authority_fingerprint FROM public.authority_records WHERE id=r.parent_r5_authority_record_id) AND r.contact_claim_universe_fingerprint=public.marketroute_r6_claim_universe_fingerprint_v1(r.organisation_id,(SELECT id FROM public.route_authority_r5_records WHERE authority_record_id=r.parent_r5_authority_record_id)) AND NOT EXISTS(SELECT 1 FROM public.claims c JOIN public.truth_claim_snapshots ts ON ts.id=(r.contact_truth_snapshot_map->>c.id::text)::uuid WHERE c.id IN(SELECT claim_id FROM public.marketroute_r6_claim_universe_v1(r.organisation_id,(SELECT id FROM public.route_authority_r5_records WHERE authority_record_id=r.parent_r5_authority_record_id))) AND (ts.input_fingerprint<>public.marketroute_truth_context_fingerprint_v1(c.id,ts.reference_time) OR (ts.next_revalidation_at IS NOT NULL AND ts.next_revalidation_at<=p_at))) AND NOT EXISTS(SELECT 1 FROM public.authority_events e WHERE e.authority_record_id=a.id AND e.event_type IN('SUPERSEDED','INVALIDATED','REVOKED') AND e.occurred_at<=p_at));
$$;

--
-- Name: marketroute_r6_claim_refs_v1(uuid, uuid, uuid, uuid, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_r6_claim_refs_v1(p_organisation_id uuid, p_person_id uuid, p_employer_company_id uuid, p_access_point_id uuid, p_kind text, p_snapshot_map jsonb) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
 WITH c AS (
   SELECT c.* FROM public.claims c WHERE (c.tenant_scope_organisation_id IS NULL OR c.tenant_scope_organisation_id=p_organisation_id) AND NOT EXISTS(SELECT 1 FROM public.claim_supersessions s WHERE s.prior_claim_id=c.id) AND (
     (p_kind='IDENTITY' AND c.subject_type='PERSON' AND c.subject_id=p_person_id AND c.claim_key='identity.canonical_name') OR
     (p_kind='EMPLOYMENT' AND c.subject_type='PERSON' AND c.subject_id=p_person_id AND c.claim_key='employment.current' AND c.object_json->>'companyId'=p_employer_company_id::text) OR
     (p_kind='ROLE' AND c.subject_type='PERSON' AND c.subject_id=p_person_id AND c.claim_key='role.current' AND c.object_json->>'companyId'=p_employer_company_id::text) OR
     (p_kind='CHANNEL' AND c.subject_type='CHANNEL' AND c.subject_id=p_access_point_id AND c.claim_key='ownership.current')
   )
 )
 SELECT COALESCE(jsonb_agg(jsonb_build_object('claimId',c.id,'snapshotId',ts.id,'snapshotFingerprint',ts.snapshot_fingerprint,'truthState',ts.truth_state,'nextRevalidationAt',ts.next_revalidation_at,'roleTitle',c.object_json->>'roleTitle','canonicalValueText',c.canonical_value_text,'objectJson',c.object_json) ORDER BY c.claim_fingerprint),'[]'::jsonb)
 FROM c JOIN public.truth_claim_snapshots ts ON ts.id=(p_snapshot_map->>c.id::text)::uuid;
$$;

--
-- Name: marketroute_r6_claim_universe_fingerprint_v1(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_r6_claim_universe_fingerprint_v1(p_organisation_id uuid, p_r5_record_id uuid) RETURNS text
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_claims text; v_people text; v_parent text;
BEGIN
 SELECT a.authority_fingerprint INTO v_parent FROM public.route_authority_r5_records r JOIN public.authority_records a ON a.id=r.authority_record_id WHERE r.id=p_r5_record_id;
 IF v_parent IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_R6_PARENT_R5_NOT_FOUND'; END IF;
 SELECT COALESCE(string_agg(c.claim_fingerprint,',' ORDER BY c.claim_fingerprint),'') INTO v_claims FROM public.claims c WHERE c.id IN(SELECT claim_id FROM public.marketroute_r6_claim_universe_v1(p_organisation_id,p_r5_record_id));
 SELECT COALESCE(string_agg(p.id::text||':'||p.lifecycle_state,',' ORDER BY p.id::text),'') INTO v_people FROM public.people p WHERE p.id IN(SELECT DISTINCT person_id FROM public.marketroute_r6_path_structure_v1(p_r5_record_id) WHERE person_id IS NOT NULL);
 RETURN encode(extensions.digest(concat_ws('|','MRV2-R6-CLAIM-UNIVERSE-1.0.0',p_organisation_id::text,p_r5_record_id::text,v_parent,v_claims,v_people),'sha256'),'hex');
END $$;

--
-- Name: marketroute_r6_claim_universe_v1(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_r6_claim_universe_v1(p_organisation_id uuid, p_r5_record_id uuid) RETURNS TABLE(claim_id uuid)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
 WITH req AS (SELECT * FROM public.marketroute_r6_path_structure_v1(p_r5_record_id) WHERE r5_path_state='CONTACT_TRUTH_REQUIRED' AND structurally_bindable),
 scoped_claims AS (
   SELECT c.* FROM public.claims c WHERE (c.tenant_scope_organisation_id IS NULL OR c.tenant_scope_organisation_id=p_organisation_id) AND NOT EXISTS(SELECT 1 FROM public.claim_supersessions s WHERE s.prior_claim_id=c.id)
 )
 SELECT DISTINCT c.id FROM req r JOIN scoped_claims c ON
   (c.subject_type='PERSON' AND c.subject_id=r.person_id AND c.claim_key='identity.canonical_name') OR
   (c.subject_type='PERSON' AND c.subject_id=r.person_id AND c.claim_key='employment.current' AND c.object_json->>'companyId'=r.employer_company_id::text) OR
   (c.subject_type='PERSON' AND c.subject_id=r.person_id AND c.claim_key='role.current' AND c.object_json->>'companyId'=r.employer_company_id::text) OR
   (c.subject_type='CHANNEL' AND c.subject_id=r.terminal_access_point_id AND c.claim_key='ownership.current')
 ORDER BY c.id;
$$;

--
-- Name: marketroute_r6_current_r5_record_v1(uuid, uuid, uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_r6_current_r5_record_v1(p_organisation_id uuid, p_campaign_id uuid, p_company_id uuid, p_at timestamp with time zone) RETURNS uuid
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
 SELECT r.id FROM public.route_authority_r5_records r WHERE r.organisation_id=p_organisation_id AND r.campaign_id=p_campaign_id AND r.company_id=p_company_id AND public.marketroute_r5_authority_current_v1(r.authority_record_id,p_at) ORDER BY r.created_at DESC,r.id DESC LIMIT 1;
$$;

--
-- Name: marketroute_r6_exact_group_qualified_v1(jsonb, timestamp with time zone, text, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_r6_exact_group_qualified_v1(p_claims jsonb, p_reference_time timestamp with time zone, p_object_key text, p_expected text, p_block_competing boolean DEFAULT false) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
 SELECT CASE WHEN p_claims IS NULL OR jsonb_typeof(p_claims)<>'array' THEN false
   WHEN EXISTS(SELECT 1 FROM jsonb_array_elements(p_claims) c WHERE lower(btrim(COALESCE(c->'objectJson'->>p_object_key,'')))=lower(btrim(COALESCE(p_expected,''))) AND c->>'truthState'='CONTRADICTED') THEN false
   WHEN p_block_competing AND EXISTS(SELECT 1 FROM jsonb_array_elements(p_claims) c WHERE lower(btrim(COALESCE(c->'objectJson'->>p_object_key,'')))<>lower(btrim(COALESCE(p_expected,''))) AND c->>'truthState' IN('KNOWN','SUPPORTED') AND NULLIF(c->>'nextRevalidationAt','')::timestamptz>p_reference_time) THEN false
   ELSE EXISTS(SELECT 1 FROM jsonb_array_elements(p_claims) c WHERE lower(btrim(COALESCE(c->'objectJson'->>p_object_key,'')))=lower(btrim(COALESCE(p_expected,''))) AND c->>'truthState' IN('KNOWN','SUPPORTED') AND NULLIF(c->>'nextRevalidationAt','')::timestamptz>p_reference_time) END;
$$;

--
-- Name: marketroute_r6_expected_v1(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_r6_expected_v1(p_context jsonb) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE p jsonb; v_bindings jsonb:='[]'::jsonb; v_auth_paths jsonb:='[]'::jsonb; v_auth_access jsonb:='[]'::jsonb; v_research jsonb:='[]'::jsonb; v_ref timestamptz:=(p_context->>'referenceTime')::timestamptz; v_ok boolean; v_reason text; v_mode text; v_state text; v_decision text;
BEGIN
 IF NOT COALESCE((p_context#>>'{parentR5,current}')::boolean,false) OR p_context#>>'{parentR5,decisionCode}'<>'ROUTE_STRUCTURALLY_OPEN' THEN RETURN jsonb_build_object('decision','CONTACT_NOT_APPLICABLE','bindings','[]'::jsonb,'authorisedPathFingerprints','[]'::jsonb,'authorisedAccessPointIds','[]'::jsonb,'researchRequiredAccessPointIds','[]'::jsonb,'distinctAuthorisedAccessPointCount',0); END IF;
 FOR p IN SELECT value FROM jsonb_array_elements(p_context->'paths') LOOP
   IF p->>'r5PathState'='ORGANISATIONAL_OPEN' THEN v_ok:=true;v_mode:='ORGANISATIONAL_ROUTE';v_reason:='ORGANISATIONAL_ACCESS_REQUIRES_NO_PERSON_TRUTH';
   ELSE
     v_ok:=true;v_mode:='NAMED_CONTACT';v_reason:='CONTACT_TRUTH_QUALIFIED';
     IF NULLIF(p->>'personId','') IS NULL OR NULLIF(p->>'employerCompanyId','') IS NULL THEN v_ok:=false;v_reason:='PERSON_OR_EMPLOYER_NOT_STRUCTURALLY_IDENTIFIED';
     ELSIF p->>'personLifecycleState'<>'ACTIVE' THEN v_ok:=false;v_reason:='PERSON_CANONICAL_RECORD_NOT_ACTIVE';
     ELSIF NOT public.marketroute_r6_exact_group_qualified_v1(p->'identityClaims',v_ref,'name',p->>'expectedPersonName',true) THEN v_ok:=false;v_reason:='IDENTITY_NOT_TRUTH_QUALIFIED';
     ELSIF NOT public.marketroute_r6_exact_group_qualified_v1(p->'employmentClaims',v_ref,'companyId',p->>'employerCompanyId',false) THEN v_ok:=false;v_reason:='CURRENT_EMPLOYMENT_NOT_TRUTH_QUALIFIED';
     ELSIF NOT public.marketroute_r6_role_qualified_v1(p->'roleClaims',v_ref,(p->>'employerCompanyId')::uuid) THEN v_ok:=false;v_reason:='CURRENT_ROLE_NOT_TRUTH_QUALIFIED';
     ELSIF NOT public.marketroute_r6_exact_group_qualified_v1(p->'channelOwnershipClaims',v_ref,'personId',p->>'personId',true) THEN v_ok:=false;v_reason:='CHANNEL_OWNERSHIP_NOT_TRUTH_QUALIFIED'; END IF;
   END IF;
   v_state:=CASE WHEN v_ok THEN 'AUTHORISED' ELSE 'CONTACT_TRUTH_REQUIRED' END;
   v_bindings:=v_bindings||jsonb_build_array(jsonb_build_object('pathFingerprint',p->>'pathFingerprint','terminalAccessPointId',p->>'terminalAccessPointId','mode',v_mode,'authorityState',v_state,'personId',NULLIF(p->>'personId',''),'employerCompanyId',NULLIF(p->>'employerCompanyId',''),'reasonCode',v_reason));
   IF v_ok THEN v_auth_paths:=v_auth_paths||jsonb_build_array(p->>'pathFingerprint');v_auth_access:=v_auth_access||jsonb_build_array(p->>'terminalAccessPointId'); ELSE v_research:=v_research||jsonb_build_array(p->>'terminalAccessPointId'); END IF;
 END LOOP;
 SELECT COALESCE(jsonb_agg(DISTINCT value ORDER BY value),'[]'::jsonb) INTO v_auth_paths FROM jsonb_array_elements_text(v_auth_paths) value;
 SELECT COALESCE(jsonb_agg(DISTINCT value ORDER BY value),'[]'::jsonb) INTO v_auth_access FROM jsonb_array_elements_text(v_auth_access) value;
 SELECT COALESCE(jsonb_agg(DISTINCT value ORDER BY value),'[]'::jsonb) INTO v_research FROM jsonb_array_elements_text(v_research) value;
 SELECT COALESCE(jsonb_agg(value ORDER BY value->>'pathFingerprint'),'[]'::jsonb) INTO v_bindings FROM jsonb_array_elements(v_bindings) value;
 v_decision:=CASE WHEN jsonb_array_length(v_auth_paths)>0 THEN 'CONTACT_AUTHORISED' ELSE 'CONTACT_RESEARCH_REQUIRED' END;
 RETURN jsonb_build_object('decision',v_decision,'bindings',v_bindings,'authorisedPathFingerprints',v_auth_paths,'authorisedAccessPointIds',v_auth_access,'researchRequiredAccessPointIds',v_research,'distinctAuthorisedAccessPointCount',jsonb_array_length(v_auth_access));
END $$;

--
-- Name: marketroute_r6_path_structure_v1(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_r6_path_structure_v1(p_r5_record_id uuid) RETURNS TABLE(path_fingerprint text, terminal_access_point_id uuid, r5_path_state text, person_id uuid, employer_company_id uuid, structurally_bindable boolean)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
 WITH paths AS (
   SELECT p.value path FROM public.route_authority_r5_records r CROSS JOIN LATERAL jsonb_array_elements(r.paths_json) p(value) WHERE r.id=p_r5_record_id
 ), base AS (
   SELECT path->>'pathFingerprint' path_fingerprint,(path->>'terminalAccessPointId')::uuid terminal_access_point_id,path->>'pathState' r5_path_state,path
   FROM paths
 ), people AS (
   SELECT b.path_fingerprint,array_agg(n.person_id ORDER BY n.id) person_ids,array_agg(n.id ORDER BY n.id) person_node_ids
   FROM base b CROSS JOIN LATERAL jsonb_array_elements_text(b.path->'nodeIds') x(node_id)
   JOIN public.commercial_graph_nodes n ON n.id=x.node_id::uuid AND n.node_kind='PERSON' GROUP BY b.path_fingerprint
 ), employers AS (
   SELECT b.path_fingerprint,array_agg(DISTINCT cn.company_id ORDER BY cn.company_id) employer_ids
   FROM base b CROSS JOIN LATERAL jsonb_array_elements_text(b.path->'relationshipIds') x(rel_id)
   JOIN public.commercial_relationships cr ON cr.id=x.rel_id::uuid AND cr.relation_type='employs'
   JOIN public.commercial_graph_nodes cn ON cn.id=cr.from_node_id AND cn.node_kind='COMPANY'
   JOIN public.commercial_graph_nodes pn ON pn.id=cr.to_node_id AND pn.node_kind='PERSON'
   GROUP BY b.path_fingerprint
 )
 SELECT b.path_fingerprint,b.terminal_access_point_id,b.r5_path_state,
   CASE WHEN cardinality(COALESCE(p.person_ids,'{}'::uuid[]))=1 THEN p.person_ids[1] ELSE NULL END,
   CASE WHEN cardinality(COALESCE(e.employer_ids,'{}'::uuid[]))=1 THEN e.employer_ids[1] ELSE NULL END,
   CASE WHEN b.r5_path_state='ORGANISATIONAL_OPEN' THEN true ELSE cardinality(COALESCE(p.person_ids,'{}'::uuid[]))=1 AND cardinality(COALESCE(e.employer_ids,'{}'::uuid[]))=1 END
 FROM base b LEFT JOIN people p USING(path_fingerprint) LEFT JOIN employers e USING(path_fingerprint);
$$;

--
-- Name: marketroute_r6_role_qualified_v1(jsonb, timestamp with time zone, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_r6_role_qualified_v1(p_claims jsonb, p_reference_time timestamp with time zone, p_employer_company_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
 WITH matching AS (SELECT c FROM jsonb_array_elements(COALESCE(p_claims,'[]'::jsonb)) c WHERE c->'objectJson'->>'companyId'=p_employer_company_id::text AND length(btrim(COALESCE(c->>'roleTitle','')))>0), roles AS (SELECT lower(btrim(c->>'roleTitle')) role FROM matching GROUP BY lower(btrim(c->>'roleTitle')))
 SELECT EXISTS(SELECT 1 FROM roles r WHERE EXISTS(SELECT 1 FROM matching m WHERE lower(btrim(m.c->>'roleTitle'))=r.role AND m.c->>'truthState' IN('KNOWN','SUPPORTED') AND NULLIF(m.c->>'nextRevalidationAt','')::timestamptz>p_reference_time) AND NOT EXISTS(SELECT 1 FROM matching m WHERE lower(btrim(m.c->>'roleTitle'))=r.role AND m.c->>'truthState'='CONTRADICTED'));
$$;

--
-- Name: marketroute_reconcile_stripe_subscription_v1(uuid, text, text, text, text, timestamp with time zone, timestamp with time zone, boolean, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_reconcile_stripe_subscription_v1(p_organisation_id uuid, p_plan_code text, p_external_customer_id text, p_external_subscription_id text, p_provider_status text, p_current_period_start timestamp with time zone, p_current_period_end timestamp with time zone, p_cancel_at_period_end boolean DEFAULT false, p_external_event_id text DEFAULT NULL::text, p_event_type text DEFAULT NULL::text, p_external_checkout_session_id text DEFAULT NULL::text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_status text;v_provider text:=lower(btrim(COALESCE(p_provider_status,'')));v_existing_org uuid;
  v_limit integer:=0;v_live integer:=0;v_rank integer:=0;v_suspended jsonb:='[]'::jsonb;rec record;v_run public.anonymous_discovery_runs%ROWTYPE;v_original_campaign uuid;v_discovery_restored boolean:=false;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF p_plan_code NOT IN('STARTER','GROWTH','SCALE') OR NOT EXISTS(SELECT 1 FROM public.marketroute_plan_catalog p WHERE p.plan_code=p_plan_code AND p.public_visible=true) THEN RAISE EXCEPTION 'MARKETROUTE_BILLING_PLAN_INVALID'; END IF;
  IF p_external_customer_id IS NULL OR p_external_customer_id !~ '^cus_' THEN RAISE EXCEPTION 'MARKETROUTE_BILLING_CUSTOMER_ID_INVALID'; END IF;
  IF p_external_subscription_id IS NULL OR p_external_subscription_id !~ '^sub_' THEN RAISE EXCEPTION 'MARKETROUTE_BILLING_SUBSCRIPTION_ID_INVALID'; END IF;
  IF p_current_period_end IS NOT NULL AND p_current_period_start IS NOT NULL AND p_current_period_end<=p_current_period_start THEN RAISE EXCEPTION 'MARKETROUTE_BILLING_PERIOD_INVALID'; END IF;
  SELECT organisation_id INTO v_existing_org FROM public.organisation_commercial_entitlements WHERE external_subscription_id=p_external_subscription_id AND organisation_id<>p_organisation_id LIMIT 1;
  IF v_existing_org IS NOT NULL THEN RAISE EXCEPTION 'MARKETROUTE_BILLING_SUBSCRIPTION_ALREADY_OWNED'; END IF;
  v_status:=CASE WHEN v_provider IN('active','trialing') THEN 'ACTIVE' WHEN v_provider='incomplete_expired' THEN 'EXPIRED' WHEN v_provider IN('canceled','unpaid') THEN 'CANCELLED' ELSE 'PAST_DUE' END;
  SELECT p.active_market_limit INTO v_limit FROM public.marketroute_plan_catalog p WHERE p.plan_code=p_plan_code;
  SELECT count(*)::int INTO v_live FROM public.campaigns c WHERE c.organisation_id=p_organisation_id AND c.workflow_state<>'ARCHIVED';
  SELECT r.original_campaign_id INTO v_original_campaign FROM public.anonymous_discovery_runs r WHERE r.organisation_id=p_organisation_id AND r.original_campaign_id IS NOT NULL ORDER BY r.created_at LIMIT 1;

  INSERT INTO public.organisation_commercial_entitlements(organisation_id,plan_code,status,source,external_customer_id,external_subscription_id,current_period_start,current_period_end,activated_at,updated_at,metadata_json)
  VALUES(p_organisation_id,p_plan_code,v_status,'BILLING',p_external_customer_id,p_external_subscription_id,p_current_period_start,p_current_period_end,now(),now(),jsonb_build_object('provider','STRIPE','providerStatus',v_provider,'cancelAtPeriodEnd',COALESCE(p_cancel_at_period_end,false),'lastEventId',p_external_event_id,'lastEventType',p_event_type,'lastReconciledAt',now()))
  ON CONFLICT(organisation_id) DO UPDATE SET plan_code=EXCLUDED.plan_code,status=EXCLUDED.status,source='BILLING',external_customer_id=EXCLUDED.external_customer_id,external_subscription_id=EXCLUDED.external_subscription_id,current_period_start=EXCLUDED.current_period_start,current_period_end=EXCLUDED.current_period_end,activated_at=CASE WHEN organisation_commercial_entitlements.status<>'ACTIVE' AND EXCLUDED.status='ACTIVE' THEN now() ELSE organisation_commercial_entitlements.activated_at END,updated_at=now(),metadata_json=organisation_commercial_entitlements.metadata_json||EXCLUDED.metadata_json;

  IF v_status='ACTIVE' THEN
    FOR rec IN SELECT c.id,c.workflow_state FROM public.campaigns c WHERE c.organisation_id=p_organisation_id AND c.workflow_state<>'ARCHIVED' ORDER BY c.created_at,c.id LOOP
      v_rank:=v_rank+1;
      IF rec.id=v_original_campaign THEN
        INSERT INTO public.research_budget_policies(organisation_id,campaign_id,daily_budget_usd,max_job_cost_usd,max_concurrent_jobs,max_work_units_per_plan,refresh_horizon_hours,enabled,policy_version,updated_at)
        VALUES(p_organisation_id,rec.id,100.00000000,0.50000000,2,4,2,(rec.workflow_state='ACTIVE' AND v_rank<=v_limit),'MRV2-PAID-ENTITLEMENT-TRANSITION-1.0.0',now())
        ON CONFLICT(organisation_id,campaign_id) DO UPDATE SET daily_budget_usd=EXCLUDED.daily_budget_usd,max_job_cost_usd=EXCLUDED.max_job_cost_usd,max_concurrent_jobs=EXCLUDED.max_concurrent_jobs,max_work_units_per_plan=EXCLUDED.max_work_units_per_plan,refresh_horizon_hours=EXCLUDED.refresh_horizon_hours,enabled=EXCLUDED.enabled,policy_version=EXCLUDED.policy_version,updated_at=now();
      ELSE
        INSERT INTO public.research_budget_policies(organisation_id,campaign_id,daily_budget_usd,max_job_cost_usd,max_concurrent_jobs,max_work_units_per_plan,refresh_horizon_hours,enabled,policy_version,updated_at)
        VALUES(p_organisation_id,rec.id,100.00000000,0.50000000,2,4,2,(rec.workflow_state='ACTIVE' AND v_rank<=v_limit),'MRV2-RESEARCH-BUDGET-1.0.0',now())
        ON CONFLICT(organisation_id,campaign_id) DO UPDATE SET enabled=EXCLUDED.enabled,updated_at=now();
      END IF;
      IF v_rank>v_limit THEN v_suspended:=v_suspended||jsonb_build_array(rec.id); END IF;
    END LOOP;
    UPDATE public.organisation_commercial_entitlements SET metadata_json=metadata_json||jsonb_build_object('activeMarketCount',v_live,'activeMarketLimit',v_limit,'capacityOverage',v_live>v_limit,'researchSuspendedCampaignIds',v_suspended,'researchPolicyProfile','PAID'),updated_at=now() WHERE organisation_id=p_organisation_id;
  ELSE
    UPDATE public.research_budget_policies SET enabled=false,updated_at=now() WHERE organisation_id=p_organisation_id;
    SELECT * INTO v_run FROM public.anonymous_discovery_runs r WHERE r.organisation_id=p_organisation_id AND r.original_campaign_id IS NOT NULL AND r.status IN('ACTIVE','CLAIMED') AND r.research_expires_at>now() ORDER BY r.created_at LIMIT 1;
    IF FOUND AND NOT public.marketroute_anonymous_discovery_budget_terminal_v1(v_run.id,now()) THEN
      INSERT INTO public.research_budget_policies(organisation_id,campaign_id,daily_budget_usd,max_job_cost_usd,max_concurrent_jobs,max_work_units_per_plan,refresh_horizon_hours,enabled,policy_version,updated_at)
      SELECT p_organisation_id,v_run.original_campaign_id,LEAST(1.00000000,GREATEST(0.50000000,v_run.lifetime_budget_usd)),0.35000000,1,3,24,(c.workflow_state='ACTIVE'),'MRV2-DISCOVERY-RESTORED-1.0.0',now() FROM public.campaigns c WHERE c.id=v_run.original_campaign_id AND c.organisation_id=p_organisation_id
      ON CONFLICT(organisation_id,campaign_id) DO UPDATE SET daily_budget_usd=EXCLUDED.daily_budget_usd,max_job_cost_usd=EXCLUDED.max_job_cost_usd,max_concurrent_jobs=EXCLUDED.max_concurrent_jobs,max_work_units_per_plan=EXCLUDED.max_work_units_per_plan,refresh_horizon_hours=EXCLUDED.refresh_horizon_hours,enabled=EXCLUDED.enabled,policy_version=EXCLUDED.policy_version,updated_at=now();
      v_discovery_restored:=true;
    END IF;
    UPDATE public.organisation_commercial_entitlements SET metadata_json=metadata_json||jsonb_build_object('capacityOverage',false,'researchSuspendedCampaignIds','[]'::jsonb,'researchPolicyProfile',CASE WHEN v_discovery_restored THEN 'DISCOVERY_RESTORED' ELSE 'INACTIVE' END),updated_at=now() WHERE organisation_id=p_organisation_id;
  END IF;

  IF p_external_checkout_session_id IS NOT NULL THEN
    UPDATE public.marketroute_billing_checkout_attempts SET status=CASE WHEN v_status='ACTIVE' THEN 'COMPLETED' ELSE status END,updated_at=now(),metadata_json=metadata_json||jsonb_build_object('subscriptionId',p_external_subscription_id,'providerStatus',v_provider) WHERE external_checkout_session_id=p_external_checkout_session_id;
  END IF;
  RETURN true;
END;$$;

--
-- Name: marketroute_record_ai_usage_v1(uuid, uuid, text, text, text, bigint, bigint, numeric, integer, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_record_ai_usage_v1(p_organisation_id uuid, p_campaign_id uuid, p_provider text, p_model text, p_request_kind text, p_input_tokens bigint, p_output_tokens bigint, p_cost_usd numeric, p_latency_ms integer, p_status text, p_metadata_json jsonb DEFAULT '{}'::jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_id uuid;
BEGIN
 PERFORM public.marketroute_require_service_role(); IF p_status NOT IN('SUCCEEDED','FAILED','TIMED_OUT','CANCELLED') THEN RAISE EXCEPTION 'MARKETROUTE_AI_USAGE_STATUS_INVALID'; END IF;
 INSERT INTO public.ai_usage_events(organisation_id,campaign_id,provider,model,request_kind,input_tokens,output_tokens,cost_usd,latency_ms,status,metadata_json) VALUES(p_organisation_id,p_campaign_id,left(COALESCE(p_provider,'UNKNOWN'),100),left(COALESCE(p_model,'UNKNOWN'),200),left(COALESCE(p_request_kind,'UNKNOWN'),160),greatest(0,COALESCE(p_input_tokens,0)),greatest(0,COALESCE(p_output_tokens,0)),greatest(0,COALESCE(p_cost_usd,0)),greatest(0,COALESCE(p_latency_ms,0)),p_status,COALESCE(p_metadata_json,'{}'::jsonb)) RETURNING id INTO v_id; RETURN v_id;
END;$$;

--
-- Name: marketroute_record_claim_evidence_v1(uuid, text, uuid, text, text, jsonb, text, text, text, uuid, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_record_claim_evidence_v1(p_tenant_scope_organisation_id uuid, p_subject_type text, p_subject_id uuid, p_claim_key text, p_predicate text, p_object_json jsonb, p_canonical_value_text text, p_claim_fingerprint text, p_claim_fingerprint_version text, p_evidence_item_id uuid, p_polarity text, p_link_method text, p_link_version text) RETURNS TABLE(claim_id uuid, claim_evidence_link_id uuid, claim_created boolean, link_created boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
DECLARE
  v_claim_id uuid;
  v_link_id uuid;
  v_family text;
  v_claim_created boolean := false;
  v_link_created boolean := false;
  v_claim public.claims%ROWTYPE;
BEGIN
  PERFORM public.marketroute_require_service_role();

  IF p_claim_fingerprint !~ '^[a-f0-9]{64}$' THEN RAISE EXCEPTION 'MARKETROUTE_INVALID_CLAIM_FINGERPRINT'; END IF;
  IF length(btrim(COALESCE(p_claim_key, ''))) = 0 OR length(btrim(COALESCE(p_predicate, ''))) = 0 THEN
    RAISE EXCEPTION 'MARKETROUTE_CLAIM_KEY_AND_PREDICATE_REQUIRED';
  END IF;
  IF length(btrim(COALESCE(p_claim_fingerprint_version, ''))) = 0 THEN RAISE EXCEPTION 'MARKETROUTE_CLAIM_VERSION_REQUIRED'; END IF;

  SELECT e.dependence_family_key INTO v_family
  FROM public.evidence_items AS e
  WHERE e.id = p_evidence_item_id;
  IF v_family IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_EVIDENCE_NOT_FOUND'; END IF;

  INSERT INTO public.claims AS c(
    tenant_scope_organisation_id, subject_type, subject_id, claim_key, predicate,
    object_json, canonical_value_text, claim_fingerprint, fingerprint_version
  ) VALUES (
    p_tenant_scope_organisation_id, p_subject_type, p_subject_id, p_claim_key, p_predicate,
    p_object_json, p_canonical_value_text, p_claim_fingerprint, p_claim_fingerprint_version
  )
  ON CONFLICT (claim_fingerprint) DO NOTHING
  RETURNING c.id INTO v_claim_id;

  IF v_claim_id IS NOT NULL THEN
    v_claim_created := true;
  ELSE
    SELECT c.* INTO v_claim
    FROM public.claims AS c
    WHERE c.claim_fingerprint = p_claim_fingerprint;
    v_claim_id := v_claim.id;
    IF v_claim.tenant_scope_organisation_id IS DISTINCT FROM p_tenant_scope_organisation_id
       OR v_claim.subject_type IS DISTINCT FROM p_subject_type
       OR v_claim.subject_id IS DISTINCT FROM p_subject_id
       OR v_claim.claim_key IS DISTINCT FROM p_claim_key
       OR v_claim.predicate IS DISTINCT FROM p_predicate
       OR v_claim.object_json IS DISTINCT FROM p_object_json
       OR v_claim.canonical_value_text IS DISTINCT FROM p_canonical_value_text
       OR v_claim.fingerprint_version IS DISTINCT FROM p_claim_fingerprint_version THEN
      RAISE EXCEPTION 'MARKETROUTE_CLAIM_FINGERPRINT_COLLISION';
    END IF;
  END IF;

  INSERT INTO public.claim_evidence_links AS cel(
    claim_id, evidence_item_id, polarity, dependence_family_key, link_method, link_version
  ) VALUES (
    v_claim_id, p_evidence_item_id, p_polarity, v_family, p_link_method, p_link_version
  )
  ON CONFLICT ON CONSTRAINT claim_evidence_links_claim_id_evidence_item_id_polarity_key DO NOTHING
  RETURNING cel.id INTO v_link_id;

  IF v_link_id IS NOT NULL THEN
    v_link_created := true;
  ELSE
    SELECT cel.id INTO v_link_id
    FROM public.claim_evidence_links AS cel
    WHERE cel.claim_id = v_claim_id
      AND cel.evidence_item_id = p_evidence_item_id
      AND cel.polarity = p_polarity;
  END IF;

  RETURN QUERY SELECT v_claim_id, v_link_id, v_claim_created, v_link_created;
END;
$_$;

--
-- Name: marketroute_record_engagement_ai_review_v1(uuid, uuid, text, text, text, text[], jsonb, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_record_engagement_ai_review_v1(p_message_id uuid, p_request_id uuid, p_review_contract_version text, p_reviewer_version text, p_verdict text, p_reason_codes text[], p_diagnostics_json jsonb, p_at timestamp with time zone DEFAULT now()) RETURNS TABLE(review_id uuid, verdict text, review_fingerprint text, deduplicated boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
DECLARE v_existing public.engagement_ai_reviews%ROWTYPE; v_message public.engagement_messages%ROWTYPE; v_reasons text[]; v_diag jsonb:=COALESCE(p_diagnostics_json,'{}'::jsonb); v_fp text; v_id uuid;
BEGIN
 PERFORM public.marketroute_require_service_role(); IF p_request_id IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_REVIEW_REQUEST_ID_REQUIRED'; END IF;
 SELECT * INTO v_existing FROM public.engagement_ai_reviews WHERE review_request_id=p_request_id;
 IF FOUND THEN
  IF v_existing.message_id IS DISTINCT FROM p_message_id OR v_existing.reviewer_version IS DISTINCT FROM btrim(p_reviewer_version) OR v_existing.verdict IS DISTINCT FROM p_verdict THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_REVIEW_IDEMPOTENCY_COLLISION'; END IF;
  RETURN QUERY SELECT v_existing.id,v_existing.verdict,v_existing.review_fingerprint,true; RETURN;
 END IF;
 IF EXISTS(SELECT 1 FROM public.engagement_ai_reviews WHERE message_id=p_message_id) THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_MESSAGE_ALREADY_REVIEWED'; END IF;
 IF p_at IS NULL OR abs(extract(epoch FROM(now()-p_at)))>300 THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_REVIEW_TIME_NOT_CURRENT'; END IF;
 IF p_review_contract_version<>'MRV2-ENGAGEMENT-REVIEW-1.0.0' OR p_verdict NOT IN('PASS','REWRITE','BLOCK') THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_REVIEW_CONTRACT_INVALID'; END IF;
 IF length(btrim(COALESCE(p_reviewer_version,''))) NOT BETWEEN 1 AND 160 THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_REVIEWER_VERSION_INVALID'; END IF;
 IF jsonb_typeof(v_diag)<>'object' THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_REVIEW_DIAGNOSTICS_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_each(v_diag) d(key,value) WHERE d.key !~ '^[A-Za-z][A-Za-z0-9_.-]{0,79}$' OR d.key ~* '(authority|executionpermission|commercialviability|routeauthority|contactauthority)' OR jsonb_typeof(d.value) NOT IN('string','number','boolean','null')) THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_REVIEW_DIAGNOSTIC_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM unnest(COALESCE(p_reason_codes,'{}'::text[])) x WHERE x IS NULL) THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_REVIEW_REASON_INVALID'; END IF;
 SELECT COALESCE(array_agg(DISTINCT upper(btrim(x)) ORDER BY upper(btrim(x))),'{}'::text[]) INTO v_reasons FROM unnest(COALESCE(p_reason_codes,'{}'::text[])) x;
 IF EXISTS(SELECT 1 FROM unnest(v_reasons) x WHERE x !~ '^[A-Z0-9][A-Z0-9_:-]{0,95}$') THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_REVIEW_REASON_INVALID'; END IF;
 IF p_verdict<>'PASS' AND cardinality(v_reasons)=0 THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_NONPASS_REASON_REQUIRED'; END IF;
 SELECT * INTO v_message FROM public.engagement_messages WHERE id=p_message_id; IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_MESSAGE_NOT_FOUND'; END IF;
 IF NOT public.marketroute_engagement_strategy_current_v1(v_message.strategy_id,p_at) THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_REVIEW_STRATEGY_NOT_CURRENT'; END IF;
 v_fp:=encode(extensions.digest(concat_ws('|','MRV2-ENGAGEMENT-REVIEW-1.0.0',v_message.message_fingerprint,p_review_contract_version,btrim(p_reviewer_version),p_verdict,to_jsonb(v_reasons)::text,v_diag::text),'sha256'),'hex');
 INSERT INTO public.engagement_ai_reviews(review_request_id,message_id,review_contract_version,reviewer_version,verdict,reason_codes,diagnostics_json,review_fingerprint,created_at)
 VALUES(p_request_id,p_message_id,p_review_contract_version,btrim(p_reviewer_version),p_verdict,v_reasons,v_diag,v_fp,p_at) RETURNING id INTO v_id;
 RETURN QUERY SELECT v_id,p_verdict,v_fp,false;
END $_$;

--
-- Name: marketroute_record_engagement_message_approval_v1(uuid, uuid, text, uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_record_engagement_message_approval_v1(p_message_id uuid, p_actor_user_id uuid, p_decision text, p_request_id uuid, p_at timestamp with time zone DEFAULT now()) RETURNS TABLE(approval_id uuid, decision text, approval_mode text, deduplicated boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_existing public.engagement_message_approvals%ROWTYPE; v_message public.engagement_messages%ROWTYPE; v_strategy public.engagement_strategies%ROWTYPE; v_review public.engagement_ai_reviews%ROWTYPE; v_env jsonb; v_envfp text; v_id uuid;
BEGIN
 PERFORM public.marketroute_require_service_role(); IF p_request_id IS NULL OR p_actor_user_id IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_APPROVAL_IDENTITY_REQUIRED'; END IF;
 SELECT * INTO v_existing FROM public.engagement_message_approvals WHERE approval_request_id=p_request_id;
 IF FOUND THEN
  IF v_existing.message_id IS DISTINCT FROM p_message_id OR v_existing.actor_user_id IS DISTINCT FROM p_actor_user_id OR v_existing.decision IS DISTINCT FROM p_decision OR v_existing.approval_mode<>'HUMAN' THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_APPROVAL_IDEMPOTENCY_COLLISION'; END IF;
  RETURN QUERY SELECT v_existing.id,v_existing.decision,v_existing.approval_mode,true; RETURN;
 END IF;
 IF p_at IS NULL OR abs(extract(epoch FROM(now()-p_at)))>300 THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_APPROVAL_TIME_NOT_CURRENT'; END IF; IF p_decision NOT IN('APPROVE','REJECT') THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_APPROVAL_DECISION_INVALID'; END IF;
 SELECT * INTO v_message FROM public.engagement_messages WHERE id=p_message_id; IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_MESSAGE_NOT_FOUND'; END IF;
 SELECT * INTO v_strategy FROM public.engagement_strategies WHERE id=v_message.strategy_id; SELECT * INTO v_review FROM public.engagement_ai_reviews WHERE message_id=p_message_id;
 IF v_review.id IS NULL OR v_review.verdict<>'PASS' THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_HUMAN_APPROVAL_REQUIRES_PASS_REVIEW'; END IF;
 IF NOT public.marketroute_engagement_strategy_current_v1(v_strategy.id,p_at) THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_APPROVAL_STRATEGY_NOT_CURRENT'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.organisation_memberships m WHERE m.organisation_id=v_strategy.organisation_id AND m.user_id=p_actor_user_id AND m.status='ACTIVE' AND m.role IN('OWNER','ADMIN','MEMBER')) THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_APPROVER_NOT_AUTHORISED'; END IF;
 PERFORM 1 FROM public.opportunities o WHERE o.id=v_strategy.opportunity_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_OPPORTUNITY_NOT_FOUND'; END IF;
 IF EXISTS(SELECT 1 FROM public.engagement_delivery_jobs j JOIN public.engagement_queue_items q ON q.id=j.queue_item_id WHERE q.opportunity_id=v_strategy.opportunity_id AND j.status='RUNNING') THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_MESSAGE_APPROVAL_BLOCKED_DURING_DELIVERY'; END IF;
 v_env:=public.marketroute_authority_envelope_v1(v_strategy.organisation_id,v_strategy.campaign_id,v_strategy.company_id,p_at); v_envfp:=public.marketroute_engagement_authority_snapshot_fingerprint_v1(v_env);
 INSERT INTO public.engagement_message_approvals(approval_request_id,message_id,review_id,approval_mode,actor_user_id,decision,policy_version,authority_envelope_json,authority_envelope_fingerprint,created_at)
 VALUES(p_request_id,p_message_id,v_review.id,'HUMAN',p_actor_user_id,p_decision,'MRV2-ENGAGEMENT-POLICY-1.0.0',v_env,v_envfp,p_at) RETURNING id INTO v_id;
 RETURN QUERY SELECT v_id,p_decision,'HUMAN'::text,false;
END $$;

--
-- Name: marketroute_record_engagement_message_v1(uuid, uuid, uuid, text, text, text, text, text, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_record_engagement_message_v1(p_strategy_id uuid, p_previous_message_id uuid, p_request_id uuid, p_context_fingerprint text, p_generation_contract_version text, p_generator_version text, p_subject_text text, p_body_text text, p_at timestamp with time zone DEFAULT now()) RETURNS TABLE(message_id uuid, message_fingerprint text, deduplicated boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_existing public.engagement_messages%ROWTYPE; v_strategy public.engagement_strategies%ROWTYPE; v_prev public.engagement_messages%ROWTYPE; v_ordinal int:=0; v_subject text; v_body text; v_fp text; v_id uuid;
BEGIN
 PERFORM public.marketroute_require_service_role(); IF p_request_id IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_MESSAGE_REQUEST_ID_REQUIRED'; END IF;
 SELECT * INTO v_existing FROM public.engagement_messages WHERE generation_request_id=p_request_id;
 IF FOUND THEN
  IF v_existing.strategy_id IS DISTINCT FROM p_strategy_id OR v_existing.previous_message_id IS DISTINCT FROM p_previous_message_id OR v_existing.generation_context_fingerprint IS DISTINCT FROM p_context_fingerprint OR v_existing.generator_version IS DISTINCT FROM btrim(p_generator_version) OR v_existing.subject_text IS DISTINCT FROM NULLIF(btrim(p_subject_text),'') OR v_existing.body_text IS DISTINCT FROM btrim(p_body_text) THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_MESSAGE_IDEMPOTENCY_COLLISION'; END IF;
  RETURN QUERY SELECT v_existing.id,v_existing.message_fingerprint,true; RETURN;
 END IF;
 IF p_at IS NULL OR abs(extract(epoch FROM(now()-p_at)))>300 THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_MESSAGE_TIME_NOT_CURRENT'; END IF;
 IF p_generation_contract_version<>'MRV2-ENGAGEMENT-GENERATION-1.0.0' THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_GENERATION_CONTRACT_MISMATCH'; END IF;
 IF length(btrim(COALESCE(p_generator_version,''))) NOT BETWEEN 1 AND 160 THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_GENERATOR_VERSION_INVALID'; END IF;
 SELECT * INTO v_strategy FROM public.engagement_strategies WHERE id=p_strategy_id; IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_STRATEGY_NOT_FOUND'; END IF;
 IF p_context_fingerprint IS DISTINCT FROM v_strategy.generation_context_fingerprint OR NOT public.marketroute_engagement_strategy_current_v1(v_strategy.id,p_at) THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_STRATEGY_NOT_CURRENT'; END IF;
 v_subject:=NULLIF(btrim(p_subject_text),''); v_body:=btrim(COALESCE(p_body_text,'')); IF length(v_body) NOT BETWEEN 1 AND 8000 THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_BODY_INVALID'; END IF;
 IF v_strategy.channel_kind='EMAIL' THEN IF v_subject IS NULL OR length(v_subject)>300 THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_EMAIL_SUBJECT_REQUIRED'; END IF; ELSE IF v_subject IS NOT NULL THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_NON_EMAIL_SUBJECT_FORBIDDEN'; END IF; END IF;
 IF p_previous_message_id IS NOT NULL THEN SELECT * INTO v_prev FROM public.engagement_messages WHERE id=p_previous_message_id; IF NOT FOUND OR v_prev.strategy_id<>p_strategy_id THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_REWRITE_PARENT_INVALID'; END IF; v_ordinal:=v_prev.rewrite_ordinal+1; END IF;
 IF v_ordinal>2 THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_REWRITE_LIMIT_EXCEEDED'; END IF;
 IF EXISTS(SELECT 1 FROM public.engagement_messages m WHERE m.strategy_id=p_strategy_id AND m.rewrite_ordinal=v_ordinal) THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_REWRITE_ORDINAL_ALREADY_EXISTS'; END IF;
 v_fp:=encode(extensions.digest(concat_ws('|','MRV2-ENGAGEMENT-MESSAGE-1.0.0',v_strategy.strategy_fingerprint,octet_length(COALESCE(v_subject,''))::text,COALESCE(v_subject,''),octet_length(v_body)::text,v_body),'sha256'),'hex');
 INSERT INTO public.engagement_messages(generation_request_id,strategy_id,previous_message_id,rewrite_ordinal,generation_contract_version,generator_version,generation_context_fingerprint,subject_text,body_text,message_fingerprint,created_at)
 VALUES(p_request_id,p_strategy_id,p_previous_message_id,v_ordinal,p_generation_contract_version,btrim(p_generator_version),p_context_fingerprint,v_subject,v_body,v_fp,p_at) RETURNING id INTO v_id;
 RETURN QUERY SELECT v_id,v_fp,false;
END $$;

--
-- Name: marketroute_record_engagement_policy_v1(uuid, uuid, uuid, text, uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_record_engagement_policy_v1(p_organisation_id uuid, p_campaign_id uuid, p_actor_user_id uuid, p_policy_mode text, p_request_id uuid, p_at timestamp with time zone DEFAULT now()) RETURNS TABLE(policy_event_id uuid, policy_mode text, deduplicated boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_existing public.campaign_engagement_policy_events%ROWTYPE; v_id uuid;
BEGIN
 PERFORM public.marketroute_require_service_role();
 IF p_request_id IS NULL OR p_actor_user_id IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_POLICY_IDENTITY_REQUIRED'; END IF;
 SELECT * INTO v_existing FROM public.campaign_engagement_policy_events WHERE request_id=p_request_id;
 IF FOUND THEN
  IF v_existing.organisation_id IS DISTINCT FROM p_organisation_id OR v_existing.campaign_id IS DISTINCT FROM p_campaign_id OR v_existing.actor_user_id IS DISTINCT FROM p_actor_user_id OR v_existing.policy_mode IS DISTINCT FROM p_policy_mode THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_POLICY_IDEMPOTENCY_COLLISION'; END IF;
  RETURN QUERY SELECT v_existing.id,v_existing.policy_mode,true; RETURN;
 END IF;
 IF p_at IS NULL OR abs(extract(epoch FROM(now()-p_at)))>300 THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_POLICY_TIME_NOT_CURRENT'; END IF;
 IF p_policy_mode NOT IN('HUMAN_ONLY','AUTOPILOT') THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_POLICY_MODE_INVALID'; END IF;
 PERFORM 1 FROM public.campaigns c WHERE c.id=p_campaign_id AND c.organisation_id=p_organisation_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_POLICY_CAMPAIGN_SCOPE_MISMATCH'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.organisation_memberships m WHERE m.organisation_id=p_organisation_id AND m.user_id=p_actor_user_id AND m.status='ACTIVE' AND m.role IN('OWNER','ADMIN')) THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_POLICY_ACTOR_NOT_AUTHORISED'; END IF;
 IF EXISTS(SELECT 1 FROM public.engagement_delivery_jobs j JOIN public.engagement_queue_items q ON q.id=j.queue_item_id WHERE q.organisation_id=p_organisation_id AND q.campaign_id=p_campaign_id AND j.status='RUNNING') THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_POLICY_CHANGE_BLOCKED_DURING_DELIVERY'; END IF;
 INSERT INTO public.campaign_engagement_policy_events(request_id,organisation_id,campaign_id,actor_user_id,policy_mode,policy_version,occurred_at)
 VALUES(p_request_id,p_organisation_id,p_campaign_id,p_actor_user_id,p_policy_mode,'MRV2-ENGAGEMENT-POLICY-1.0.0',p_at) RETURNING id INTO v_id;
 RETURN QUERY SELECT v_id,p_policy_mode,false;
END $$;

--
-- Name: marketroute_record_manual_engagement_v1(uuid, text, uuid, uuid, uuid, text, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_record_manual_engagement_v1(p_opportunity_id uuid, p_path_fingerprint text, p_message_id uuid, p_actor_user_id uuid, p_request_id uuid, p_note text DEFAULT NULL::text, p_at timestamp with time zone DEFAULT now()) RETURNS TABLE(manual_action_id uuid, workflow_event_id uuid, prior_workflow_state text, resulting_workflow_state text, channel_kind text, deduplicated boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
DECLARE
  v_existing public.engagement_manual_actions%ROWTYPE;
  v_opp public.opportunities%ROWTYPE;
  v_strategy public.engagement_strategies%ROWTYPE;
  v_message public.engagement_messages%ROWTYPE;
  v_review public.engagement_ai_reviews%ROWTYPE;
  v_approval public.engagement_message_approvals%ROWTYPE;
  v_context jsonb;
  v_envelope jsonb;
  v_envelope_fp text;
  v_action_id uuid;
  v_event_id uuid;
  v_note text:=NULLIF(left(btrim(COALESCE(p_note,'')),1000),'');
  v_prior text;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF p_request_id IS NULL OR p_actor_user_id IS NULL OR p_opportunity_id IS NULL OR p_message_id IS NULL THEN
    RAISE EXCEPTION 'MARKETROUTE_MANUAL_ENGAGEMENT_IDENTITY_REQUIRED';
  END IF;
  IF p_path_fingerprint IS NULL OR p_path_fingerprint !~ '^[a-f0-9]{64}$' THEN
    RAISE EXCEPTION 'MARKETROUTE_MANUAL_ENGAGEMENT_PATH_INVALID';
  END IF;

  SELECT * INTO v_existing FROM public.engagement_manual_actions WHERE request_id=p_request_id;
  IF FOUND THEN
    IF v_existing.opportunity_id IS DISTINCT FROM p_opportunity_id
      OR v_existing.path_fingerprint IS DISTINCT FROM p_path_fingerprint
      OR v_existing.message_id IS DISTINCT FROM p_message_id
      OR v_existing.actor_user_id IS DISTINCT FROM p_actor_user_id
      OR v_existing.note IS DISTINCT FROM v_note THEN
      RAISE EXCEPTION 'MARKETROUTE_MANUAL_ENGAGEMENT_IDEMPOTENCY_COLLISION';
    END IF;
    RETURN QUERY SELECT v_existing.id,NULL::uuid,'REVIEWABLE'::text,'ENGAGED'::text,v_existing.channel_kind,true;
    RETURN;
  END IF;

  IF p_at IS NULL OR abs(extract(epoch FROM(now()-p_at)))>300 THEN
    RAISE EXCEPTION 'MARKETROUTE_MANUAL_ENGAGEMENT_TIME_NOT_CURRENT';
  END IF;

  SELECT * INTO v_opp FROM public.opportunities WHERE id=p_opportunity_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_MANUAL_ENGAGEMENT_OPPORTUNITY_NOT_FOUND'; END IF;
  IF v_opp.workflow_state NOT IN('REVIEWABLE','APPROVED') THEN
    RAISE EXCEPTION 'MARKETROUTE_MANUAL_ENGAGEMENT_REQUIRES_READY_OPPORTUNITY';
  END IF;
  v_prior:=v_opp.workflow_state;
  IF NOT EXISTS(
    SELECT 1 FROM public.organisation_memberships m
    WHERE m.organisation_id=v_opp.organisation_id
      AND m.user_id=p_actor_user_id
      AND m.status='ACTIVE'
      AND m.role IN('OWNER','ADMIN','MEMBER')
  ) THEN RAISE EXCEPTION 'MARKETROUTE_MANUAL_ENGAGEMENT_ACTOR_NOT_AUTHORISED'; END IF;

  -- The context function revalidates ACTIVE organisation/campaign, system-ready
  -- workflow, current R4/R5/R6, executable authority and an R6-authorised path.
  v_context:=public.marketroute_engagement_generation_context_v1(p_opportunity_id,p_path_fingerprint,p_at);

  SELECT * INTO v_strategy
  FROM public.engagement_strategies s
  WHERE s.opportunity_id=p_opportunity_id AND s.path_fingerprint=p_path_fingerprint
  ORDER BY s.created_at DESC,s.id DESC LIMIT 1;
  IF NOT FOUND OR public.marketroute_engagement_strategy_current_v1(v_strategy.id,p_at) IS NOT TRUE THEN
    RAISE EXCEPTION 'MARKETROUTE_MANUAL_ENGAGEMENT_CURRENT_STRATEGY_REQUIRED';
  END IF;

  SELECT * INTO v_message FROM public.engagement_messages WHERE id=p_message_id AND strategy_id=v_strategy.id;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_MANUAL_ENGAGEMENT_MESSAGE_SCOPE_MISMATCH'; END IF;
  IF EXISTS(SELECT 1 FROM public.engagement_messages newer WHERE newer.strategy_id=v_strategy.id AND newer.rewrite_ordinal>v_message.rewrite_ordinal) THEN
    RAISE EXCEPTION 'MARKETROUTE_MANUAL_ENGAGEMENT_MESSAGE_NOT_CURRENT';
  END IF;

  SELECT * INTO v_review FROM public.engagement_ai_reviews WHERE message_id=v_message.id ORDER BY created_at DESC,id DESC LIMIT 1;
  IF NOT FOUND OR v_review.verdict<>'PASS' THEN
    RAISE EXCEPTION 'MARKETROUTE_MANUAL_ENGAGEMENT_PASS_REVIEW_REQUIRED';
  END IF;
  SELECT * INTO v_approval FROM public.engagement_message_approvals WHERE message_id=v_message.id ORDER BY created_at DESC,id DESC LIMIT 1;
  IF NOT FOUND OR v_approval.approval_mode<>'HUMAN' OR v_approval.decision<>'APPROVE' THEN
    RAISE EXCEPTION 'MARKETROUTE_MANUAL_ENGAGEMENT_HUMAN_APPROVAL_REQUIRED';
  END IF;

  v_envelope:=public.marketroute_authority_envelope_v1(v_opp.organisation_id,v_opp.campaign_id,v_opp.company_id,p_at);
  v_envelope_fp:=public.marketroute_engagement_authority_snapshot_fingerprint_v1(v_envelope);
  IF v_envelope_fp IS DISTINCT FROM v_strategy.authority_envelope_fingerprint
    OR v_envelope_fp IS DISTINCT FROM v_approval.authority_envelope_fingerprint THEN
    RAISE EXCEPTION 'MARKETROUTE_MANUAL_ENGAGEMENT_AUTHORITY_CHANGED';
  END IF;

  INSERT INTO public.engagement_manual_actions(
    request_id,opportunity_id,organisation_id,campaign_id,company_id,strategy_id,message_id,actor_user_id,
    path_fingerprint,channel_kind,access_point_id,person_id,authority_envelope_fingerprint,note,occurred_at
  ) VALUES(
    p_request_id,v_opp.id,v_opp.organisation_id,v_opp.campaign_id,v_opp.company_id,v_strategy.id,v_message.id,p_actor_user_id,
    p_path_fingerprint,v_strategy.channel_kind,v_strategy.access_point_id,v_strategy.person_id,v_envelope_fp,v_note,p_at
  ) RETURNING id INTO v_action_id;

  UPDATE public.opportunities SET workflow_state='ENGAGED',updated_at=p_at WHERE id=v_opp.id;
  INSERT INTO public.opportunity_workflow_events(
    opportunity_id,organisation_id,event_type,prior_workflow_state,resulting_workflow_state,
    actor_user_id,request_id,reason_code,authority_envelope_json,authority_envelope_fingerprint,occurred_at
  ) VALUES(
    v_opp.id,v_opp.organisation_id,'ENGAGEMENT',v_prior,'ENGAGED',p_actor_user_id,p_request_id,
    'FIRST_MANUAL_ENGAGEMENT_RECORDED',v_envelope,v_envelope_fp,p_at
  ) RETURNING id INTO v_event_id;

  RETURN QUERY SELECT v_action_id,v_event_id,v_prior,'ENGAGED'::text,v_strategy.channel_kind,false;
END $_$;

--
-- Name: marketroute_record_opportunity_review_v1(uuid, uuid, text, text, uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_record_opportunity_review_v1(p_opportunity_id uuid, p_reviewer_user_id uuid, p_decision text, p_note text, p_request_id uuid, p_reviewed_at timestamp with time zone DEFAULT now()) RETURNS TABLE(review_id uuid, workflow_event_id uuid, prior_workflow_state text, resulting_workflow_state text, authority_envelope_fingerprint text, executable_now boolean, deduplicated boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_opp public.opportunities%ROWTYPE; v_existing public.opportunity_human_reviews%ROWTYPE; v_review_id uuid; v_event_id uuid; v_result text; v_envelope jsonb; v_envelope_fp text; v_note text:=NULLIF(btrim(p_note),''); v_reason text;
BEGIN
 IF p_request_id IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_REVIEW_REQUEST_ID_REQUIRED'; END IF; IF p_reviewer_user_id IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_REVIEWER_REQUIRED'; END IF; IF p_decision NOT IN('APPROVE','REJECT','RETURN_TO_RESEARCH') THEN RAISE EXCEPTION 'MARKETROUTE_REVIEW_DECISION_INVALID'; END IF;
 SELECT * INTO v_opp FROM public.opportunities WHERE id=p_opportunity_id FOR UPDATE; IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_OPPORTUNITY_NOT_FOUND'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.organisation_memberships m WHERE m.organisation_id=v_opp.organisation_id AND m.user_id=p_reviewer_user_id AND m.status='ACTIVE' AND m.role IN('OWNER','ADMIN','MEMBER')) THEN RAISE EXCEPTION 'MARKETROUTE_REVIEWER_NOT_AUTHORISED'; END IF;
 SELECT * INTO v_existing FROM public.opportunity_human_reviews WHERE opportunity_id=p_opportunity_id AND review_request_id=p_request_id LIMIT 1;
 IF FOUND THEN
  IF v_existing.reviewer_user_id IS DISTINCT FROM p_reviewer_user_id OR v_existing.decision IS DISTINCT FROM p_decision OR COALESCE(v_existing.note,'') IS DISTINCT FROM COALESCE(v_note,'') THEN RAISE EXCEPTION 'MARKETROUTE_REVIEW_IDEMPOTENCY_COLLISION'; END IF;
  SELECT e.id INTO v_event_id FROM public.opportunity_workflow_events e WHERE e.opportunity_id=p_opportunity_id AND e.request_id=p_request_id LIMIT 1;
  RETURN QUERY SELECT v_existing.id,v_event_id,v_existing.prior_workflow_state,v_existing.resulting_workflow_state,v_existing.authority_envelope_fingerprint,public.marketroute_opportunity_executable_now_v1(p_opportunity_id,now()),true; RETURN;
 END IF;
 IF EXISTS(SELECT 1 FROM public.engagement_delivery_jobs j JOIN public.engagement_queue_items q ON q.id=j.queue_item_id WHERE q.opportunity_id=p_opportunity_id AND j.status='RUNNING') THEN RAISE EXCEPTION 'MARKETROUTE_REVIEW_BLOCKED_DURING_ENGAGEMENT_DELIVERY'; END IF;
 IF p_reviewed_at IS NULL OR abs(extract(epoch FROM(now()-p_reviewed_at)))>300 THEN RAISE EXCEPTION 'MARKETROUTE_REVIEW_TIME_NOT_CURRENT'; END IF;
 v_envelope:=public.marketroute_authority_envelope_v1(v_opp.organisation_id,v_opp.campaign_id,v_opp.company_id,p_reviewed_at); v_envelope_fp:=public.marketroute_authority_envelope_fingerprint_v1(v_envelope);
 IF p_decision='APPROVE' THEN IF v_opp.workflow_state<>'REVIEWABLE' THEN RAISE EXCEPTION 'MARKETROUTE_APPROVAL_REQUIRES_REVIEWABLE'; END IF; IF COALESCE((v_envelope->>'authorityReady')::boolean,false) IS NOT TRUE THEN RAISE EXCEPTION 'MARKETROUTE_APPROVAL_REQUIRES_CURRENT_AUTHORITY'; END IF; v_result:='APPROVED';v_reason:='FOUNDER_APPROVED_CURRENT_AUTHORITY';
 ELSIF p_decision='REJECT' THEN IF v_opp.workflow_state NOT IN('REVIEWABLE','APPROVED') THEN RAISE EXCEPTION 'MARKETROUTE_REJECTION_STATE_INVALID'; END IF;v_result:='REJECTED';v_reason:='FOUNDER_REJECTED';
 ELSE IF v_opp.workflow_state NOT IN('REVIEWABLE','APPROVED','REJECTED') THEN RAISE EXCEPTION 'MARKETROUTE_RETURN_TO_RESEARCH_STATE_INVALID'; END IF;v_result:='RESEARCHING';v_reason:='FOUNDER_RETURNED_TO_RESEARCH'; END IF;
 UPDATE public.opportunities SET workflow_state=v_result WHERE id=v_opp.id;
 INSERT INTO public.opportunity_human_reviews(opportunity_id,organisation_id,reviewer_user_id,decision,note,review_request_id,prior_workflow_state,resulting_workflow_state,authority_envelope_json,authority_envelope_fingerprint,created_at)
 VALUES(v_opp.id,v_opp.organisation_id,p_reviewer_user_id,p_decision,v_note,p_request_id,v_opp.workflow_state,v_result,v_envelope,v_envelope_fp,p_reviewed_at) RETURNING id INTO v_review_id;
 INSERT INTO public.opportunity_workflow_events(opportunity_id,organisation_id,event_type,prior_workflow_state,resulting_workflow_state,actor_user_id,request_id,reason_code,authority_envelope_json,authority_envelope_fingerprint,occurred_at)
 VALUES(v_opp.id,v_opp.organisation_id,'HUMAN_REVIEW',v_opp.workflow_state,v_result,p_reviewer_user_id,p_request_id,v_reason,v_envelope,v_envelope_fp,p_reviewed_at) RETURNING id INTO v_event_id;
 RETURN QUERY SELECT v_review_id,v_event_id,v_opp.workflow_state,v_result,v_envelope_fp,public.marketroute_opportunity_executable_now_v1(p_opportunity_id,p_reviewed_at),false;
END $$;

--
-- Name: marketroute_record_runtime_event_v1(uuid, text, text, integer, text, jsonb, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_record_runtime_event_v1(p_correlation_id uuid, p_runtime_kind text, p_event_type text, p_duration_ms integer DEFAULT NULL::integer, p_error_code text DEFAULT NULL::text, p_metadata_json jsonb DEFAULT '{}'::jsonb, p_at timestamp with time zone DEFAULT now()) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_id uuid;BEGIN PERFORM public.marketroute_require_service_role();IF p_correlation_id IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_RUNTIME_CORRELATION_REQUIRED';END IF;IF p_runtime_kind NOT IN ('BOOTSTRAP','GROWTH','RESEARCH','DELIVERY','PREFLIGHT','SMOKE') THEN RAISE EXCEPTION 'MARKETROUTE_RUNTIME_KIND_INVALID';END IF;IF p_event_type NOT IN ('STARTED','SUCCEEDED','FAILED','DISABLED') THEN RAISE EXCEPTION 'MARKETROUTE_RUNTIME_EVENT_INVALID';END IF;IF p_duration_ms IS NOT NULL AND p_duration_ms<0 THEN RAISE EXCEPTION 'MARKETROUTE_RUNTIME_DURATION_INVALID';END IF;IF jsonb_typeof(COALESCE(p_metadata_json,'{}'::jsonb))<>'object' THEN RAISE EXCEPTION 'MARKETROUTE_RUNTIME_METADATA_INVALID';END IF;INSERT INTO public.production_runtime_events(correlation_id,runtime_kind,event_type,duration_ms,error_code,metadata_json,occurred_at) VALUES(p_correlation_id,p_runtime_kind,p_event_type,p_duration_ms,left(nullif(btrim(COALESCE(p_error_code,'')),''),500),COALESCE(p_metadata_json,'{}'::jsonb),COALESCE(p_at,now())) RETURNING id INTO v_id;RETURN v_id;END;$$;

--
-- Name: marketroute_record_seller_genome_source_v1(uuid, uuid, text, jsonb, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_record_seller_genome_source_v1(p_organisation_id uuid, p_seller_business_id uuid, p_material_kind text, p_content_json jsonb, p_created_by_user_id uuid DEFAULT NULL::uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp', 'extensions'
    AS $$
DECLARE
  v_seller public.seller_businesses%ROWTYPE;
  v_fingerprint text;
  v_existing public.seller_genome_source_materials%ROWTYPE;
  v_id uuid;
BEGIN
  IF p_material_kind NOT IN ('USER_DECLARED','WEBSITE_ANALYSIS','IMPORT','COMPOSITE') THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_SOURCE_KIND_INVALID'; END IF;
  IF jsonb_typeof(p_content_json) NOT IN ('object','array','string') THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_SOURCE_CONTENT_INVALID'; END IF;
  SELECT * INTO v_seller FROM public.seller_businesses WHERE id = p_seller_business_id AND organisation_id = p_organisation_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_SOURCE_SCOPE_INVALID'; END IF;
  IF p_created_by_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.organisation_memberships m
    WHERE m.organisation_id = p_organisation_id AND m.user_id = p_created_by_user_id AND m.status = 'ACTIVE'
  ) THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_SOURCE_CREATOR_NOT_MEMBER'; END IF;
  v_fingerprint := encode(extensions.digest(concat_ws('|',
    'MRV2-SELLER-SOURCE-1.0.0', p_organisation_id::text, p_seller_business_id::text, p_material_kind, p_content_json::text
  ), 'sha256'), 'hex');
  SELECT * INTO v_existing FROM public.seller_genome_source_materials WHERE material_fingerprint = v_fingerprint;
  IF FOUND THEN
    IF v_existing.organisation_id <> p_organisation_id OR v_existing.seller_business_id <> p_seller_business_id OR v_existing.material_kind <> p_material_kind OR v_existing.content_json <> p_content_json THEN
      RAISE EXCEPTION 'MARKETROUTE_SELLER_SOURCE_FINGERPRINT_COLLISION';
    END IF;
    RETURN jsonb_build_object('sourceMaterialId', v_existing.id, 'materialFingerprint', v_fingerprint, 'deduplicated', true);
  END IF;
  INSERT INTO public.seller_genome_source_materials(organisation_id, seller_business_id, material_kind, content_json, material_fingerprint, created_by_user_id)
  VALUES (p_organisation_id, p_seller_business_id, p_material_kind, p_content_json, v_fingerprint, p_created_by_user_id)
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('sourceMaterialId', v_id, 'materialFingerprint', v_fingerprint, 'deduplicated', false);
END;
$$;

--
-- Name: marketroute_recover_abandoned_engagement_delivery_v1(timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_recover_abandoned_engagement_delivery_v1(p_at timestamp with time zone DEFAULT now()) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_count int:=0; r record;
BEGIN
 PERFORM public.marketroute_require_service_role(); IF p_at IS NULL OR abs(extract(epoch FROM(now()-p_at)))>300 THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_RECOVERY_TIME_NOT_CURRENT'; END IF;
 FOR r IN SELECT j.* FROM public.engagement_delivery_jobs j WHERE j.status='RUNNING' AND j.claimed_at < p_at-interval '10 minutes' FOR UPDATE SKIP LOCKED LOOP
  UPDATE public.engagement_delivery_jobs SET status='RECONCILIATION_REQUIRED',finished_at=p_at,last_error_code='ABANDONED_IN_FLIGHT_DELIVERY_STATUS_UNKNOWN' WHERE id=r.id;
  INSERT INTO public.engagement_delivery_events(queue_item_id,job_id,event_type,worker_id,send_gate_fingerprint,metadata_json,occurred_at) VALUES(r.queue_item_id,r.id,'RECONCILIATION_REQUIRED',r.claimed_by,r.send_gate_fingerprint,jsonb_build_object('reason','ABANDONED_RUNNING_DELIVERY_MAY_HAVE_SENT'),p_at); v_count:=v_count+1;
 END LOOP; RETURN v_count;
END $$;

--
-- Name: marketroute_recover_abandoned_research_work_v1(uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_recover_abandoned_research_work_v1(p_scheduler_run_id uuid, p_at timestamp with time zone DEFAULT now()) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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
$$;

--
-- Name: marketroute_register_company_in_genesis_bank_v1(uuid, text[], text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_register_company_in_genesis_bank_v1(p_company_id uuid, p_industry_keys text[], p_discovery_reason text DEFAULT NULL::text) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_inserted integer:=0;
BEGIN
  PERFORM public.marketroute_require_service_role();

  IF NOT EXISTS (
    SELECT 1 FROM public.companies c
    WHERE c.id=p_company_id AND c.lifecycle_state='ACTIVE'
  ) THEN
    RAISE EXCEPTION 'MARKETROUTE_GENESIS_BANK_COMPANY_INVALID';
  END IF;

  INSERT INTO public.genesis_growth_company_memberships(industry_key,company_id,discovery_reason)
  SELECT DISTINCT i.industry_key,p_company_id,left(nullif(btrim(COALESCE(p_discovery_reason,'')),''),500)
  FROM public.genesis_growth_industries i
  WHERE i.enabled=true
    AND i.industry_key=ANY(COALESCE(p_industry_keys,'{}'::text[]))
  ON CONFLICT(industry_key,company_id) DO NOTHING;

  GET DIAGNOSTICS v_inserted=ROW_COUNT;

  IF EXISTS(SELECT 1 FROM public.genesis_growth_company_memberships m WHERE m.company_id=p_company_id) THEN
    -- Identity-known state only. Customer-private campaign evidence is never
    -- copied into global Genesis completion fields by this function.
    INSERT INTO public.genesis_growth_company_progress(company_id)
    VALUES(p_company_id)
    ON CONFLICT(company_id) DO NOTHING;
  END IF;

  RETURN v_inserted;
END;
$$;

--
-- Name: marketroute_reject_mutation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_reject_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'MARKETROUTE_APPEND_ONLY_RELATION:%', TG_TABLE_NAME;
END;
$$;

--
-- Name: marketroute_require_service_role(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_require_service_role() RETURNS void
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
BEGIN
 -- AWS V0: authorization is enforced by the server-side Data API/IAM boundary.
 RETURN;
END;
$$;

--
-- Name: marketroute_research_budget_snapshot_v1(uuid, uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_research_budget_snapshot_v1(p_organisation_id uuid, p_campaign_id uuid, p_at timestamp with time zone DEFAULT now()) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
 WITH day_bounds AS (SELECT date_trunc('day',p_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AS d0),
 committed AS (SELECT COALESCE(sum(e.amount_usd),0) v FROM public.research_budget_events e,day_bounds d WHERE e.organisation_id=p_organisation_id AND e.campaign_id=p_campaign_id AND e.event_type='COMMIT' AND e.occurred_at>=d.d0 AND e.occurred_at<d.d0+interval '1 day'),
 active_reserved AS (SELECT COALESCE(sum(r.amount_usd),0) v FROM public.research_budget_events r,day_bounds d WHERE r.organisation_id=p_organisation_id AND r.campaign_id=p_campaign_id AND r.event_type='RESERVE' AND r.occurred_at>=d.d0 AND r.occurred_at<d.d0+interval '1 day' AND NOT EXISTS(SELECT 1 FROM public.research_budget_events x WHERE x.work_unit_id=r.work_unit_id AND x.attempt_number=r.attempt_number AND x.event_type IN('COMMIT','RELEASE'))),
 active_jobs AS (SELECT count(*)::int v FROM public.research_work_units w JOIN public.background_jobs j ON j.id=w.background_job_id WHERE w.organisation_id=p_organisation_id AND w.campaign_id=p_campaign_id AND j.status IN('RESERVED','RUNNING'))
 SELECT jsonb_build_object('spentTodayUsd',(SELECT v FROM committed),'reservedTodayUsd',(SELECT v FROM active_reserved),'activeJobs',(SELECT v FROM active_jobs));
$$;

--
-- Name: marketroute_research_capacity_snapshot_v1(uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_research_capacity_snapshot_v1(p_organisation_id uuid, p_at timestamp with time zone DEFAULT now()) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_ent public.organisation_commercial_entitlements%ROWTYPE;v_plan public.marketroute_plan_catalog%ROWTYPE;v_used integer:=0;v_reserved integer:=0;
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT * INTO v_ent FROM public.organisation_commercial_entitlements e
  WHERE e.organisation_id=p_organisation_id AND e.status='ACTIVE'
    AND (e.current_period_start IS NULL OR e.current_period_start<=p_at)
    AND (e.current_period_end IS NULL OR e.current_period_end>p_at) LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('planCode',NULL,'limitUnits',0,'usedUnits',0,'reservedUnits',0,'remainingUnits',0,'available',false,'periodStart',NULL,'periodEnd',NULL); END IF;
  SELECT * INTO v_plan FROM public.marketroute_plan_catalog WHERE plan_code=v_ent.plan_code;
  IF v_plan.research_capacity_units IS NULL THEN RETURN jsonb_build_object('planCode',v_ent.plan_code,'limitUnits',NULL,'usedUnits',0,'reservedUnits',0,'remainingUnits',NULL,'available',true,'periodStart',v_ent.current_period_start,'periodEnd',v_ent.current_period_end); END IF;
  SELECT count(DISTINCT b.work_unit_id)::int INTO v_used FROM public.research_budget_events b
  WHERE b.organisation_id=p_organisation_id AND b.event_type='COMMIT'
    AND (v_ent.current_period_start IS NULL OR b.occurred_at>=v_ent.current_period_start)
    AND (v_ent.current_period_end IS NULL OR b.occurred_at<v_ent.current_period_end);
  SELECT count(DISTINCT r.work_unit_id)::int INTO v_reserved FROM public.research_budget_events r
  WHERE r.organisation_id=p_organisation_id AND r.event_type='RESERVE'
    AND (v_ent.current_period_start IS NULL OR r.occurred_at>=v_ent.current_period_start)
    AND (v_ent.current_period_end IS NULL OR r.occurred_at<v_ent.current_period_end)
    AND NOT EXISTS(SELECT 1 FROM public.research_budget_events x WHERE x.work_unit_id=r.work_unit_id AND x.attempt_number=r.attempt_number AND x.event_type IN('COMMIT','RELEASE'));
  RETURN jsonb_build_object('planCode',v_ent.plan_code,'limitUnits',v_plan.research_capacity_units,'usedUnits',v_used,'reservedUnits',v_reserved,'remainingUnits',greatest(0,v_plan.research_capacity_units-v_used-v_reserved),'available',(v_used+v_reserved)<v_plan.research_capacity_units,'periodStart',v_ent.current_period_start,'periodEnd',v_ent.current_period_end);
END;$$;

--
-- Name: marketroute_research_gap_context_v1(uuid, uuid, uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_research_gap_context_v1(p_organisation_id uuid, p_campaign_id uuid, p_company_id uuid, p_at timestamp with time zone DEFAULT now()) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_env jsonb; v_env_fp text; v_gap_fp text; v_state text; v_candidates jsonb:='[]'::jsonb; v_policy jsonb; v_budget jsonb; v_r4 public.commercial_reality_r4_records%ROWTYPE; v_r5 public.route_authority_r5_records%ROWTYPE; v_r6 public.contact_authority_r6_records%ROWTYPE; v_gap jsonb; v_item jsonb; v_i int:=0; v_earliest_layer text; v_earliest timestamptz; v_t timestamptz;
BEGIN
 v_env:=public.marketroute_authority_envelope_v1(p_organisation_id,p_campaign_id,p_company_id,p_at); v_env_fp:=public.marketroute_authority_envelope_fingerprint_v1(v_env); v_state:=v_env->>'lifecycleState'; v_policy:=public.marketroute_research_policy_v1(p_organisation_id,p_campaign_id); v_budget:=public.marketroute_research_budget_snapshot_v1(p_organisation_id,p_campaign_id,p_at);
 IF COALESCE((v_policy->>'enabled')::boolean,true)=false THEN RETURN jsonb_build_object('organisationId',p_organisation_id,'campaignId',p_campaign_id,'companyId',p_company_id,'referenceTime',p_at,'lifecycleState',v_state,'authorityEnvelopeFingerprint',v_env_fp,'gapSetFingerprint',encode(extensions.digest('MRV2-RESEARCH-GAP-SET-1.0.0|'||('[]'::jsonb)::text,'sha256'),'hex'),'candidates','[]'::jsonb,'policy',v_policy,'budget',v_budget); END IF;
 IF v_state='R4_REVALIDATION_REQUIRED' THEN
   v_candidates:=v_candidates||jsonb_build_array(jsonb_build_object('gapKey','r4:revalidate','layer','R4','tier','CURRENTNESS_REPAIR','action','REVALIDATE_R4','subjectType','COMPANY','subjectId',p_company_id::text,'claimKey',NULL,'reasonCode','CURRENT_R4_REQUIRED','queryHints','[]'::jsonb,'metadata','{}'::jsonb));
 ELSIF v_state='COMMERCIAL_RESEARCH_REQUIRED' THEN
   SELECT r.* INTO v_r4 FROM public.commercial_reality_r4_records r WHERE r.organisation_id=p_organisation_id AND r.campaign_id=p_campaign_id AND r.company_id=p_company_id AND public.marketroute_r4_authority_current_v1(r.authority_record_id,p_at) ORDER BY r.created_at DESC,r.id DESC LIMIT 1;
   FOR v_item IN SELECT value FROM jsonb_array_elements(COALESCE(v_r4.boundaries_json,'[]'::jsonb)) x(value) WHERE value->>'state' IN('UNRESOLVED','CONTRADICTED','STALE') ORDER BY value->>'boundaryKey' LOOP
     v_candidates:=v_candidates||jsonb_build_array(jsonb_build_object('gapKey','r4:'||(v_item->>'boundaryKey'),'layer','R4','tier','DECISION_BLOCKER','action','ACQUIRE_CLAIM_EVIDENCE','subjectType','COMPANY','subjectId',p_company_id::text,'claimKey',v_item->>'claimKey','reasonCode',v_item->>'reasonCode','queryHints',CASE WHEN v_item->>'claimKey' IS NULL THEN '[]'::jsonb ELSE jsonb_build_array(v_item->>'claimKey') END,'metadata',jsonb_build_object('boundaryKey',v_item->>'boundaryKey','boundaryState',v_item->>'state')));
   END LOOP;
 ELSIF v_state='R5_REVALIDATION_REQUIRED' THEN
   v_candidates:=v_candidates||jsonb_build_array(jsonb_build_object('gapKey','r5:revalidate','layer','R5','tier','CURRENTNESS_REPAIR','action','REVALIDATE_R5','subjectType','COMPANY','subjectId',p_company_id::text,'claimKey',NULL,'reasonCode','CURRENT_R5_REQUIRED','queryHints','[]'::jsonb,'metadata','{}'::jsonb));
 ELSIF v_state='ROUTE_RESEARCH_REQUIRED' THEN
   v_candidates:=v_candidates||jsonb_build_array(jsonb_build_object('gapKey','r5:discover-route','layer','R5','tier','DECISION_BLOCKER','action','DISCOVER_ROUTE_STRUCTURE','subjectType','COMPANY','subjectId',p_company_id::text,'claimKey',NULL,'reasonCode','STRUCTURAL_ROUTE_EVIDENCE_REQUIRED','queryHints',jsonb_build_array('contact','team','department','leadership','email','contact form'),'metadata','{}'::jsonb));
 ELSIF v_state='R6_REVALIDATION_REQUIRED' THEN
   v_candidates:=v_candidates||jsonb_build_array(jsonb_build_object('gapKey','r6:revalidate','layer','R6','tier','CURRENTNESS_REPAIR','action','REVALIDATE_R6','subjectType','COMPANY','subjectId',p_company_id::text,'claimKey',NULL,'reasonCode','CURRENT_R6_REQUIRED','queryHints','[]'::jsonb,'metadata','{}'::jsonb));
 ELSIF v_state='CONTACT_RESEARCH_REQUIRED' THEN
   SELECT r.* INTO v_r6 FROM public.contact_authority_r6_records r WHERE r.organisation_id=p_organisation_id AND r.campaign_id=p_campaign_id AND r.company_id=p_company_id AND public.marketroute_r6_authority_current_v1(r.authority_record_id,p_at) ORDER BY r.created_at DESC,r.id DESC LIMIT 1;
   FOR v_item IN SELECT value FROM jsonb_array_elements(COALESCE(v_r6.bindings_json,'[]'::jsonb)) x(value) WHERE value->>'authorityState'='CONTACT_TRUTH_REQUIRED' ORDER BY value->>'pathFingerprint' LOOP
     v_candidates:=v_candidates||jsonb_build_array(jsonb_build_object('gapKey','r6:'||(v_item->>'pathFingerprint'),'layer','R6','tier','DECISION_BLOCKER','action','RESEARCH_CONTACT_BINDING','subjectType','CHANNEL','subjectId',v_item->>'terminalAccessPointId','claimKey',NULL,'reasonCode',v_item->>'reasonCode','queryHints',jsonb_build_array('identity','current employment','current role','channel ownership'),'metadata',jsonb_build_object('pathFingerprint',v_item->>'pathFingerprint','personId',v_item->>'personId','employerCompanyId',v_item->>'employerCompanyId')));
   END LOOP;
 ELSIF v_state='AUTHORITY_READY' AND COALESCE((v_policy->>'refreshHorizonHours')::int,0)>0 THEN
   FOREACH v_earliest_layer IN ARRAY ARRAY['R4','R5','R6'] LOOP
     v_t:=CASE v_earliest_layer WHEN 'R4' THEN NULLIF(v_env->'r4'->>'validUntil','')::timestamptz WHEN 'R5' THEN NULLIF(v_env->'r5'->>'validUntil','')::timestamptz ELSE NULLIF(v_env->'r6'->>'validUntil','')::timestamptz END;
     IF v_t IS NOT NULL AND v_t<=p_at+make_interval(hours=>((v_policy->>'refreshHorizonHours')::int)) AND (v_earliest IS NULL OR v_t<v_earliest) THEN v_earliest:=v_t; END IF;
   END LOOP;
   IF v_earliest IS NOT NULL THEN
     IF NULLIF(v_env->'r4'->>'validUntil','')::timestamptz=v_earliest THEN v_earliest_layer:='R4';
     ELSIF NULLIF(v_env->'r5'->>'validUntil','')::timestamptz=v_earliest THEN v_earliest_layer:='R5'; ELSE v_earliest_layer:='R6'; END IF;
     v_candidates:=v_candidates||jsonb_build_array(jsonb_build_object('gapKey',lower(v_earliest_layer)||':expiring','layer',v_earliest_layer,'tier','EXPIRING_SOON','action','REVALIDATE_'||v_earliest_layer,'subjectType','COMPANY','subjectId',p_company_id::text,'claimKey',NULL,'reasonCode','AUTHORITY_EXPIRING_SOON','queryHints','[]'::jsonb,'metadata',jsonb_build_object('validUntil',v_earliest)));
   END IF;
 END IF;
 SELECT COALESCE(jsonb_agg(x.value ORDER BY x.ord),'[]'::jsonb) INTO v_candidates
 FROM jsonb_array_elements(v_candidates) WITH ORDINALITY x(value,ord)
 WHERE NOT EXISTS (
   SELECT 1 FROM public.research_work_units w JOIN public.background_jobs j ON j.id=w.background_job_id
   WHERE w.organisation_id=p_organisation_id AND w.campaign_id=p_campaign_id AND w.company_id=p_company_id
     AND w.gap_key=x.value->>'gapKey' AND w.action=x.value->>'action'
     AND j.status IN('PENDING','DEFERRED','RESERVED','RUNNING','SUCCEEDED','FAILED')
     AND w.created_at > p_at - interval '6 hours'
 );
 v_gap_fp:=encode(extensions.digest('MRV2-RESEARCH-GAP-SET-1.0.0|'||v_candidates::text,'sha256'),'hex');
 RETURN jsonb_build_object('organisationId',p_organisation_id,'campaignId',p_campaign_id,'companyId',p_company_id,'referenceTime',p_at,'lifecycleState',v_state,'authorityEnvelopeFingerprint',v_env_fp,'gapSetFingerprint',v_gap_fp,'candidates',v_candidates,'policy',v_policy-'enabled'-'policyVersion','budget',v_budget);
END $$;

--
-- Name: marketroute_research_planning_targets_v1(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_research_planning_targets_v1(p_limit integer DEFAULT 100) RETURNS TABLE(organisation_id uuid, campaign_id uuid, company_id uuid)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
 SELECT DISTINCT s.organisation_id,s.campaign_id,s.company_id
 FROM public.organisation_company_scopes s
 JOIN public.campaigns c ON c.id=s.campaign_id AND c.organisation_id=s.organisation_id
 JOIN public.research_budget_policies p ON p.organisation_id=s.organisation_id AND p.campaign_id=s.campaign_id AND p.enabled=true
 LEFT JOIN public.anonymous_discovery_runs a ON a.organisation_id=s.organisation_id
 WHERE s.scope_kind='CAMPAIGN' AND s.campaign_id IS NOT NULL AND c.workflow_state='ACTIVE'
   AND (a.id IS NULL OR (public.marketroute_paid_entitlement_active_v1(s.organisation_id,now()) AND COALESCE((public.marketroute_research_capacity_snapshot_v1(s.organisation_id,now())->>'available')::boolean,false)) OR (a.status IN('ACTIVE','CLAIMED') AND a.research_expires_at>now()))
 ORDER BY s.organisation_id,s.campaign_id,s.company_id
 LIMIT greatest(0,least(COALESCE(p_limit,100),1000));
$$;

--
-- Name: marketroute_research_policy_v1(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_research_policy_v1(p_organisation_id uuid, p_campaign_id uuid) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
 SELECT COALESCE((SELECT jsonb_build_object('dailyBudgetUsd',daily_budget_usd,'maxJobCostUsd',max_job_cost_usd,'maxConcurrentJobs',max_concurrent_jobs,'maxWorkUnitsPerPlan',max_work_units_per_plan,'refreshHorizonHours',refresh_horizon_hours,'enabled',enabled,'policyVersion',policy_version) FROM public.research_budget_policies WHERE organisation_id=p_organisation_id AND campaign_id=p_campaign_id),
 jsonb_build_object('dailyBudgetUsd',5.00000000,'maxJobCostUsd',0.50000000,'maxConcurrentJobs',2,'maxWorkUnitsPerPlan',4,'refreshHorizonHours',2,'enabled',true,'policyVersion','MRV2-RESEARCH-BUDGET-1.0.0'));
$$;

--
-- Name: marketroute_research_queue_diagnostics_v1(timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_research_queue_diagnostics_v1(p_at timestamp with time zone DEFAULT now()) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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
$$;

--
-- Name: marketroute_select_campaign_seller_context_v1(uuid, uuid, uuid, text, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_select_campaign_seller_context_v1(p_organisation_id uuid, p_campaign_id uuid, p_genome_snapshot_id uuid, p_objective_key text, p_request_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp', 'extensions'
    AS $_$
DECLARE
  v_campaign public.campaigns%ROWTYPE;
  v_genome public.seller_commercial_genome_snapshots%ROWTYPE;
  v_objective_key text := lower(btrim(p_objective_key));
  v_input_fingerprint text;
  v_semantic_context_fingerprint text;
  v_existing public.campaign_seller_context_selections%ROWTYPE;
  v_id uuid;
BEGIN
  SELECT * INTO v_campaign FROM public.campaigns WHERE id = p_campaign_id AND organisation_id = p_organisation_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_CONTEXT_CAMPAIGN_SCOPE_INVALID'; END IF;
  SELECT * INTO v_genome FROM public.seller_commercial_genome_snapshots WHERE id = p_genome_snapshot_id AND organisation_id = p_organisation_id;
  IF NOT FOUND OR v_genome.seller_business_id <> v_campaign.seller_business_id THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_CONTEXT_GENOME_SCOPE_INVALID'; END IF;
  IF v_objective_key !~ '^[a-z0-9][a-z0-9._-]{0,79}$' THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_CONTEXT_OBJECTIVE_KEY_INVALID'; END IF;
  IF v_genome.canonical_genome_json#>>'{semantic,commercialObjectives,state}' <> 'DECLARED' THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_CONTEXT_OBJECTIVE_NOT_DECLARED'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_genome.canonical_genome_json#>'{semantic,commercialObjectives,items}') o
    WHERE o->>'objectiveKey' = v_objective_key
  ) THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_CONTEXT_OBJECTIVE_NOT_FOUND'; END IF;

  v_input_fingerprint := encode(extensions.digest(concat_ws('|',
    'MRV2-SELLER-CONTEXT-INPUT-1.0.0', p_organisation_id::text, p_campaign_id::text, p_genome_snapshot_id::text, v_genome.content_fingerprint, v_objective_key
  ), 'sha256'), 'hex');
  v_semantic_context_fingerprint := encode(extensions.digest(concat_ws('|',
    'MRV2-SELLER-CONTEXT-SEMANTIC-1.0.0', p_organisation_id::text, p_campaign_id::text, v_genome.seller_business_id::text, v_genome.semantic_fingerprint, v_objective_key
  ), 'sha256'), 'hex');

  IF p_request_id IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_CONTEXT_REQUEST_ID_REQUIRED'; END IF;
  SELECT * INTO v_existing FROM public.campaign_seller_context_selections WHERE selection_request_id = p_request_id;
  IF FOUND THEN
    IF v_existing.organisation_id <> p_organisation_id OR v_existing.campaign_id <> p_campaign_id OR v_existing.genome_snapshot_id <> p_genome_snapshot_id OR v_existing.objective_key <> v_objective_key THEN
      RAISE EXCEPTION 'MARKETROUTE_SELLER_CONTEXT_REQUEST_ID_REUSE_MISMATCH';
    END IF;
    RETURN jsonb_build_object('selectionId', v_existing.id, 'selectionRequestId', v_existing.selection_request_id, 'inputFingerprint', v_existing.input_fingerprint, 'semanticContextFingerprint', v_existing.semantic_context_fingerprint, 'deduplicated', true);
  END IF;
  INSERT INTO public.campaign_seller_context_selections(
    organisation_id, campaign_id, seller_business_id, genome_snapshot_id, objective_key, selection_request_id, input_fingerprint, semantic_context_fingerprint
  ) VALUES (
    p_organisation_id, p_campaign_id, v_genome.seller_business_id, p_genome_snapshot_id, v_objective_key, p_request_id, v_input_fingerprint, v_semantic_context_fingerprint
  ) RETURNING id INTO v_id;
  RETURN jsonb_build_object('selectionId', v_id, 'selectionRequestId', p_request_id, 'inputFingerprint', v_input_fingerprint, 'semanticContextFingerprint', v_semantic_context_fingerprint, 'deduplicated', false);
END;
$_$;

--
-- Name: marketroute_seller_genome_semantic_identity_v1(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_seller_genome_semantic_identity_v1(p_genome jsonb) RETURNS jsonb
    LANGUAGE sql IMMUTABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  SELECT jsonb_build_object(
    'offerings', jsonb_build_object(
      'state', p_genome#>>'{semantic,offerings,state}',
      'items', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'offeringKey', i->>'offeringKey',
        'problemCodes', public.marketroute_sort_jsonb_text_array_v1(i->'problemCodes'),
        'outcomeCodes', public.marketroute_sort_jsonb_text_array_v1(i->'outcomeCodes'),
        'deliveryModeCodes', public.marketroute_sort_jsonb_text_array_v1(i->'deliveryModeCodes')
      ) ORDER BY i->>'offeringKey') FROM jsonb_array_elements(p_genome#>'{semantic,offerings,items}') i), '[]'::jsonb)
    ),
    'capabilities', jsonb_build_object(
      'state', p_genome#>>'{semantic,capabilities,state}',
      'items', COALESCE((SELECT jsonb_agg(jsonb_build_object('capabilityKey', i->>'capabilityKey') ORDER BY i->>'capabilityKey') FROM jsonb_array_elements(p_genome#>'{semantic,capabilities,items}') i), '[]'::jsonb)
    ),
    'commercialObjectives', jsonb_build_object(
      'state', p_genome#>>'{semantic,commercialObjectives,state}',
      'items', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'objectiveKey', i->>'objectiveKey',
        'objectiveType', i->>'objectiveType',
        'offeringKeys', public.marketroute_sort_jsonb_text_array_v1(i->'offeringKeys'),
        'desiredActionCode', i->>'desiredActionCode',
        'outcomeCodes', public.marketroute_sort_jsonb_text_array_v1(i->'outcomeCodes')
      ) ORDER BY i->>'objectiveKey') FROM jsonb_array_elements(p_genome#>'{semantic,commercialObjectives,items}') i), '[]'::jsonb)
    ),
    'delivery', jsonb_build_object(
      'state', p_genome#>>'{semantic,delivery,state}',
      'modeCodes', public.marketroute_sort_jsonb_text_array_v1(p_genome#>'{semantic,delivery,modeCodes}')
    ),
    'serviceGeography', jsonb_build_object(
      'state', p_genome#>>'{semantic,serviceGeography,state}',
      'countryCodes', public.marketroute_sort_jsonb_text_array_v1(p_genome#>'{semantic,serviceGeography,countryCodes}'),
      'regionCodes', public.marketroute_sort_jsonb_text_array_v1(p_genome#>'{semantic,serviceGeography,regionCodes}')
    ),
    'targetCharacteristics', jsonb_build_object(
      'state', p_genome#>>'{semantic,targetCharacteristics,state}',
      'industryCodes', public.marketroute_sort_jsonb_text_array_v1(p_genome#>'{semantic,targetCharacteristics,industryCodes}'),
      'companySizeBands', public.marketroute_sort_jsonb_text_array_v1(p_genome#>'{semantic,targetCharacteristics,companySizeBands}'),
      'businessModelCodes', public.marketroute_sort_jsonb_text_array_v1(p_genome#>'{semantic,targetCharacteristics,businessModelCodes}')
    ),
    'buyerAssumptions', jsonb_build_object(
      'state', p_genome#>>'{semantic,buyerAssumptions,state}',
      'roleCodes', public.marketroute_sort_jsonb_text_array_v1(p_genome#>'{semantic,buyerAssumptions,roleCodes}'),
      'departmentCodes', public.marketroute_sort_jsonb_text_array_v1(p_genome#>'{semantic,buyerAssumptions,departmentCodes}'),
      'painCodes', public.marketroute_sort_jsonb_text_array_v1(p_genome#>'{semantic,buyerAssumptions,painCodes}')
    ),
    'constraints', jsonb_build_object(
      'state', p_genome#>>'{semantic,constraints,state}',
      'items', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'constraintKey', i->>'constraintKey',
        'constraintType', i->>'constraintType',
        'mode', i->>'mode',
        'valueCodes', public.marketroute_sort_jsonb_text_array_v1(i->'valueCodes')
      ) ORDER BY i->>'constraintKey') FROM jsonb_array_elements(p_genome#>'{semantic,constraints,items}') i), '[]'::jsonb)
    )
  );
$$;

--
-- Name: marketroute_seller_genome_validate_v1(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_seller_genome_validate_v1(p_seller_business_id uuid, p_genome jsonb) RETURNS void
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp', 'extensions'
    AS $_$
DECLARE
  v_seller public.seller_businesses%ROWTYPE;
  v_semantic jsonb;
  v_dimension text;
  v_state text;
  v_missing text[] := '{}';
  v_declared_count integer;
  v_unknown_count integer;
  v_expected_completeness text;
  v_objective jsonb;
  v_offering_ref jsonb;
  v_item jsonb;
  v_supplied_missing text[] := '{}';
  v_unknown_dimensions text[] := '{}';
BEGIN
  SELECT * INTO v_seller FROM public.seller_businesses WHERE id = p_seller_business_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_SELLER_NOT_FOUND'; END IF;
  IF jsonb_typeof(p_genome) <> 'object' THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_OBJECT_REQUIRED'; END IF;
  IF p_genome->>'schemaVersion' <> 'MRV2-SELLER-GENOME-1.0.0' THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_SCHEMA_VERSION_INVALID'; END IF;
  IF p_genome->>'canonicalisationVersion' <> 'MRV2-SELLER-CANON-1.0.0' THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_CANON_VERSION_INVALID'; END IF;
  IF p_genome->>'sellerBusinessId' <> p_seller_business_id::text THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_SELLER_ID_MISMATCH'; END IF;
  IF jsonb_typeof(p_genome->'semantic') <> 'object' THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_SEMANTIC_OBJECT_REQUIRED'; END IF;
  IF jsonb_typeof(p_genome->'explanatory') <> 'object' THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_EXPLANATORY_OBJECT_REQUIRED'; END IF;
  IF regexp_replace(btrim(COALESCE(p_genome#>>'{explanatory,sellerDisplayName}', '')), '\s+', ' ', 'g')
     <> regexp_replace(btrim(v_seller.name), '\s+', ' ', 'g') THEN
    RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_DISPLAY_NAME_MISMATCH';
  END IF;

  v_semantic := p_genome->'semantic';
  IF p_genome::text ~* '"[^"]*(confidence|probability|score|rank|fit|viab|authority|priority)[^"]*"\s*:' THEN
    RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_FORBIDDEN_FIELD';
  END IF;
  IF NOT (v_semantic ?& ARRAY['offerings','capabilities','commercialObjectives','delivery','serviceGeography','targetCharacteristics','buyerAssumptions','constraints'])
     OR (v_semantic - ARRAY['offerings','capabilities','commercialObjectives','delivery','serviceGeography','targetCharacteristics','buyerAssumptions','constraints']) <> '{}'::jsonb THEN
    RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_SEMANTIC_KEYS_INVALID';
  END IF;
  FOREACH v_dimension IN ARRAY ARRAY['offerings','capabilities','commercialObjectives','delivery','serviceGeography','targetCharacteristics','buyerAssumptions','constraints']
  LOOP
    IF jsonb_typeof(v_semantic->v_dimension) <> 'object' THEN
      RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_DIMENSION_REQUIRED:%', v_dimension;
    END IF;
    v_state := v_semantic->v_dimension->>'state';
    IF v_state NOT IN ('DECLARED','EXPLICIT_NONE','UNKNOWN') THEN
      RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_DIMENSION_STATE_INVALID:%', v_dimension;
    END IF;
    IF v_state = 'UNKNOWN' THEN v_missing := array_append(v_missing, v_dimension); END IF;
  END LOOP;

  -- List dimensions must obey state/value consistency.
  FOREACH v_dimension IN ARRAY ARRAY['offerings','capabilities','commercialObjectives','constraints']
  LOOP
    IF jsonb_typeof(v_semantic->v_dimension->'items') <> 'array' THEN
      RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_ITEMS_ARRAY_REQUIRED:%', v_dimension;
    END IF;
    v_declared_count := jsonb_array_length(v_semantic->v_dimension->'items');
    v_state := v_semantic->v_dimension->>'state';
    IF v_state = 'DECLARED' AND v_declared_count = 0 THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_DECLARED_EMPTY:%', v_dimension; END IF;
    IF v_state <> 'DECLARED' AND v_declared_count <> 0 THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_NONDECLARED_HAS_ITEMS:%', v_dimension; END IF;
  END LOOP;

  IF ((v_semantic->'offerings') - ARRAY['state','items']) <> '{}'::jsonb OR NOT (v_semantic->'offerings' ?& ARRAY['state','items']) THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_OFFERING_DIMENSION_KEYS_INVALID'; END IF;
  IF ((v_semantic->'capabilities') - ARRAY['state','items']) <> '{}'::jsonb OR NOT (v_semantic->'capabilities' ?& ARRAY['state','items']) THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_CAPABILITY_DIMENSION_KEYS_INVALID'; END IF;
  IF ((v_semantic->'commercialObjectives') - ARRAY['state','items']) <> '{}'::jsonb OR NOT (v_semantic->'commercialObjectives' ?& ARRAY['state','items']) THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_OBJECTIVE_DIMENSION_KEYS_INVALID'; END IF;
  IF ((v_semantic->'constraints') - ARRAY['state','items']) <> '{}'::jsonb OR NOT (v_semantic->'constraints' ?& ARRAY['state','items']) THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_CONSTRAINT_DIMENSION_KEYS_INVALID'; END IF;
  IF ((v_semantic->'delivery') - ARRAY['state','modeCodes']) <> '{}'::jsonb OR NOT (v_semantic->'delivery' ?& ARRAY['state','modeCodes']) THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_DELIVERY_KEYS_INVALID'; END IF;
  IF ((v_semantic->'serviceGeography') - ARRAY['state','countryCodes','regionCodes']) <> '{}'::jsonb OR NOT (v_semantic->'serviceGeography' ?& ARRAY['state','countryCodes','regionCodes']) THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_GEOGRAPHY_KEYS_INVALID'; END IF;
  IF ((v_semantic->'targetCharacteristics') - ARRAY['state','industryCodes','companySizeBands','businessModelCodes']) <> '{}'::jsonb OR NOT (v_semantic->'targetCharacteristics' ?& ARRAY['state','industryCodes','companySizeBands','businessModelCodes']) THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_TARGET_KEYS_INVALID'; END IF;
  IF ((v_semantic->'buyerAssumptions') - ARRAY['state','roleCodes','departmentCodes','painCodes']) <> '{}'::jsonb OR NOT (v_semantic->'buyerAssumptions' ?& ARRAY['state','roleCodes','departmentCodes','painCodes']) THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_BUYER_KEYS_INVALID'; END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(v_semantic#>'{offerings,items}') LOOP
    IF (v_item - ARRAY['offeringKey','problemCodes','outcomeCodes','deliveryModeCodes']) <> '{}'::jsonb OR NOT (v_item ?& ARRAY['offeringKey','problemCodes','outcomeCodes','deliveryModeCodes']) THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_OFFERING_ITEM_KEYS_INVALID'; END IF;
    IF COALESCE(v_item->>'offeringKey','') !~ '^[a-z0-9][a-z0-9._-]{0,79}$' THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_OFFERING_KEY_INVALID'; END IF;
    IF NOT public.marketroute_jsonb_text_array_is_set_v1(v_item->'problemCodes','^[a-z0-9][a-z0-9._-]{0,79}$') OR NOT public.marketroute_jsonb_text_array_is_set_v1(v_item->'outcomeCodes','^[a-z0-9][a-z0-9._-]{0,79}$') OR NOT public.marketroute_jsonb_text_array_is_set_v1(v_item->'deliveryModeCodes','^[a-z0-9][a-z0-9._-]{0,79}$') THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_OFFERING_CODES_INVALID'; END IF;
  END LOOP;
  IF (SELECT count(*) FROM jsonb_array_elements(v_semantic#>'{offerings,items}')) <> (SELECT count(DISTINCT value->>'offeringKey') FROM jsonb_array_elements(v_semantic#>'{offerings,items}')) THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_DUPLICATE_OFFERING_KEY'; END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(v_semantic#>'{capabilities,items}') LOOP
    IF (v_item - ARRAY['capabilityKey']) <> '{}'::jsonb OR NOT (v_item ? 'capabilityKey') OR COALESCE(v_item->>'capabilityKey','') !~ '^[a-z0-9][a-z0-9._-]{0,79}$' THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_CAPABILITY_ITEM_INVALID'; END IF;
  END LOOP;
  IF (SELECT count(*) FROM jsonb_array_elements(v_semantic#>'{capabilities,items}')) <> (SELECT count(DISTINCT value->>'capabilityKey') FROM jsonb_array_elements(v_semantic#>'{capabilities,items}')) THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_DUPLICATE_CAPABILITY_KEY'; END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(v_semantic#>'{constraints,items}') LOOP
    IF (v_item - ARRAY['constraintKey','constraintType','mode','valueCodes']) <> '{}'::jsonb OR NOT (v_item ?& ARRAY['constraintKey','constraintType','mode','valueCodes']) THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_CONSTRAINT_ITEM_KEYS_INVALID'; END IF;
    IF COALESCE(v_item->>'constraintKey','') !~ '^[a-z0-9][a-z0-9._-]{0,79}$' OR COALESCE(v_item->>'constraintType','') !~ '^[a-z0-9][a-z0-9._-]{0,79}$' OR v_item->>'mode' NOT IN ('HARD','PREFERENCE') OR NOT public.marketroute_jsonb_text_array_is_set_v1(v_item->'valueCodes','^[a-z0-9][a-z0-9._-]{0,79}$') OR jsonb_array_length(v_item->'valueCodes') = 0 THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_CONSTRAINT_ITEM_INVALID'; END IF;
  END LOOP;
  IF (SELECT count(*) FROM jsonb_array_elements(v_semantic#>'{constraints,items}')) <> (SELECT count(DISTINCT value->>'constraintKey') FROM jsonb_array_elements(v_semantic#>'{constraints,items}')) THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_DUPLICATE_CONSTRAINT_KEY'; END IF;

  IF jsonb_typeof(v_semantic#>'{delivery,modeCodes}') <> 'array' THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_DELIVERY_MODES_ARRAY_REQUIRED'; END IF;
  IF jsonb_typeof(v_semantic#>'{serviceGeography,countryCodes}') <> 'array' OR jsonb_typeof(v_semantic#>'{serviceGeography,regionCodes}') <> 'array' THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_GEOGRAPHY_ARRAYS_REQUIRED'; END IF;
  IF jsonb_typeof(v_semantic#>'{targetCharacteristics,industryCodes}') <> 'array' OR jsonb_typeof(v_semantic#>'{targetCharacteristics,companySizeBands}') <> 'array' OR jsonb_typeof(v_semantic#>'{targetCharacteristics,businessModelCodes}') <> 'array' THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_TARGET_ARRAYS_REQUIRED'; END IF;
  IF jsonb_typeof(v_semantic#>'{buyerAssumptions,roleCodes}') <> 'array' OR jsonb_typeof(v_semantic#>'{buyerAssumptions,departmentCodes}') <> 'array' OR jsonb_typeof(v_semantic#>'{buyerAssumptions,painCodes}') <> 'array' THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_BUYER_ARRAYS_REQUIRED'; END IF;
  IF NOT public.marketroute_jsonb_text_array_is_set_v1(v_semantic#>'{delivery,modeCodes}','^[a-z0-9][a-z0-9._-]{0,79}$') THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_DELIVERY_CODES_INVALID'; END IF;
  IF NOT public.marketroute_jsonb_text_array_is_set_v1(v_semantic#>'{serviceGeography,countryCodes}','^[A-Z]{2}$') OR NOT public.marketroute_jsonb_text_array_is_set_v1(v_semantic#>'{serviceGeography,regionCodes}','^[a-z0-9][a-z0-9._-]{0,79}$') THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_GEOGRAPHY_CODES_INVALID'; END IF;
  IF NOT public.marketroute_jsonb_text_array_is_set_v1(v_semantic#>'{targetCharacteristics,industryCodes}','^[a-z0-9][a-z0-9._-]{0,79}$') OR NOT public.marketroute_jsonb_text_array_is_set_v1(v_semantic#>'{targetCharacteristics,companySizeBands}','^[a-z0-9][a-z0-9._-]{0,79}$') OR NOT public.marketroute_jsonb_text_array_is_set_v1(v_semantic#>'{targetCharacteristics,businessModelCodes}','^[a-z0-9][a-z0-9._-]{0,79}$') THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_TARGET_CODES_INVALID'; END IF;
  IF NOT public.marketroute_jsonb_text_array_is_set_v1(v_semantic#>'{buyerAssumptions,roleCodes}','^[a-z0-9][a-z0-9._-]{0,79}$') OR NOT public.marketroute_jsonb_text_array_is_set_v1(v_semantic#>'{buyerAssumptions,departmentCodes}','^[a-z0-9][a-z0-9._-]{0,79}$') OR NOT public.marketroute_jsonb_text_array_is_set_v1(v_semantic#>'{buyerAssumptions,painCodes}','^[a-z0-9][a-z0-9._-]{0,79}$') THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_BUYER_CODES_INVALID'; END IF;

  IF (v_semantic#>>'{delivery,state}') = 'DECLARED' AND jsonb_array_length(v_semantic#>'{delivery,modeCodes}') = 0 THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_DECLARED_EMPTY:delivery'; END IF;
  IF (v_semantic#>>'{delivery,state}') <> 'DECLARED' AND jsonb_array_length(v_semantic#>'{delivery,modeCodes}') <> 0 THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_NONDECLARED_HAS_VALUES:delivery'; END IF;

  IF (v_semantic#>>'{serviceGeography,state}') = 'DECLARED' AND (jsonb_array_length(v_semantic#>'{serviceGeography,countryCodes}') + jsonb_array_length(v_semantic#>'{serviceGeography,regionCodes}')) = 0 THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_DECLARED_EMPTY:serviceGeography'; END IF;
  IF (v_semantic#>>'{serviceGeography,state}') <> 'DECLARED' AND (jsonb_array_length(v_semantic#>'{serviceGeography,countryCodes}') + jsonb_array_length(v_semantic#>'{serviceGeography,regionCodes}')) <> 0 THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_NONDECLARED_HAS_VALUES:serviceGeography'; END IF;

  IF (v_semantic#>>'{targetCharacteristics,state}') = 'DECLARED' AND (jsonb_array_length(v_semantic#>'{targetCharacteristics,industryCodes}') + jsonb_array_length(v_semantic#>'{targetCharacteristics,companySizeBands}') + jsonb_array_length(v_semantic#>'{targetCharacteristics,businessModelCodes}')) = 0 THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_DECLARED_EMPTY:targetCharacteristics'; END IF;
  IF (v_semantic#>>'{targetCharacteristics,state}') <> 'DECLARED' AND (jsonb_array_length(v_semantic#>'{targetCharacteristics,industryCodes}') + jsonb_array_length(v_semantic#>'{targetCharacteristics,companySizeBands}') + jsonb_array_length(v_semantic#>'{targetCharacteristics,businessModelCodes}')) <> 0 THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_NONDECLARED_HAS_VALUES:targetCharacteristics'; END IF;

  IF (v_semantic#>>'{buyerAssumptions,state}') = 'DECLARED' AND (jsonb_array_length(v_semantic#>'{buyerAssumptions,roleCodes}') + jsonb_array_length(v_semantic#>'{buyerAssumptions,departmentCodes}') + jsonb_array_length(v_semantic#>'{buyerAssumptions,painCodes}')) = 0 THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_DECLARED_EMPTY:buyerAssumptions'; END IF;
  IF (v_semantic#>>'{buyerAssumptions,state}') <> 'DECLARED' AND (jsonb_array_length(v_semantic#>'{buyerAssumptions,roleCodes}') + jsonb_array_length(v_semantic#>'{buyerAssumptions,departmentCodes}') + jsonb_array_length(v_semantic#>'{buyerAssumptions,painCodes}')) <> 0 THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_NONDECLARED_HAS_VALUES:buyerAssumptions'; END IF;

  -- Objective references must point at offerings inside this exact semantic snapshot.
  FOR v_objective IN SELECT value FROM jsonb_array_elements(v_semantic#>'{commercialObjectives,items}')
  LOOP
    IF (v_objective - ARRAY['objectiveKey','objectiveType','offeringKeys','desiredActionCode','outcomeCodes']) <> '{}'::jsonb OR NOT (v_objective ?& ARRAY['objectiveKey','objectiveType','offeringKeys','desiredActionCode','outcomeCodes']) THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_OBJECTIVE_ITEM_KEYS_INVALID'; END IF;
    IF COALESCE(v_objective->>'objectiveKey','') !~ '^[a-z0-9][a-z0-9._-]{0,79}$' THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_OBJECTIVE_KEY_INVALID'; END IF;
    IF COALESCE(v_objective->>'desiredActionCode','') !~ '^[a-z0-9][a-z0-9._-]{0,79}$' THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_OBJECTIVE_ACTION_INVALID'; END IF;
    IF v_objective->>'objectiveType' NOT IN ('ACQUIRE_CUSTOMERS','EXPAND_ACCOUNTS','BUILD_PARTNERSHIPS','ENTER_MARKET','SOURCE_SUPPLIERS','RECRUIT_TALENT','OTHER') THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_OBJECTIVE_TYPE_INVALID'; END IF;
    IF NOT public.marketroute_jsonb_text_array_is_set_v1(v_objective->'offeringKeys','^[a-z0-9][a-z0-9._-]{0,79}$') OR NOT public.marketroute_jsonb_text_array_is_set_v1(v_objective->'outcomeCodes','^[a-z0-9][a-z0-9._-]{0,79}$') THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_OBJECTIVE_CODES_INVALID'; END IF;
    FOR v_offering_ref IN SELECT value FROM jsonb_array_elements(v_objective->'offeringKeys')
    LOOP
      IF NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(v_semantic#>'{offerings,items}') o
        WHERE o->>'offeringKey' = trim(both '"' from v_offering_ref::text)
      ) THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_OBJECTIVE_UNKNOWN_OFFERING'; END IF;
    END LOOP;
  END LOOP;
  IF (SELECT count(*) FROM jsonb_array_elements(v_semantic#>'{commercialObjectives,items}')) <> (SELECT count(DISTINCT value->>'objectiveKey') FROM jsonb_array_elements(v_semantic#>'{commercialObjectives,items}')) THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_DUPLICATE_OBJECTIVE_KEY'; END IF;

  IF jsonb_typeof(p_genome->'missingDimensions') <> 'array' OR jsonb_typeof(p_genome->'explicitUnknowns') <> 'array' THEN
    RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_UNKNOWN_ARRAYS_REQUIRED';
  END IF;
  SELECT COALESCE(array_agg(value ORDER BY value), '{}') INTO v_supplied_missing FROM jsonb_array_elements_text(p_genome->'missingDimensions') value;
  SELECT COALESCE(array_agg(value ORDER BY value), '{}') INTO v_missing FROM unnest(v_missing) value;
  IF v_supplied_missing IS DISTINCT FROM v_missing THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_MISSING_DIMENSIONS_MISMATCH'; END IF;
  SELECT count(*), COALESCE(array_agg(value->>'dimension' ORDER BY value->>'dimension'), '{}') INTO v_unknown_count, v_unknown_dimensions FROM jsonb_array_elements(p_genome->'explicitUnknowns') value;
  IF v_unknown_count <> cardinality(v_missing) OR v_unknown_dimensions IS DISTINCT FROM v_missing THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_UNKNOWN_COUNT_MISMATCH'; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_genome->'explicitUnknowns') u WHERE (u - ARRAY['dimension','question']) <> '{}'::jsonb OR NOT (u ?& ARRAY['dimension','question']) OR length(btrim(COALESCE(u->>'question',''))) = 0) THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_UNKNOWN_ITEM_INVALID'; END IF;

  v_expected_completeness := CASE WHEN cardinality(v_missing) = 0 THEN 'COMPLETE' ELSE 'PARTIAL' END;
  IF p_genome->>'semanticCompleteness' <> v_expected_completeness THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_COMPLETENESS_MISMATCH'; END IF;
END;
$_$;

--
-- Name: marketroute_set_research_policy_v1(uuid, uuid, numeric, numeric, integer, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_set_research_policy_v1(p_organisation_id uuid, p_campaign_id uuid, p_daily_budget_usd numeric, p_max_job_cost_usd numeric, p_max_concurrent_jobs integer, p_max_work_units_per_plan integer, p_refresh_horizon_hours integer) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.campaigns WHERE id=p_campaign_id AND organisation_id=p_organisation_id) THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_POLICY_SCOPE_MISMATCH'; END IF;
 IF p_daily_budget_usd<0 OR p_daily_budget_usd>100000 OR p_max_job_cost_usd<0 OR p_max_job_cost_usd>p_daily_budget_usd OR p_max_concurrent_jobs<0 OR p_max_concurrent_jobs>100 OR p_max_work_units_per_plan<0 OR p_max_work_units_per_plan>100 OR p_refresh_horizon_hours<0 OR p_refresh_horizon_hours>168 THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_POLICY_INVALID'; END IF;
 INSERT INTO public.research_budget_policies(organisation_id,campaign_id,daily_budget_usd,max_job_cost_usd,max_concurrent_jobs,max_work_units_per_plan,refresh_horizon_hours,enabled,updated_at)
 VALUES(p_organisation_id,p_campaign_id,p_daily_budget_usd,p_max_job_cost_usd,p_max_concurrent_jobs,p_max_work_units_per_plan,p_refresh_horizon_hours,true,now())
 ON CONFLICT(organisation_id,campaign_id) DO UPDATE SET daily_budget_usd=EXCLUDED.daily_budget_usd,max_job_cost_usd=EXCLUDED.max_job_cost_usd,max_concurrent_jobs=EXCLUDED.max_concurrent_jobs,max_work_units_per_plan=EXCLUDED.max_work_units_per_plan,refresh_horizon_hours=EXCLUDED.refresh_horizon_hours,enabled=true,updated_at=now();
 RETURN public.marketroute_research_policy_v1(p_organisation_id,p_campaign_id);
END $$;

--
-- Name: marketroute_set_workspace_activation_stage_v1(uuid, text, text, integer, jsonb, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_set_workspace_activation_stage_v1(p_job_id uuid, p_worker_id text, p_stage text, p_progress integer, p_detail_json jsonb DEFAULT '{}'::jsonb, p_at timestamp with time zone DEFAULT now()) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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
$$;

--
-- Name: marketroute_sort_jsonb_text_array_v1(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_sort_jsonb_text_array_v1(p_value jsonb) RETURNS jsonb
    LANGUAGE sql IMMUTABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  SELECT COALESCE(jsonb_agg(value ORDER BY value), '[]'::jsonb)
  FROM jsonb_array_elements_text(p_value) value;
$$;

--
-- Name: marketroute_start_growth_scheduler_run_v1(timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_start_growth_scheduler_run_v1(p_at timestamp with time zone DEFAULT now()) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_id uuid;
  v_owner uuid;
  v_enabled boolean := false;
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT enabled INTO v_enabled
  FROM public.genesis_growth_settings
  WHERE singleton=true;
  IF COALESCE(v_enabled,false)=false THEN
    RAISE EXCEPTION 'MARKETROUTE_GROWTH_PAUSED';
  END IF;
  IF abs(extract(epoch from (p_at-now())))>300 THEN
    RAISE EXCEPTION 'MARKETROUTE_GROWTH_SCHEDULER_TIME_NOT_CURRENT';
  END IF;
  INSERT INTO public.scheduler_runs(runner_key,status,started_at,metadata_json)
  VALUES(
    'GENESIS_DATABASE_GROWTH_V1','RUNNING',p_at,
    jsonb_build_object('growthEngine','MRV2-GENESIS-GROWTH-1.0.0','productPolicy','DEMAND_DRIVEN')
  ) RETURNING id INTO v_id;
  INSERT INTO public.scheduler_leases(lease_key,owner_run_id,acquired_at,expires_at,heartbeat_at)
  VALUES('GENESIS_DATABASE_GROWTH_V1',v_id,p_at,p_at+interval '10 minutes',p_at)
  ON CONFLICT(lease_key) DO UPDATE
    SET owner_run_id=EXCLUDED.owner_run_id,
        acquired_at=EXCLUDED.acquired_at,
        expires_at=EXCLUDED.expires_at,
        heartbeat_at=EXCLUDED.heartbeat_at
    WHERE public.scheduler_leases.expires_at<=p_at
  RETURNING owner_run_id INTO v_owner;
  IF v_owner IS DISTINCT FROM v_id THEN
    UPDATE public.scheduler_runs
    SET status='CANCELLED',completed_at=p_at,
        metadata_json=metadata_json||jsonb_build_object('leaseHeld',true)
    WHERE id=v_id;
    RAISE EXCEPTION 'MARKETROUTE_GROWTH_SCHEDULER_LEASE_HELD';
  END IF;
  RETURN v_id;
END;
$$;

--
-- Name: marketroute_start_research_scheduler_run_v1(text, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_start_research_scheduler_run_v1(p_runner_key text DEFAULT 'GENESIS_RESEARCH_V1'::text, p_at timestamp with time zone DEFAULT now()) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_id uuid; v_owner uuid;
BEGIN
 IF p_runner_key<>'GENESIS_RESEARCH_V1' THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_RUNNER_KEY_INVALID'; END IF;
 IF abs(extract(epoch from (p_at-now())))>300 THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_SCHEDULER_TIME_NOT_CURRENT'; END IF;
 INSERT INTO public.scheduler_runs(runner_key,status,started_at,metadata_json) VALUES(p_runner_key,'RUNNING',p_at,jsonb_build_object('researchEngine','MRV2-RESEARCH-PLANNER-1.0.0')) RETURNING id INTO v_id;
 INSERT INTO public.scheduler_leases(lease_key,owner_run_id,acquired_at,expires_at,heartbeat_at) VALUES('GENESIS_RESEARCH_V1',v_id,p_at,p_at+interval '30 minutes',p_at)
 ON CONFLICT(lease_key) DO UPDATE SET owner_run_id=EXCLUDED.owner_run_id,acquired_at=EXCLUDED.acquired_at,expires_at=EXCLUDED.expires_at,heartbeat_at=EXCLUDED.heartbeat_at WHERE public.scheduler_leases.expires_at<=p_at
 RETURNING owner_run_id INTO v_owner;
 IF v_owner IS DISTINCT FROM v_id THEN RAISE EXCEPTION 'MARKETROUTE_RESEARCH_SCHEDULER_LEASE_HELD'; END IF;
 UPDATE public.scheduler_runs SET metadata_json=metadata_json||jsonb_build_object('recoveredAbandonedWork',public.marketroute_recover_abandoned_research_work_v1(v_id,p_at)) WHERE id=v_id;
 RETURN v_id;
END $$;

--
-- Name: marketroute_submit_campaign_v2(uuid, text, text, text, text, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_submit_campaign_v2(p_organisation_id uuid, p_campaign_name text, p_seller_offering_text text, p_objective_text text, p_target_market_text text, p_hard_constraints_text text, p_no_hard_constraints boolean, p_actor_user_id uuid) RETURNS uuid
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
  SELECT public.marketroute_submit_campaign_v3($1,$2,$3,$4,$5,$6,$7,$8);
$_$;

--
-- Name: marketroute_submit_campaign_v3(uuid, text, text, text, text, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_submit_campaign_v3(p_organisation_id uuid, p_campaign_name text, p_seller_offering_text text, p_objective_text text, p_target_market_text text, p_hard_constraints_text text, p_no_hard_constraints boolean, p_actor_user_id uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_user uuid:=p_actor_user_id;
  v_seller uuid;
  v_job uuid;
  v_name text:=nullif(btrim(COALESCE(p_campaign_name,'')),'');
  v_offering text:=nullif(btrim(COALESCE(p_seller_offering_text,'')),'');
  v_no_hard boolean:=COALESCE(p_no_hard_constraints,false);
  v_hard text:=nullif(btrim(COALESCE(p_hard_constraints_text,'')),'');
  v_plan_code text;
  v_limit integer;
  v_live integer;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_AUTH_REQUIRED'; END IF;
  IF NOT public.marketroute_is_org_admin(p_organisation_id, p_actor_user_id) THEN RAISE EXCEPTION 'MARKETROUTE_CAMPAIGN_ADMIN_REQUIRED'; END IF;
  IF v_name IS NULL OR length(v_name) NOT BETWEEN 3 AND 120 THEN RAISE EXCEPTION 'MARKETROUTE_CAMPAIGN_NAME_REQUIRED'; END IF;
  IF v_offering IS NULL OR length(v_offering)<8 THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_OFFERING_REQUIRED'; END IF;
  IF length(btrim(COALESCE(p_objective_text,'')))<8 THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_OBJECTIVE_REQUIRED'; END IF;
  IF length(btrim(COALESCE(p_target_market_text,'')))<3 THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_TARGET_REQUIRED'; END IF;
  IF v_no_hard AND v_hard IS NOT NULL THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_CONSTRAINT_CONFLICT'; END IF;
  IF NOT v_no_hard AND v_hard IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_CONSTRAINT_DECLARATION_REQUIRED'; END IF;

  PERFORM 1 FROM public.organisations o
  WHERE o.id=p_organisation_id AND o.status='ACTIVE'
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_WORKSPACE_NOT_ACTIVE'; END IF;

  SELECT e.plan_code,p.active_market_limit
  INTO v_plan_code,v_limit
  FROM public.organisation_commercial_entitlements e
  JOIN public.marketroute_plan_catalog p ON p.plan_code=e.plan_code
  WHERE e.organisation_id=p_organisation_id
    AND e.status='ACTIVE'
    AND e.plan_code IN('STARTER','GROWTH','SCALE','LEGACY_FULL')
    AND (e.current_period_start IS NULL OR e.current_period_start<=now())
    AND (e.current_period_end IS NULL OR e.current_period_end>now())
  ORDER BY e.updated_at DESC LIMIT 1;
  IF v_plan_code IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_CAMPAIGN_PLAN_REQUIRED'; END IF;

  SELECT count(*)::int INTO v_live
  FROM public.campaigns c
  WHERE c.organisation_id=p_organisation_id AND c.workflow_state<>'ARCHIVED';
  IF v_live>=v_limit THEN RAISE EXCEPTION 'MARKETROUTE_CAMPAIGN_LIMIT_REACHED'; END IF;

  IF EXISTS(
    SELECT 1 FROM public.workspace_activation_jobs j
    WHERE j.organisation_id=p_organisation_id
      AND (j.status='PENDING' OR (j.status='RUNNING' AND COALESCE(j.lease_expires_at,now()+interval '1 minute')>=now()))
  ) THEN
    RAISE EXCEPTION 'MARKETROUTE_CAMPAIGN_CREATION_ALREADY_PROCESSING';
  END IF;

  SELECT s.id INTO v_seller
  FROM public.seller_businesses s
  WHERE s.organisation_id=p_organisation_id AND s.lifecycle_state='ACTIVE'
  ORDER BY s.created_at,s.id LIMIT 1;
  IF v_seller IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_SELLER_NOT_FOUND'; END IF;

  INSERT INTO public.workspace_activation_jobs(
    organisation_id,seller_business_id,campaign_name,seller_offering_text,objective_text,target_market_text,
    hard_constraints_text,no_hard_constraints,status,attempt_count,available_at,worker_id,lease_expires_at,
    last_error_code,result_json,activation_stage,activation_progress,activation_stage_detail_json,activation_kind
  ) VALUES(
    p_organisation_id,v_seller,v_name,v_offering,btrim(p_objective_text),btrim(p_target_market_text),
    CASE WHEN v_no_hard THEN NULL ELSE v_hard END,v_no_hard,'PENDING',0,now(),NULL,NULL,NULL,'{}'::jsonb,
    'QUEUED',0,'{}'::jsonb,'CUSTOMER_CAMPAIGN'
  ) RETURNING id INTO v_job;

  RETURN v_job;
END;
$$;

--
-- Name: marketroute_submit_replacement_campaign_v1(uuid, text, text, text, text, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_submit_replacement_campaign_v1(p_organisation_id uuid, p_campaign_name text, p_seller_offering_text text, p_objective_text text, p_target_market_text text, p_hard_constraints_text text, p_no_hard_constraints boolean, p_actor_user_id uuid) RETURNS uuid
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
  SELECT public.marketroute_submit_campaign_v3($1,$2,$3,$4,$5,$6,$7,$8);
$_$;

--
-- Name: marketroute_submit_workspace_activation_v1(uuid, text, text, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_submit_workspace_activation_v1(p_organisation_id uuid, p_objective_text text, p_target_market_text text, p_hard_constraints_text text, p_no_hard_constraints boolean, p_actor_user_id uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_offering text;
BEGIN
  SELECT j.seller_offering_text INTO v_offering
  FROM public.workspace_activation_jobs j
  WHERE j.organisation_id=p_organisation_id AND j.seller_offering_text IS NOT NULL
  ORDER BY j.created_at DESC,j.id DESC LIMIT 1;
  IF v_offering IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_CLIENT_UPGRADE_REQUIRED'; END IF;
  RETURN public.marketroute_submit_workspace_activation_v2(p_organisation_id,v_offering,p_objective_text,p_target_market_text,p_hard_constraints_text,p_no_hard_constraints,p_actor_user_id);
END;
$$;

--
-- Name: marketroute_submit_workspace_activation_v2(uuid, text, text, text, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_submit_workspace_activation_v2(p_organisation_id uuid, p_seller_offering_text text, p_objective_text text, p_target_market_text text, p_hard_constraints_text text, p_no_hard_constraints boolean, p_actor_user_id uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_user uuid:=p_actor_user_id;v_seller uuid;v_job uuid;
  v_offering text:=nullif(btrim(COALESCE(p_seller_offering_text,'')),'');
  v_no_hard boolean:=COALESCE(p_no_hard_constraints,false);
  v_hard text:=nullif(btrim(COALESCE(p_hard_constraints_text,'')),'');
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_AUTH_REQUIRED'; END IF;
  IF NOT public.marketroute_is_org_admin(p_organisation_id, p_actor_user_id) THEN RAISE EXCEPTION 'MARKETROUTE_WORKSPACE_ADMIN_REQUIRED'; END IF;
  IF v_offering IS NULL OR length(v_offering)<8 THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_OFFERING_REQUIRED'; END IF;
  IF length(btrim(COALESCE(p_objective_text,'')))<8 THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_OBJECTIVE_REQUIRED'; END IF;
  IF length(btrim(COALESCE(p_target_market_text,'')))<3 THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_TARGET_REQUIRED'; END IF;
  IF v_no_hard AND v_hard IS NOT NULL THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_CONSTRAINT_CONFLICT'; END IF;
  IF NOT v_no_hard AND v_hard IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_CONSTRAINT_DECLARATION_REQUIRED'; END IF;

  PERFORM 1 FROM public.organisations o WHERE o.id=p_organisation_id AND o.status='ACTIVE' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_WORKSPACE_NOT_ACTIVE'; END IF;
  IF EXISTS(SELECT 1 FROM public.campaigns c WHERE c.organisation_id=p_organisation_id) THEN
    RAISE EXCEPTION 'MARKETROUTE_SETUP_ALREADY_COMPLETE';
  END IF;
  IF EXISTS(SELECT 1 FROM public.workspace_activation_jobs j WHERE j.organisation_id=p_organisation_id AND j.status IN('PENDING','RUNNING')) THEN
    RAISE EXCEPTION 'MARKETROUTE_CAMPAIGN_CREATION_ALREADY_PROCESSING';
  END IF;

  SELECT id INTO v_seller FROM public.seller_businesses
  WHERE organisation_id=p_organisation_id AND lifecycle_state='ACTIVE'
  ORDER BY created_at,id LIMIT 1;
  IF v_seller IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_SELLER_NOT_FOUND'; END IF;

  INSERT INTO public.workspace_activation_jobs(
    organisation_id,seller_business_id,campaign_name,seller_offering_text,objective_text,target_market_text,
    hard_constraints_text,no_hard_constraints,status,attempt_count,available_at,worker_id,lease_expires_at,
    last_error_code,result_json,activation_stage,activation_progress,activation_stage_detail_json,activation_kind
  ) VALUES(
    p_organisation_id,v_seller,NULL,v_offering,btrim(p_objective_text),btrim(p_target_market_text),
    CASE WHEN v_no_hard THEN NULL ELSE v_hard END,v_no_hard,'PENDING',0,now(),NULL,NULL,NULL,'{}'::jsonb,
    'QUEUED',0,'{}'::jsonb,'WORKSPACE_INITIAL'
  ) RETURNING id INTO v_job;
  RETURN v_job;
END;
$$;

--
-- Name: marketroute_supersede_claim_v1(uuid, uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_supersede_claim_v1(p_prior_claim_id uuid, p_replacement_claim_id uuid, p_reason_code text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_id uuid;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF length(btrim(COALESCE(p_reason_code, ''))) = 0 THEN RAISE EXCEPTION 'MARKETROUTE_SUPERSESSION_REASON_REQUIRED'; END IF;
  INSERT INTO public.claim_supersessions(prior_claim_id, replacement_claim_id, reason_code)
  VALUES (p_prior_claim_id, p_replacement_claim_id, p_reason_code)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

--
-- Name: marketroute_sync_growth_settings_v1(boolean, integer, integer, numeric, numeric, integer, integer, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_sync_growth_settings_v1(p_enabled boolean, p_seed_target integer, p_launch_target integer, p_daily_budget numeric, p_max_action_cost numeric, p_discovery_batch integer, p_max_actions integer, p_retry_hours integer, p_refresh_days integer) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
 PERFORM public.marketroute_require_service_role();
 IF p_seed_target<1 OR p_launch_target<p_seed_target OR p_discovery_batch<1 OR p_discovery_batch>25 OR p_max_actions<1 OR p_max_actions>20 OR p_retry_hours<1 OR p_refresh_days<1 THEN RAISE EXCEPTION 'MARKETROUTE_GROWTH_SETTINGS_INVALID'; END IF;
 IF p_daily_budget<0 OR p_max_action_cost<=0 THEN RAISE EXCEPTION 'MARKETROUTE_GROWTH_BUDGET_INVALID'; END IF;
 INSERT INTO public.genesis_growth_settings(singleton,enabled,seed_target_company_count,launch_target_company_count,daily_budget_usd,max_action_cost_usd,discovery_batch_size,max_actions_per_run,retry_hours,refresh_days,updated_at)
 VALUES(true,p_enabled,p_seed_target,p_launch_target,p_daily_budget,p_max_action_cost,p_discovery_batch,p_max_actions,p_retry_hours,p_refresh_days,now())
 ON CONFLICT(singleton) DO UPDATE SET enabled=EXCLUDED.enabled,seed_target_company_count=EXCLUDED.seed_target_company_count,launch_target_company_count=EXCLUDED.launch_target_company_count,daily_budget_usd=EXCLUDED.daily_budget_usd,max_action_cost_usd=EXCLUDED.max_action_cost_usd,discovery_batch_size=EXCLUDED.discovery_batch_size,max_actions_per_run=EXCLUDED.max_actions_per_run,retry_hours=EXCLUDED.retry_hours,refresh_days=EXCLUDED.refresh_days,updated_at=now();
 UPDATE public.genesis_growth_industries SET seed_target_company_count=p_seed_target,launch_target_company_count=p_launch_target,updated_at=now() WHERE enabled;
END;$$;

--
-- Name: marketroute_sync_opportunity_v1(uuid, uuid, uuid, uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_sync_opportunity_v1(p_organisation_id uuid, p_campaign_id uuid, p_company_id uuid, p_request_id uuid, p_at timestamp with time zone DEFAULT now()) RETURNS TABLE(opportunity_id uuid, outcome_code text, prior_workflow_state text, resulting_workflow_state text, authority_envelope_fingerprint text, reviewable_now boolean, deduplicated boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_campaign public.campaigns%ROWTYPE; v_opp public.opportunities%ROWTYPE; v_existing public.opportunity_sync_events%ROWTYPE;
  v_env jsonb; v_fp text; v_ready boolean; v_prior text; v_result text; v_outcome text; v_hold boolean:=false; v_event_id uuid;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF p_request_id IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_OPPORTUNITY_SYNC_REQUEST_ID_REQUIRED'; END IF;
  SELECT * INTO v_existing FROM public.opportunity_sync_events WHERE request_id=p_request_id LIMIT 1;
  IF FOUND THEN
    IF v_existing.organisation_id IS DISTINCT FROM p_organisation_id OR v_existing.campaign_id IS DISTINCT FROM p_campaign_id OR v_existing.company_id IS DISTINCT FROM p_company_id THEN RAISE EXCEPTION 'MARKETROUTE_OPPORTUNITY_SYNC_IDEMPOTENCY_COLLISION'; END IF;
    RETURN QUERY SELECT v_existing.opportunity_id,v_existing.outcome_code,v_existing.prior_workflow_state,v_existing.resulting_workflow_state,v_existing.authority_envelope_fingerprint,
      COALESCE(v_existing.resulting_workflow_state='REVIEWABLE' AND (v_existing.authority_envelope_json->>'authorityReady')::boolean,false),true;
    RETURN;
  END IF;
  IF p_at IS NULL OR abs(extract(epoch FROM(now()-p_at)))>300 THEN RAISE EXCEPTION 'MARKETROUTE_OPPORTUNITY_SYNC_TIME_NOT_CURRENT'; END IF;
  SELECT * INTO v_campaign FROM public.campaigns WHERE id=p_campaign_id AND organisation_id=p_organisation_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_OPPORTUNITY_SYNC_CAMPAIGN_SCOPE_MISMATCH'; END IF;
  IF v_campaign.workflow_state<>'ACTIVE' THEN RAISE EXCEPTION 'MARKETROUTE_OPPORTUNITY_SYNC_CAMPAIGN_NOT_ACTIVE'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.organisation_company_scopes s WHERE s.organisation_id=p_organisation_id AND s.campaign_id=p_campaign_id AND s.company_id=p_company_id AND s.scope_kind='CAMPAIGN') THEN RAISE EXCEPTION 'MARKETROUTE_OPPORTUNITY_SYNC_COMPANY_NOT_IN_CAMPAIGN'; END IF;
  v_env:=public.marketroute_authority_envelope_v1(p_organisation_id,p_campaign_id,p_company_id,p_at); v_fp:=public.marketroute_authority_envelope_fingerprint_v1(v_env); v_ready:=COALESCE((v_env->>'authorityReady')::boolean,false);
  SELECT * INTO v_opp FROM public.opportunities WHERE organisation_id=p_organisation_id AND campaign_id=p_campaign_id AND company_id=p_company_id FOR UPDATE;
  IF NOT FOUND THEN
    IF NOT v_ready THEN
      INSERT INTO public.opportunity_sync_events(request_id,organisation_id,campaign_id,company_id,opportunity_id,outcome_code,prior_workflow_state,resulting_workflow_state,authority_envelope_json,authority_envelope_fingerprint,occurred_at)
      VALUES(p_request_id,p_organisation_id,p_campaign_id,p_company_id,NULL,'NOT_MATERIALISED',NULL,NULL,v_env,v_fp,p_at);
      RETURN QUERY SELECT NULL::uuid,'NOT_MATERIALISED'::text,NULL::text,NULL::text,v_fp,false,false; RETURN;
    END IF;
    INSERT INTO public.opportunities(organisation_id,campaign_id,company_id,workflow_state,created_at,updated_at) VALUES(p_organisation_id,p_campaign_id,p_company_id,'RESEARCHING',p_at,p_at) RETURNING * INTO v_opp;
    v_prior:='RESEARCHING'; v_result:='REVIEWABLE'; v_outcome:='MATERIALISED_REVIEWABLE';
    UPDATE public.opportunities SET workflow_state=v_result,updated_at=p_at WHERE id=v_opp.id;
    INSERT INTO public.opportunity_workflow_events(opportunity_id,organisation_id,event_type,prior_workflow_state,resulting_workflow_state,actor_user_id,request_id,reason_code,authority_envelope_json,authority_envelope_fingerprint,occurred_at)
    VALUES(v_opp.id,p_organisation_id,'SYSTEM_REVIEWABILITY',v_prior,v_result,NULL,p_request_id,'AUTHORITY_READY_MATERIALISED',v_env,v_fp,p_at) RETURNING id INTO v_event_id;
  ELSE
    v_prior:=v_opp.workflow_state; v_result:=v_prior; v_outcome:='UNCHANGED';
    IF v_prior='REVIEWABLE' AND NOT v_ready THEN v_result:='RESEARCHING';v_outcome:='BECAME_RESEARCHING';
    ELSIF v_prior='RESEARCHING' AND v_ready THEN
      SELECT EXISTS(
        SELECT 1 FROM public.opportunity_workflow_events e
        WHERE e.opportunity_id=v_opp.id AND e.reason_code='FOUNDER_RETURNED_TO_RESEARCH'
          AND e.occurred_at=(SELECT max(e2.occurred_at) FROM public.opportunity_workflow_events e2 WHERE e2.opportunity_id=v_opp.id)
          AND e.authority_envelope_fingerprint=v_fp
      ) INTO v_hold;
      IF v_hold THEN v_outcome:='FOUNDER_RESEARCH_HOLD'; ELSE v_result:='REVIEWABLE';v_outcome:='BECAME_REVIEWABLE'; END IF;
    END IF;
    IF v_result IS DISTINCT FROM v_prior THEN
      UPDATE public.opportunities SET workflow_state=v_result,updated_at=p_at WHERE id=v_opp.id;
      INSERT INTO public.opportunity_workflow_events(opportunity_id,organisation_id,event_type,prior_workflow_state,resulting_workflow_state,actor_user_id,request_id,reason_code,authority_envelope_json,authority_envelope_fingerprint,occurred_at)
      VALUES(v_opp.id,p_organisation_id,'SYSTEM_REVIEWABILITY',v_prior,v_result,NULL,p_request_id,CASE WHEN v_result='REVIEWABLE' THEN 'AUTHORITY_BECAME_READY' ELSE 'AUTHORITY_NO_LONGER_READY' END,v_env,v_fp,p_at) RETURNING id INTO v_event_id;
    END IF;
  END IF;
  INSERT INTO public.opportunity_sync_events(request_id,organisation_id,campaign_id,company_id,opportunity_id,outcome_code,prior_workflow_state,resulting_workflow_state,authority_envelope_json,authority_envelope_fingerprint,occurred_at)
  VALUES(p_request_id,p_organisation_id,p_campaign_id,p_company_id,v_opp.id,v_outcome,v_prior,v_result,v_env,v_fp,p_at);
  RETURN QUERY SELECT v_opp.id,v_outcome,v_prior,v_result,v_fp,COALESCE(v_result='REVIEWABLE' AND v_ready,false),false;
END $$;

--
-- Name: marketroute_terminate_billing_checkout_v1(uuid, uuid, uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_terminate_billing_checkout_v1(p_attempt_id uuid, p_organisation_id uuid, p_user_id uuid, p_status text, p_reason text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF p_status NOT IN('FAILED','EXPIRED') THEN RAISE EXCEPTION 'MARKETROUTE_BILLING_CHECKOUT_TERMINAL_STATUS_INVALID'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.organisation_memberships m WHERE m.organisation_id=p_organisation_id AND m.user_id=p_user_id AND m.status='ACTIVE' AND m.role='OWNER') THEN RAISE EXCEPTION 'MARKETROUTE_BILLING_OWNER_REQUIRED'; END IF;
  UPDATE public.marketroute_billing_checkout_attempts SET status=p_status,updated_at=now(),metadata_json=metadata_json||jsonb_build_object('terminationReason',left(COALESCE(p_reason,''),300))
  WHERE id=p_attempt_id AND organisation_id=p_organisation_id AND user_id=p_user_id AND status IN('PENDING','REDIRECTED');
  RETURN FOUND;
END;$$;

--
-- Name: marketroute_touch_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_touch_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

--
-- Name: marketroute_truth_claim_facts_v1(uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_truth_claim_facts_v1(p_claim_id uuid, p_reference_time timestamp with time zone) RETURNS TABLE(policy_key text, policy_version text, max_age_days integer, known_support_family_requirement integer, current_support_family_count integer, current_contradiction_family_count integer, stale_family_count integer, temporal_anomaly_count integer, evidence_sufficiency numeric, support_strength numeric, contradiction_strength numeric, evidence_balance numeric, freshness_coverage numeric, truth_state text, next_revalidation_at timestamp with time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_claim public.claims%ROWTYPE;
  v_policy record;
  v_support integer := 0;
  v_contradiction integer := 0;
  v_stale integer := 0;
  v_anomalies integer := 0;
  v_next timestamptz;
  v_current integer := 0;
  v_freshness_sum numeric := 0;
BEGIN
  SELECT * INTO v_claim FROM public.claims WHERE id = p_claim_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_TRUTH_CLAIM_NOT_FOUND'; END IF;
  IF EXISTS (SELECT 1 FROM public.claim_supersessions WHERE prior_claim_id = p_claim_id) THEN
    RAISE EXCEPTION 'MARKETROUTE_TRUTH_SUPERSEDED_CLAIM_FORBIDDEN';
  END IF;

  SELECT * INTO v_policy
  FROM public.marketroute_truth_policy_for_claim_v1(v_claim.subject_type, v_claim.claim_key);
  IF v_policy.policy_key IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_TRUTH_POLICY_NOT_FOUND'; END IF;

  WITH raw AS (
    SELECT
      l.dependence_family_key,
      l.polarity,
      e.observed_at,
      COALESCE(e.origin_published_at, s.published_at, e.observed_at) AS effective_origin,
      (e.observed_at > p_reference_time + interval '5 minutes'
       OR COALESCE(e.origin_published_at, s.published_at, e.observed_at) > p_reference_time + interval '5 minutes') AS temporal_anomaly
    FROM public.claim_evidence_links l
    JOIN public.evidence_items e ON e.id = l.evidence_item_id
    JOIN public.source_acquisitions a ON a.id = e.acquisition_id
    JOIN public.source_records s ON s.id = a.source_id
    WHERE l.claim_id = p_claim_id
  ), family AS (
    SELECT
      dependence_family_key,
      bool_or(NOT temporal_anomaly
              AND p_reference_time - effective_origin < make_interval(days => v_policy.max_age_days)
              AND polarity = 'SUPPORTS') AS current_support,
      bool_or(NOT temporal_anomaly
              AND p_reference_time - effective_origin < make_interval(days => v_policy.max_age_days)
              AND polarity = 'CONTRADICTS') AS current_contradiction,
      bool_or(NOT temporal_anomaly
              AND p_reference_time - effective_origin >= make_interval(days => v_policy.max_age_days)) AS has_stale,
      MAX(
        CASE
          WHEN NOT temporal_anomaly
               AND p_reference_time - effective_origin < make_interval(days => v_policy.max_age_days)
          THEN GREATEST(0::numeric, LEAST(1::numeric,
            1::numeric - (
              extract(epoch FROM (p_reference_time - effective_origin))
              / NULLIF(v_policy.max_age_days::numeric * 86400::numeric, 0)
            )
          ))
          ELSE NULL
        END
      ) AS current_freshness
    FROM raw
    GROUP BY dependence_family_key
  )
  SELECT
    COUNT(*) FILTER (WHERE current_support AND NOT current_contradiction)::integer,
    COUNT(*) FILTER (WHERE current_contradiction)::integer,
    COUNT(*) FILTER (WHERE NOT current_support AND NOT current_contradiction AND has_stale)::integer,
    COALESCE(SUM(current_freshness) FILTER (WHERE current_support OR current_contradiction), 0::numeric)
  INTO v_support, v_contradiction, v_stale, v_freshness_sum
  FROM family;

  SELECT COUNT(*)::integer
  INTO v_anomalies
  FROM public.claim_evidence_links l
  JOIN public.evidence_items e ON e.id = l.evidence_item_id
  JOIN public.source_acquisitions a ON a.id = e.acquisition_id
  JOIN public.source_records s ON s.id = a.source_id
  WHERE l.claim_id = p_claim_id
    AND (
      e.observed_at > p_reference_time + interval '5 minutes'
      OR COALESCE(e.origin_published_at, s.published_at, e.observed_at) > p_reference_time + interval '5 minutes'
    );

  SELECT MIN(COALESCE(e.origin_published_at, s.published_at, e.observed_at) + make_interval(days => v_policy.max_age_days))
  INTO v_next
  FROM public.claim_evidence_links l
  JOIN public.evidence_items e ON e.id = l.evidence_item_id
  JOIN public.source_acquisitions a ON a.id = e.acquisition_id
  JOIN public.source_records s ON s.id = a.source_id
  WHERE l.claim_id = p_claim_id
    AND e.observed_at <= p_reference_time + interval '5 minutes'
    AND COALESCE(e.origin_published_at, s.published_at, e.observed_at) <= p_reference_time + interval '5 minutes'
    AND p_reference_time - COALESCE(e.origin_published_at, s.published_at, e.observed_at) < make_interval(days => v_policy.max_age_days);

  v_current := v_support + v_contradiction;

  policy_key := v_policy.policy_key;
  policy_version := v_policy.policy_version;
  max_age_days := v_policy.max_age_days;
  known_support_family_requirement := v_policy.known_support_family_requirement;
  current_support_family_count := v_support;
  current_contradiction_family_count := v_contradiction;
  stale_family_count := v_stale;
  temporal_anomaly_count := v_anomalies;
  evidence_sufficiency := LEAST(1::numeric, v_current::numeric / v_policy.known_support_family_requirement::numeric);
  support_strength := LEAST(1::numeric, v_support::numeric / v_policy.known_support_family_requirement::numeric);
  contradiction_strength := LEAST(1::numeric, v_contradiction::numeric / v_policy.known_support_family_requirement::numeric);
  evidence_balance := CASE WHEN v_current = 0 THEN 0::numeric ELSE (v_support - v_contradiction)::numeric / v_current::numeric END;
  freshness_coverage := CASE WHEN v_current = 0 THEN 0::numeric ELSE v_freshness_sum / v_current::numeric END;
  truth_state := CASE
    WHEN v_contradiction > 0 THEN 'CONTRADICTED'
    WHEN v_support >= v_policy.known_support_family_requirement THEN 'KNOWN'
    WHEN v_support >= 1 THEN 'SUPPORTED'
    WHEN v_stale > 0 THEN 'STALE'
    ELSE 'UNRESOLVED'
  END;
  next_revalidation_at := v_next;
  RETURN NEXT;
END;
$$;

--
-- Name: marketroute_truth_context_fingerprint_v1(uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_truth_context_fingerprint_v1(p_claim_id uuid, p_reference_time timestamp with time zone) RETURNS text
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_claim public.claims%ROWTYPE;
  v_policy record;
  v_evidence_identity text;
  v_reference_text text;
  v_proposition_fingerprint text;
BEGIN
  SELECT * INTO v_claim FROM public.claims WHERE id = p_claim_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_TRUTH_CLAIM_NOT_FOUND'; END IF;
  IF EXISTS (SELECT 1 FROM public.claim_supersessions WHERE prior_claim_id = p_claim_id) THEN
    RAISE EXCEPTION 'MARKETROUTE_TRUTH_SUPERSEDED_CLAIM_FORBIDDEN';
  END IF;

  SELECT * INTO v_policy
  FROM public.marketroute_truth_policy_for_claim_v1(v_claim.subject_type, v_claim.claim_key);
  IF v_policy.policy_key IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_TRUTH_POLICY_NOT_FOUND'; END IF;

  v_reference_text := to_char(p_reference_time AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"');
  v_proposition_fingerprint := public.marketroute_truth_proposition_fingerprint_v1(p_claim_id);

  SELECT COALESCE(string_agg(
    concat_ws(':',
      e.evidence_fingerprint,
      l.polarity,
      l.dependence_family_key,
      to_char(e.observed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
      COALESCE(to_char(e.origin_published_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'), '-'),
      COALESCE(to_char(s.published_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'), '-')
    ),
    ';' ORDER BY e.evidence_fingerprint, l.polarity, l.dependence_family_key
  ), '')
  INTO v_evidence_identity
  FROM public.claim_evidence_links l
  JOIN public.evidence_items e ON e.id = l.evidence_item_id
  JOIN public.source_acquisitions a ON a.id = e.acquisition_id
  JOIN public.source_records s ON s.id = a.source_id
  WHERE l.claim_id = p_claim_id;

  RETURN encode(extensions.digest(
    concat_ws('|',
      'MRV2-TRUTH-CONTEXT-1.0.0',
      v_claim.claim_fingerprint,
      v_proposition_fingerprint,
      v_policy.policy_key,
      v_policy.policy_version,
      v_policy.max_age_days::text,
      v_policy.known_support_family_requirement::text,
      v_reference_text,
      v_evidence_identity
    ), 'sha256'
  ), 'hex');
END;
$$;

--
-- Name: marketroute_truth_policy_for_claim_v1(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_truth_policy_for_claim_v1(p_subject_type text, p_claim_key text) RETURNS TABLE(policy_key text, policy_version text, max_age_days integer, known_support_family_requirement integer)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  SELECT r.policy_key, r.policy_version, r.max_age_days, r.known_support_family_requirement
  FROM public.truth_claim_policy_bindings b
  JOIN public.truth_claim_policy_registry r ON r.policy_key = b.policy_key
  WHERE r.active = true
    AND (b.subject_type = p_subject_type OR b.subject_type = '*')
    AND (b.claim_key = p_claim_key OR b.claim_key = '*')
  ORDER BY
    CASE WHEN b.subject_type = p_subject_type THEN 0 ELSE 1 END,
    CASE WHEN b.claim_key = p_claim_key THEN 0 ELSE 1 END,
    b.precedence
  LIMIT 1;
$$;

--
-- Name: marketroute_truth_proposition_fingerprint_v1(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_truth_proposition_fingerprint_v1(p_claim_id uuid) RETURNS text
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_claim public.claims%ROWTYPE;
BEGIN
  SELECT * INTO v_claim FROM public.claims WHERE id = p_claim_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_TRUTH_CLAIM_NOT_FOUND'; END IF;
  RETURN encode(extensions.digest(concat_ws('|',
    'MRV2-TRUTH-PROPOSITION-1.0.0',
    v_claim.subject_type,
    v_claim.subject_id::text,
    v_claim.claim_key,
    v_claim.predicate,
    v_claim.object_json::text,
    COALESCE(v_claim.canonical_value_text, '-')
  ), 'sha256'), 'hex');
END;
$$;

--
-- Name: marketroute_validate_claim_evidence_scope(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_validate_claim_evidence_scope() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_claim_org uuid;
  v_claim_subject_type text;
  v_claim_subject_id uuid;
  v_evidence_org uuid;
  v_evidence_subject_type text;
  v_evidence_subject_id uuid;
  v_dependence_family_key text;
BEGIN
  SELECT tenant_scope_organisation_id, subject_type, subject_id
  INTO v_claim_org, v_claim_subject_type, v_claim_subject_id
  FROM public.claims WHERE id = NEW.claim_id;

  SELECT tenant_scope_organisation_id, subject_type, subject_id, dependence_family_key
  INTO v_evidence_org, v_evidence_subject_type, v_evidence_subject_id, v_dependence_family_key
  FROM public.evidence_items
  WHERE id = NEW.evidence_item_id;

  IF v_claim_subject_type IS DISTINCT FROM v_evidence_subject_type
     OR v_claim_subject_id IS DISTINCT FROM v_evidence_subject_id THEN
    RAISE EXCEPTION 'MARKETROUTE_CLAIM_EVIDENCE_SUBJECT_MISMATCH';
  END IF;
  IF v_claim_org IS NULL AND v_evidence_org IS NOT NULL THEN
    RAISE EXCEPTION 'MARKETROUTE_GLOBAL_CLAIM_CANNOT_USE_PRIVATE_EVIDENCE';
  END IF;
  IF v_claim_org IS NOT NULL AND v_evidence_org IS NOT NULL AND v_claim_org <> v_evidence_org THEN
    RAISE EXCEPTION 'MARKETROUTE_CLAIM_EVIDENCE_TENANT_MISMATCH';
  END IF;
  IF NEW.dependence_family_key IS DISTINCT FROM v_dependence_family_key THEN
    RAISE EXCEPTION 'MARKETROUTE_DEPENDENCE_FAMILY_MUST_INHERIT_EVIDENCE';
  END IF;
  RETURN NEW;
END;
$$;

--
-- Name: marketroute_validate_claim_supersession_scope(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_validate_claim_supersession_scope() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_prior_org uuid;
  v_prior_subject_type text;
  v_prior_subject_id uuid;
  v_prior_claim_key text;
  v_replacement_org uuid;
  v_replacement_subject_type text;
  v_replacement_subject_id uuid;
  v_replacement_claim_key text;
BEGIN
  SELECT tenant_scope_organisation_id, subject_type, subject_id, claim_key
  INTO v_prior_org, v_prior_subject_type, v_prior_subject_id, v_prior_claim_key
  FROM public.claims
  WHERE id = NEW.prior_claim_id;

  IF NEW.replacement_claim_id IS NOT NULL THEN
    SELECT tenant_scope_organisation_id, subject_type, subject_id, claim_key
    INTO v_replacement_org, v_replacement_subject_type, v_replacement_subject_id, v_replacement_claim_key
    FROM public.claims
    WHERE id = NEW.replacement_claim_id;

    IF v_prior_org IS DISTINCT FROM v_replacement_org
       OR v_prior_subject_type IS DISTINCT FROM v_replacement_subject_type
       OR v_prior_subject_id IS DISTINCT FROM v_replacement_subject_id
       OR v_prior_claim_key IS DISTINCT FROM v_replacement_claim_key THEN
      RAISE EXCEPTION 'MARKETROUTE_CLAIM_SUPERSESSION_SCOPE_MISMATCH';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

--
-- Name: marketroute_workspace_activation_status_transition_v1(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_workspace_activation_status_transition_v1() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_temp'
    AS $$
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
$$;

--
-- Name: marketroute_workspace_activation_status_v1(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_workspace_activation_status_v1(p_organisation_id uuid, p_actor_user_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_status text;v_error text;BEGIN
  IF p_actor_user_id IS NULL OR NOT public.marketroute_is_org_member(p_organisation_id, p_actor_user_id) THEN RAISE EXCEPTION 'MARKETROUTE_WORKSPACE_ACCESS_DENIED';END IF;
  SELECT status,last_error_code INTO v_status,v_error FROM public.workspace_activation_jobs WHERE organisation_id=p_organisation_id;
  IF v_status IS NULL THEN
    IF EXISTS(SELECT 1 FROM public.campaigns WHERE organisation_id=p_organisation_id AND workflow_state<>'ARCHIVED') THEN RETURN jsonb_build_object('status','NOT_REQUIRED','lastErrorCode',NULL);END IF;
    RETURN jsonb_build_object('status','NOT_SUBMITTED','lastErrorCode',NULL);
  END IF;
  RETURN jsonb_build_object('status',v_status,'lastErrorCode',v_error);
END;$$;

--
-- Name: marketroute_workspace_activation_status_v2(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_workspace_activation_status_v2(p_organisation_id uuid, p_actor_user_id uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_job public.workspace_activation_jobs%ROWTYPE;v_campaign_id uuid;v_campaign_name text;
BEGIN
  IF p_actor_user_id IS NULL OR NOT public.marketroute_is_org_member(p_organisation_id, p_actor_user_id) THEN
    RAISE EXCEPTION 'MARKETROUTE_WORKSPACE_ACCESS_DENIED';
  END IF;
  SELECT * INTO v_job
  FROM public.workspace_activation_jobs j
  WHERE j.organisation_id=p_organisation_id
  ORDER BY j.created_at DESC,j.id DESC LIMIT 1;
  IF NOT FOUND THEN
    SELECT id,name INTO v_campaign_id,v_campaign_name FROM public.campaigns
    WHERE organisation_id=p_organisation_id AND workflow_state<>'ARCHIVED'
    ORDER BY updated_at DESC,id LIMIT 1;
    IF v_campaign_id IS NOT NULL THEN
      RETURN jsonb_build_object('status','NOT_REQUIRED','lastErrorCode',NULL,'campaignId',v_campaign_id,'campaignName',v_campaign_name,'stage','READY','progress',100,'stageDetail','{}'::jsonb,'activationKind',NULL,'updatedAt',NULL);
    END IF;
    RETURN jsonb_build_object('status','NOT_SUBMITTED','lastErrorCode',NULL,'campaignId',NULL,'campaignName',NULL,'stage','QUEUED','progress',0,'stageDetail','{}'::jsonb,'activationKind',NULL,'updatedAt',NULL);
  END IF;
  IF nullif(v_job.result_json->>'campaignId','') IS NOT NULL THEN
    BEGIN v_campaign_id:=(v_job.result_json->>'campaignId')::uuid; EXCEPTION WHEN invalid_text_representation THEN v_campaign_id:=NULL; END;
  END IF;
  v_campaign_name:=nullif(btrim(v_job.campaign_name),'');
  IF v_campaign_id IS NOT NULL AND v_campaign_name IS NULL THEN
    SELECT name INTO v_campaign_name FROM public.campaigns WHERE id=v_campaign_id AND organisation_id=p_organisation_id;
  END IF;
  RETURN jsonb_build_object(
    'status',v_job.status,'lastErrorCode',v_job.last_error_code,'campaignId',v_campaign_id,
    'campaignName',v_campaign_name,'stage',v_job.activation_stage,'progress',v_job.activation_progress,
    'stageDetail',v_job.activation_stage_detail_json,'activationKind',v_job.activation_kind,'updatedAt',v_job.updated_at
  );
END;
$$;

--
-- Name: marketroute_workspace_commercial_access_v1(uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.marketroute_workspace_commercial_access_v1(p_organisation_id uuid, p_at timestamp with time zone DEFAULT now()) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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
$$;

SET default_tablespace = '';

SET default_table_access_method = heap;

-- AWS V0 internal user identity anchor. Cognito/external identity mapping is Build 5.
CREATE TABLE public.marketroute_users (id uuid DEFAULT gen_random_uuid() NOT NULL,status text DEFAULT 'ACTIVE'::text NOT NULL,created_at timestamp with time zone DEFAULT now() NOT NULL,updated_at timestamp with time zone DEFAULT now() NOT NULL,CONSTRAINT marketroute_users_status_check CHECK ((status = ANY (ARRAY['ACTIVE'::text,'SUSPENDED'::text,'DISABLED'::text]))));
ALTER TABLE ONLY public.marketroute_users ADD CONSTRAINT marketroute_users_pkey PRIMARY KEY (id);
CREATE INDEX marketroute_users_status_idx ON public.marketroute_users USING btree (status);

--
-- Name: ai_usage_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_usage_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organisation_id uuid,
    campaign_id uuid,
    reasoning_run_id uuid,
    provider text NOT NULL,
    model text NOT NULL,
    request_kind text NOT NULL,
    input_tokens bigint,
    output_tokens bigint,
    cost_usd numeric(18,8),
    latency_ms integer,
    status text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    metadata_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT ai_usage_events_check CHECK (((campaign_id IS NULL) OR (organisation_id IS NOT NULL))),
    CONSTRAINT ai_usage_events_cost_usd_check CHECK (((cost_usd IS NULL) OR (cost_usd >= (0)::numeric))),
    CONSTRAINT ai_usage_events_input_tokens_check CHECK (((input_tokens IS NULL) OR (input_tokens >= 0))),
    CONSTRAINT ai_usage_events_latency_ms_check CHECK (((latency_ms IS NULL) OR (latency_ms >= 0))),
    CONSTRAINT ai_usage_events_metadata_json_check CHECK ((jsonb_typeof(metadata_json) = 'object'::text)),
    CONSTRAINT ai_usage_events_output_tokens_check CHECK (((output_tokens IS NULL) OR (output_tokens >= 0))),
    CONSTRAINT ai_usage_events_status_check CHECK ((status = ANY (ARRAY['SUCCEEDED'::text, 'FAILED'::text, 'TIMED_OUT'::text, 'CANCELLED'::text])))
);

--
-- Name: anonymous_discovery_extension_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.anonymous_discovery_extension_jobs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    run_id uuid NOT NULL,
    organisation_id uuid NOT NULL,
    campaign_id uuid NOT NULL,
    status text DEFAULT 'PENDING'::text NOT NULL,
    attempt_count integer DEFAULT 0 NOT NULL,
    available_at timestamp with time zone DEFAULT now() NOT NULL,
    worker_id text,
    lease_expires_at timestamp with time zone,
    last_error_code text,
    result_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    cycle_policy_version integer DEFAULT 1 NOT NULL,
    CONSTRAINT anonymous_discovery_extension_jobs_attempt_count_check CHECK (((attempt_count >= 0) AND (attempt_count <= 3))),
    CONSTRAINT anonymous_discovery_extension_jobs_cycle_policy_version_check CHECK (((cycle_policy_version >= 1) AND (cycle_policy_version <= 4))),
    CONSTRAINT anonymous_discovery_extension_jobs_result_json_check CHECK ((jsonb_typeof(result_json) = 'object'::text)),
    CONSTRAINT anonymous_discovery_extension_jobs_status_check CHECK ((status = ANY (ARRAY['PENDING'::text, 'RUNNING'::text, 'DEFERRED'::text, 'SUCCEEDED'::text, 'EXHAUSTED'::text, 'FAILED'::text])))
);

--
-- Name: anonymous_discovery_opportunity_unlocks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.anonymous_discovery_opportunity_unlocks (
    run_id uuid NOT NULL,
    opportunity_id uuid NOT NULL,
    company_id uuid NOT NULL,
    ordinal integer NOT NULL,
    unlocked_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT anonymous_discovery_opportunity_unlocks_ordinal_check CHECK (((ordinal >= 1) AND (ordinal <= 8)))
);

--
-- Name: anonymous_discovery_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.anonymous_discovery_runs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    browser_key_hash text NOT NULL,
    ip_hash text NOT NULL,
    organisation_id uuid NOT NULL,
    seller_business_id uuid NOT NULL,
    activation_job_id uuid NOT NULL,
    company_name text NOT NULL,
    website_url text NOT NULL,
    lifetime_budget_usd numeric(18,8) NOT NULL,
    target_count integer NOT NULL,
    research_expires_at timestamp with time zone NOT NULL,
    status text DEFAULT 'ACTIVE'::text NOT NULL,
    claimed_by_user_id uuid,
    claimed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    original_campaign_id uuid,
    objective_text text,
    target_market_text text,
    CONSTRAINT anonymous_discovery_runs_browser_key_hash_check CHECK ((browser_key_hash ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT anonymous_discovery_runs_check CHECK ((research_expires_at > created_at)),
    CONSTRAINT anonymous_discovery_runs_check1 CHECK ((((status = 'CLAIMED'::text) AND (claimed_by_user_id IS NOT NULL) AND (claimed_at IS NOT NULL)) OR (status <> 'CLAIMED'::text))),
    CONSTRAINT anonymous_discovery_runs_company_name_check CHECK (((length(btrim(company_name)) >= 2) AND (length(btrim(company_name)) <= 160))),
    CONSTRAINT anonymous_discovery_runs_ip_hash_check CHECK ((ip_hash ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT anonymous_discovery_runs_lifetime_budget_usd_check CHECK (((lifetime_budget_usd >= 0.50) AND (lifetime_budget_usd <= 25.00))),
    CONSTRAINT anonymous_discovery_runs_status_check CHECK ((status = ANY (ARRAY['ACTIVE'::text, 'CLAIMED'::text, 'EXPIRED'::text, 'BLOCKED'::text]))),
    CONSTRAINT anonymous_discovery_runs_target_count_check CHECK (((target_count >= 8) AND (target_count <= 20))),
    CONSTRAINT anonymous_discovery_runs_website_url_check CHECK ((website_url ~ '^https?://'::text))
);

--
-- Name: audit_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organisation_id uuid,
    actor_type text NOT NULL,
    actor_id text,
    event_type text NOT NULL,
    subject_type text,
    subject_id uuid,
    details_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT audit_events_actor_type_check CHECK ((actor_type = ANY (ARRAY['USER'::text, 'SYSTEM'::text, 'SCHEDULER'::text, 'MIGRATION'::text]))),
    CONSTRAINT audit_events_details_json_check CHECK ((jsonb_typeof(details_json) = 'object'::text))
);

--
-- Name: authority_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.authority_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    authority_record_id uuid NOT NULL,
    event_type text NOT NULL,
    writer_key text NOT NULL,
    reason_code text,
    metadata_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT authority_events_event_type_check CHECK ((event_type = ANY (ARRAY['GRANTED'::text, 'REVALIDATED'::text, 'SUPERSEDED'::text, 'INVALIDATED'::text, 'REVOKED'::text, 'EXPIRED'::text]))),
    CONSTRAINT authority_events_metadata_json_check CHECK ((jsonb_typeof(metadata_json) = 'object'::text))
);

--
-- Name: authority_records; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.authority_records (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organisation_id uuid NOT NULL,
    campaign_id uuid,
    reasoning_run_id uuid NOT NULL,
    reasoning_artifact_id uuid NOT NULL,
    authority_stage text NOT NULL,
    subject_type text NOT NULL,
    subject_id uuid NOT NULL,
    decision_code text NOT NULL,
    writer_key text NOT NULL,
    writer_version text NOT NULL,
    input_fingerprint text NOT NULL,
    authority_fingerprint text NOT NULL,
    parent_authority_fingerprints jsonb DEFAULT '[]'::jsonb NOT NULL,
    payload_json jsonb NOT NULL,
    valid_from timestamp with time zone NOT NULL,
    valid_until timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT authority_records_authority_fingerprint_check CHECK ((authority_fingerprint ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT authority_records_authority_stage_check CHECK ((authority_stage = ANY (ARRAY['COMMERCIAL_REALITY'::text, 'ROUTE_AUTHORITY'::text, 'CONTACT_AUTHORITY'::text, 'EXECUTION_PERMISSION'::text]))),
    CONSTRAINT authority_records_check CHECK ((valid_until > valid_from)),
    CONSTRAINT authority_records_check1 CHECK (((campaign_id IS NULL) OR (organisation_id IS NOT NULL))),
    CONSTRAINT authority_records_input_fingerprint_check CHECK ((input_fingerprint ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT authority_records_parent_authority_fingerprints_check CHECK ((jsonb_typeof(parent_authority_fingerprints) = 'array'::text)),
    CONSTRAINT authority_records_payload_json_check CHECK ((jsonb_typeof(payload_json) = 'object'::text))
);

--
-- Name: authority_writer_registry; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.authority_writer_registry (
    writer_key text NOT NULL,
    authority_stage text NOT NULL,
    writer_version text NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    registered_by_build integer NOT NULL,
    metadata_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    registered_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT authority_writer_registry_authority_stage_check CHECK ((authority_stage = ANY (ARRAY['COMMERCIAL_REALITY'::text, 'ROUTE_AUTHORITY'::text, 'CONTACT_AUTHORITY'::text, 'EXECUTION_PERMISSION'::text]))),
    CONSTRAINT authority_writer_registry_metadata_json_check CHECK ((jsonb_typeof(metadata_json) = 'object'::text)),
    CONSTRAINT authority_writer_registry_registered_by_build_check CHECK ((registered_by_build >= 3))
);

--
-- Name: background_job_attempts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.background_job_attempts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    job_id uuid NOT NULL,
    scheduler_run_id uuid,
    attempt_number integer NOT NULL,
    status text NOT NULL,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    completed_at timestamp with time zone,
    error_code text,
    telemetry_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT background_job_attempts_attempt_number_check CHECK ((attempt_number > 0)),
    CONSTRAINT background_job_attempts_status_check CHECK ((status = ANY (ARRAY['RUNNING'::text, 'SUCCEEDED'::text, 'FAILED'::text, 'TIMED_OUT'::text, 'ABORTED'::text]))),
    CONSTRAINT background_job_attempts_telemetry_json_check CHECK ((jsonb_typeof(telemetry_json) = 'object'::text))
);

--
-- Name: background_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.background_jobs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organisation_id uuid,
    campaign_id uuid,
    job_type text NOT NULL,
    dedupe_key text NOT NULL,
    status text DEFAULT 'PENDING'::text NOT NULL,
    priority integer DEFAULT 100 NOT NULL,
    payload_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    available_at timestamp with time zone DEFAULT now() NOT NULL,
    reserved_by_run_id uuid,
    reserved_at timestamp with time zone,
    attempt_count integer DEFAULT 0 NOT NULL,
    max_attempts integer DEFAULT 5 NOT NULL,
    last_error_code text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT background_jobs_attempt_count_check CHECK ((attempt_count >= 0)),
    CONSTRAINT background_jobs_check CHECK (((campaign_id IS NULL) OR (organisation_id IS NOT NULL))),
    CONSTRAINT background_jobs_max_attempts_check CHECK (((max_attempts >= 1) AND (max_attempts <= 50))),
    CONSTRAINT background_jobs_payload_json_check CHECK ((jsonb_typeof(payload_json) = 'object'::text)),
    CONSTRAINT background_jobs_status_check CHECK ((status = ANY (ARRAY['PENDING'::text, 'RESERVED'::text, 'RUNNING'::text, 'SUCCEEDED'::text, 'FAILED'::text, 'CANCELLED'::text, 'DEFERRED'::text])))
);

--
-- Name: campaign_engagement_policy_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.campaign_engagement_policy_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    request_id uuid NOT NULL,
    organisation_id uuid NOT NULL,
    campaign_id uuid NOT NULL,
    actor_user_id uuid NOT NULL,
    policy_mode text NOT NULL,
    policy_version text NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT campaign_engagement_policy_events_policy_mode_check CHECK ((policy_mode = ANY (ARRAY['HUMAN_ONLY'::text, 'AUTOPILOT'::text]))),
    CONSTRAINT campaign_engagement_policy_events_policy_version_check CHECK ((policy_version = 'MRV2-ENGAGEMENT-POLICY-1.0.0'::text))
);

--
-- Name: campaign_seller_context_selections; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.campaign_seller_context_selections (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organisation_id uuid NOT NULL,
    campaign_id uuid NOT NULL,
    seller_business_id uuid NOT NULL,
    genome_snapshot_id uuid NOT NULL,
    objective_key text NOT NULL,
    selection_request_id uuid NOT NULL,
    input_fingerprint text NOT NULL,
    semantic_context_fingerprint text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT campaign_seller_context_sele_semantic_context_fingerprint_check CHECK ((semantic_context_fingerprint ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT campaign_seller_context_selections_input_fingerprint_check CHECK ((input_fingerprint ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT campaign_seller_context_selections_objective_key_check CHECK ((objective_key ~ '^[a-z0-9][a-z0-9._-]{0,79}$'::text))
);

--
-- Name: campaign_workflow_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.campaign_workflow_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organisation_id uuid NOT NULL,
    campaign_id uuid NOT NULL,
    actor_user_id uuid NOT NULL,
    action text NOT NULL,
    prior_workflow_state text NOT NULL,
    resulting_workflow_state text NOT NULL,
    metadata_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT campaign_workflow_events_action_check CHECK ((action = ANY (ARRAY['PAUSE'::text, 'RESUME'::text, 'ARCHIVE'::text]))),
    CONSTRAINT campaign_workflow_events_metadata_json_check CHECK ((jsonb_typeof(metadata_json) = 'object'::text)),
    CONSTRAINT campaign_workflow_events_prior_workflow_state_check CHECK ((prior_workflow_state = ANY (ARRAY['DRAFT'::text, 'ACTIVE'::text, 'PAUSED'::text, 'ARCHIVED'::text]))),
    CONSTRAINT campaign_workflow_events_resulting_workflow_state_check CHECK ((resulting_workflow_state = ANY (ARRAY['ACTIVE'::text, 'PAUSED'::text, 'ARCHIVED'::text])))
);

--
-- Name: campaigns; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.campaigns (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organisation_id uuid NOT NULL,
    seller_business_id uuid NOT NULL,
    name text NOT NULL,
    workflow_state text DEFAULT 'DRAFT'::text NOT NULL,
    objective_text text,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    activation_job_id uuid,
    CONSTRAINT campaigns_name_check CHECK (((length(btrim(name)) >= 1) AND (length(btrim(name)) <= 200))),
    CONSTRAINT campaigns_workflow_state_check CHECK ((workflow_state = ANY (ARRAY['DRAFT'::text, 'ACTIVE'::text, 'PAUSED'::text, 'ARCHIVED'::text])))
);

--
-- Name: claim_evidence_links; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.claim_evidence_links (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    claim_id uuid NOT NULL,
    evidence_item_id uuid NOT NULL,
    polarity text NOT NULL,
    dependence_family_key text NOT NULL,
    link_method text NOT NULL,
    link_version text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT claim_evidence_links_dependence_family_key_check CHECK ((length(btrim(dependence_family_key)) > 0)),
    CONSTRAINT claim_evidence_links_link_method_check CHECK ((link_method = ANY (ARRAY['DETERMINISTIC'::text, 'AI_EXTRACTED'::text, 'USER_PROVIDED'::text, 'MIGRATED'::text]))),
    CONSTRAINT claim_evidence_links_polarity_check CHECK ((polarity = ANY (ARRAY['SUPPORTS'::text, 'CONTRADICTS'::text])))
);

--
-- Name: claim_supersessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.claim_supersessions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    prior_claim_id uuid NOT NULL,
    replacement_claim_id uuid,
    reason_code text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT claim_supersessions_check CHECK (((replacement_claim_id IS NULL) OR (replacement_claim_id <> prior_claim_id)))
);

--
-- Name: claims; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.claims (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_scope_organisation_id uuid,
    subject_type text NOT NULL,
    subject_id uuid NOT NULL,
    claim_key text NOT NULL,
    predicate text NOT NULL,
    object_json jsonb NOT NULL,
    canonical_value_text text,
    claim_fingerprint text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    fingerprint_version text NOT NULL,
    CONSTRAINT claims_claim_fingerprint_check CHECK ((claim_fingerprint ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT claims_fingerprint_version_nonempty CHECK ((length(btrim(fingerprint_version)) > 0)),
    CONSTRAINT claims_subject_type_check CHECK ((subject_type = ANY (ARRAY['COMPANY'::text, 'PERSON'::text, 'SELLER_BUSINESS'::text, 'CAMPAIGN'::text, 'RELATIONSHIP'::text, 'CHANNEL'::text, 'OTHER'::text])))
);

--
-- Name: commercial_graph_nodes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commercial_graph_nodes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_scope_organisation_id uuid,
    node_kind text NOT NULL,
    company_id uuid,
    person_id uuid,
    stable_key text,
    label text,
    access_point_kind text,
    canonical_value text,
    node_fingerprint text NOT NULL,
    canonical_version text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT commercial_graph_nodes_access_point_kind_check CHECK (((access_point_kind IS NULL) OR (access_point_kind = ANY (ARRAY['CONTACT_FORM'::text, 'GENERIC_EMAIL'::text, 'SWITCHBOARD'::text, 'DEPARTMENT_EMAIL'::text, 'DEPARTMENT_FORM'::text, 'PERSONAL_EMAIL'::text, 'LINKEDIN'::text, 'PERSONAL_PHONE'::text, 'OTHER'::text])))),
    CONSTRAINT commercial_graph_nodes_check CHECK ((((node_kind = 'COMPANY'::text) AND (company_id IS NOT NULL) AND (person_id IS NULL) AND (stable_key IS NULL) AND (access_point_kind IS NULL) AND (canonical_value IS NULL) AND (tenant_scope_organisation_id IS NULL)) OR ((node_kind = 'PERSON'::text) AND (person_id IS NOT NULL) AND (company_id IS NULL) AND (stable_key IS NULL) AND (access_point_kind IS NULL) AND (canonical_value IS NULL) AND (tenant_scope_organisation_id IS NULL)) OR ((node_kind = ANY (ARRAY['ORGANISATIONAL_UNIT'::text, 'TECHNOLOGY'::text])) AND (company_id IS NULL) AND (person_id IS NULL) AND (stable_key IS NOT NULL) AND (access_point_kind IS NULL) AND (canonical_value IS NULL)) OR ((node_kind = 'ACCESS_POINT'::text) AND (company_id IS NULL) AND (person_id IS NULL) AND (stable_key IS NOT NULL) AND (access_point_kind IS NOT NULL) AND (canonical_value IS NOT NULL)))),
    CONSTRAINT commercial_graph_nodes_node_fingerprint_check CHECK ((node_fingerprint ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT commercial_graph_nodes_node_kind_check CHECK ((node_kind = ANY (ARRAY['COMPANY'::text, 'PERSON'::text, 'ORGANISATIONAL_UNIT'::text, 'TECHNOLOGY'::text, 'ACCESS_POINT'::text])))
);

--
-- Name: commercial_reality_boundary_constitutions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commercial_reality_boundary_constitutions (
    constitution_key text NOT NULL,
    constitution_version text NOT NULL,
    reality_class text NOT NULL,
    mandatory_boundary_keys jsonb NOT NULL,
    max_authority_hours integer NOT NULL,
    accepted_truth_states jsonb NOT NULL,
    active boolean DEFAULT true NOT NULL,
    metadata_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    registered_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT commercial_reality_boundary_const_mandatory_boundary_keys_check CHECK ((jsonb_typeof(mandatory_boundary_keys) = 'array'::text)),
    CONSTRAINT commercial_reality_boundary_constit_accepted_truth_states_check CHECK ((jsonb_typeof(accepted_truth_states) = 'array'::text)),
    CONSTRAINT commercial_reality_boundary_constitut_max_authority_hours_check CHECK (((max_authority_hours >= 1) AND (max_authority_hours <= 168))),
    CONSTRAINT commercial_reality_boundary_constitutions_metadata_json_check CHECK ((jsonb_typeof(metadata_json) = 'object'::text))
);

--
-- Name: commercial_reality_r4_records; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commercial_reality_r4_records (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organisation_id uuid NOT NULL,
    campaign_id uuid NOT NULL,
    company_id uuid NOT NULL,
    authority_record_id uuid NOT NULL,
    seller_context_selection_id uuid NOT NULL,
    target_truth_entity_snapshot_id uuid NOT NULL,
    constraint_truth_snapshot_map jsonb DEFAULT '{}'::jsonb NOT NULL,
    boundary_constitution_key text NOT NULL,
    boundary_constitution_version text NOT NULL,
    reality_class text NOT NULL,
    engine_version text NOT NULL,
    semantics_version text NOT NULL,
    decision_code text NOT NULL,
    boundaries_json jsonb NOT NULL,
    input_fingerprint text NOT NULL,
    authority_fingerprint text NOT NULL,
    reference_time timestamp with time zone NOT NULL,
    next_revalidation_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT commercial_reality_r4_record_constraint_truth_snapshot_ma_check CHECK ((jsonb_typeof(constraint_truth_snapshot_map) = 'object'::text)),
    CONSTRAINT commercial_reality_r4_records_authority_fingerprint_check CHECK ((authority_fingerprint ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT commercial_reality_r4_records_boundaries_json_check CHECK ((jsonb_typeof(boundaries_json) = 'array'::text)),
    CONSTRAINT commercial_reality_r4_records_check CHECK ((next_revalidation_at > reference_time)),
    CONSTRAINT commercial_reality_r4_records_decision_code_check CHECK ((decision_code = ANY (ARRAY['COMMERCIAL_CANDIDATE'::text, 'RESEARCH_REQUIRED'::text, 'NOT_ADMISSIBLE'::text]))),
    CONSTRAINT commercial_reality_r4_records_input_fingerprint_check CHECK ((input_fingerprint ~ '^[a-f0-9]{64}$'::text))
);

--
-- Name: commercial_relationship_type_registry; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commercial_relationship_type_registry (
    relation_type text NOT NULL,
    edge_class text NOT NULL,
    direction text NOT NULL,
    route_traversable boolean NOT NULL,
    allowed_from_kinds jsonb NOT NULL,
    allowed_to_kinds jsonb NOT NULL,
    ontology_version text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT commercial_relationship_type_registry_allowed_from_kinds_check CHECK (((jsonb_typeof(allowed_from_kinds) = 'array'::text) AND (jsonb_array_length(allowed_from_kinds) > 0))),
    CONSTRAINT commercial_relationship_type_registry_allowed_to_kinds_check CHECK (((jsonb_typeof(allowed_to_kinds) = 'array'::text) AND (jsonb_array_length(allowed_to_kinds) > 0))),
    CONSTRAINT commercial_relationship_type_registry_direction_check CHECK ((direction = ANY (ARRAY['DIRECTED'::text, 'UNDIRECTED'::text]))),
    CONSTRAINT commercial_relationship_type_registry_edge_class_check CHECK ((edge_class = ANY (ARRAY['DEPENDENCY'::text, 'HIERARCHY'::text, 'ASSOCIATION'::text, 'COMPOSITION'::text, 'ACCESS'::text])))
);

--
-- Name: commercial_relationships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commercial_relationships (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_scope_organisation_id uuid,
    relation_type text NOT NULL,
    from_node_id uuid NOT NULL,
    to_node_id uuid NOT NULL,
    claim_id uuid NOT NULL,
    relationship_fingerprint text NOT NULL,
    ontology_version text NOT NULL,
    canonical_version text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT commercial_relationships_check CHECK ((from_node_id <> to_node_id)),
    CONSTRAINT commercial_relationships_relationship_fingerprint_check CHECK ((relationship_fingerprint ~ '^[a-f0-9]{64}$'::text))
);

--
-- Name: companies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.companies (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    canonical_name text NOT NULL,
    canonical_domain text,
    website_url text,
    country_code text,
    lifecycle_state text DEFAULT 'ACTIVE'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT companies_canonical_domain_check CHECK (((canonical_domain IS NULL) OR (canonical_domain = lower(canonical_domain)))),
    CONSTRAINT companies_canonical_name_check CHECK (((length(btrim(canonical_name)) >= 1) AND (length(btrim(canonical_name)) <= 240))),
    CONSTRAINT companies_country_code_check CHECK (((country_code IS NULL) OR (country_code ~ '^[A-Z]{2}$'::text))),
    CONSTRAINT companies_lifecycle_state_check CHECK ((lifecycle_state = ANY (ARRAY['ACTIVE'::text, 'MERGED'::text, 'DISSOLVED'::text, 'ARCHIVED'::text])))
);

--
-- Name: contact_authority_r6_records; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contact_authority_r6_records (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organisation_id uuid NOT NULL,
    campaign_id uuid NOT NULL,
    company_id uuid NOT NULL,
    authority_record_id uuid NOT NULL,
    parent_r5_authority_record_id uuid NOT NULL,
    parent_r5_authority_fingerprint text NOT NULL,
    contact_claim_universe_fingerprint text NOT NULL,
    contact_truth_snapshot_map jsonb NOT NULL,
    engine_version text NOT NULL,
    semantics_version text NOT NULL,
    decision_code text NOT NULL,
    bindings_json jsonb NOT NULL,
    authorised_path_fingerprints jsonb NOT NULL,
    authorised_access_point_ids jsonb NOT NULL,
    research_required_access_point_ids jsonb NOT NULL,
    distinct_authorised_access_point_count integer NOT NULL,
    input_fingerprint text NOT NULL,
    authority_fingerprint text NOT NULL,
    reference_time timestamp with time zone NOT NULL,
    next_revalidation_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT contact_authority_r6_records_authorised_access_point_ids_check CHECK ((jsonb_typeof(authorised_access_point_ids) = 'array'::text)),
    CONSTRAINT contact_authority_r6_records_authorised_path_fingerprints_check CHECK ((jsonb_typeof(authorised_path_fingerprints) = 'array'::text)),
    CONSTRAINT contact_authority_r6_records_authority_fingerprint_check CHECK ((authority_fingerprint ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT contact_authority_r6_records_bindings_json_check CHECK ((jsonb_typeof(bindings_json) = 'array'::text)),
    CONSTRAINT contact_authority_r6_records_check CHECK ((next_revalidation_at > reference_time)),
    CONSTRAINT contact_authority_r6_records_contact_claim_universe_finge_check CHECK ((contact_claim_universe_fingerprint ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT contact_authority_r6_records_contact_truth_snapshot_map_check CHECK ((jsonb_typeof(contact_truth_snapshot_map) = 'object'::text)),
    CONSTRAINT contact_authority_r6_records_decision_code_check CHECK ((decision_code = ANY (ARRAY['CONTACT_AUTHORISED'::text, 'CONTACT_RESEARCH_REQUIRED'::text, 'CONTACT_NOT_APPLICABLE'::text]))),
    CONSTRAINT contact_authority_r6_records_distinct_authorised_access_p_check CHECK ((distinct_authorised_access_point_count >= 0)),
    CONSTRAINT contact_authority_r6_records_input_fingerprint_check CHECK ((input_fingerprint ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT contact_authority_r6_records_parent_r5_authority_fingerpr_check CHECK ((parent_r5_authority_fingerprint ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT contact_authority_r6_records_research_required_access_poi_check CHECK ((jsonb_typeof(research_required_access_point_ids) = 'array'::text))
);

--
-- Name: current_commercial_reality_r4; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.current_commercial_reality_r4 AS
 SELECT r.id,
    r.organisation_id,
    r.campaign_id,
    r.company_id,
    r.authority_record_id,
    r.seller_context_selection_id,
    r.target_truth_entity_snapshot_id,
    r.constraint_truth_snapshot_map,
    r.boundary_constitution_key,
    r.boundary_constitution_version,
    r.reality_class,
    r.engine_version,
    r.semantics_version,
    r.decision_code,
    r.boundaries_json,
    r.input_fingerprint,
    r.authority_fingerprint,
    r.reference_time,
    r.next_revalidation_at,
    r.created_at,
    a.valid_from,
    a.valid_until,
    a.payload_json AS authority_payload_json
   FROM (public.commercial_reality_r4_records r
     JOIN public.authority_records a ON ((a.id = r.authority_record_id)))
  WHERE public.marketroute_r4_authority_current_v1(a.id, now());

--
-- Name: current_contact_authority_r6; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.current_contact_authority_r6 AS
 SELECT r.id,
    r.organisation_id,
    r.campaign_id,
    r.company_id,
    r.authority_record_id,
    r.parent_r5_authority_record_id,
    r.parent_r5_authority_fingerprint,
    r.contact_claim_universe_fingerprint,
    r.contact_truth_snapshot_map,
    r.engine_version,
    r.semantics_version,
    r.decision_code,
    r.bindings_json,
    r.authorised_path_fingerprints,
    r.authorised_access_point_ids,
    r.research_required_access_point_ids,
    r.distinct_authorised_access_point_count,
    r.input_fingerprint,
    r.authority_fingerprint,
    r.reference_time,
    r.next_revalidation_at,
    r.created_at,
    a.valid_from,
    a.valid_until,
    a.payload_json AS authority_payload_json
   FROM (public.contact_authority_r6_records r
     JOIN public.authority_records a ON ((a.id = r.authority_record_id)))
  WHERE public.marketroute_r6_authority_current_v1(a.id, now());

--
-- Name: route_authority_r5_records; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.route_authority_r5_records (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organisation_id uuid NOT NULL,
    campaign_id uuid NOT NULL,
    company_id uuid NOT NULL,
    authority_record_id uuid NOT NULL,
    parent_r4_authority_record_id uuid NOT NULL,
    parent_r4_authority_fingerprint text NOT NULL,
    relationship_universe_fingerprint text NOT NULL,
    relationship_truth_snapshot_map jsonb NOT NULL,
    engine_version text NOT NULL,
    semantics_version text NOT NULL,
    decision_code text NOT NULL,
    paths_json jsonb NOT NULL,
    open_access_point_ids jsonb NOT NULL,
    contact_truth_required_access_point_ids jsonb NOT NULL,
    distinct_access_point_count integer NOT NULL,
    input_fingerprint text NOT NULL,
    authority_fingerprint text NOT NULL,
    reference_time timestamp with time zone NOT NULL,
    next_revalidation_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT route_authority_r5_records_authority_fingerprint_check CHECK ((authority_fingerprint ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT route_authority_r5_records_check CHECK ((next_revalidation_at > reference_time)),
    CONSTRAINT route_authority_r5_records_contact_truth_required_access__check CHECK ((jsonb_typeof(contact_truth_required_access_point_ids) = 'array'::text)),
    CONSTRAINT route_authority_r5_records_decision_code_check CHECK ((decision_code = ANY (ARRAY['ROUTE_STRUCTURALLY_OPEN'::text, 'ROUTE_RESEARCH_REQUIRED'::text, 'ROUTE_NOT_APPLICABLE'::text]))),
    CONSTRAINT route_authority_r5_records_distinct_access_point_count_check CHECK ((distinct_access_point_count >= 0)),
    CONSTRAINT route_authority_r5_records_input_fingerprint_check CHECK ((input_fingerprint ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT route_authority_r5_records_open_access_point_ids_check CHECK ((jsonb_typeof(open_access_point_ids) = 'array'::text)),
    CONSTRAINT route_authority_r5_records_parent_r4_authority_fingerprin_check CHECK ((parent_r4_authority_fingerprint ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT route_authority_r5_records_paths_json_check CHECK ((jsonb_typeof(paths_json) = 'array'::text)),
    CONSTRAINT route_authority_r5_records_relationship_truth_snapshot_ma_check CHECK ((jsonb_typeof(relationship_truth_snapshot_map) = 'object'::text)),
    CONSTRAINT route_authority_r5_records_relationship_universe_fingerpr_check CHECK ((relationship_universe_fingerprint ~ '^[a-f0-9]{64}$'::text))
);

--
-- Name: current_route_authority_r5; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.current_route_authority_r5 AS
 SELECT r.id,
    r.organisation_id,
    r.campaign_id,
    r.company_id,
    r.authority_record_id,
    r.parent_r4_authority_record_id,
    r.parent_r4_authority_fingerprint,
    r.relationship_universe_fingerprint,
    r.relationship_truth_snapshot_map,
    r.engine_version,
    r.semantics_version,
    r.decision_code,
    r.paths_json,
    r.open_access_point_ids,
    r.contact_truth_required_access_point_ids,
    r.distinct_access_point_count,
    r.input_fingerprint,
    r.authority_fingerprint,
    r.reference_time,
    r.next_revalidation_at,
    r.created_at,
    a.valid_from,
    a.valid_until,
    a.payload_json AS authority_payload_json
   FROM (public.route_authority_r5_records r
     JOIN public.authority_records a ON ((a.id = r.authority_record_id)))
  WHERE public.marketroute_r5_authority_current_v1(a.id, now());

--
-- Name: engagement_ai_reviews; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.engagement_ai_reviews (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    review_request_id uuid NOT NULL,
    message_id uuid NOT NULL,
    review_contract_version text NOT NULL,
    reviewer_version text NOT NULL,
    verdict text NOT NULL,
    reason_codes text[] DEFAULT '{}'::text[] NOT NULL,
    diagnostics_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    review_fingerprint text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT engagement_ai_reviews_diagnostics_json_check CHECK ((jsonb_typeof(diagnostics_json) = 'object'::text)),
    CONSTRAINT engagement_ai_reviews_review_contract_version_check CHECK ((review_contract_version = 'MRV2-ENGAGEMENT-REVIEW-1.0.0'::text)),
    CONSTRAINT engagement_ai_reviews_review_fingerprint_check CHECK ((review_fingerprint ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT engagement_ai_reviews_reviewer_version_check CHECK (((length(btrim(reviewer_version)) >= 1) AND (length(btrim(reviewer_version)) <= 160))),
    CONSTRAINT engagement_ai_reviews_verdict_check CHECK ((verdict = ANY (ARRAY['PASS'::text, 'REWRITE'::text, 'BLOCK'::text])))
);

--
-- Name: engagement_delivery_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.engagement_delivery_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    queue_item_id uuid NOT NULL,
    job_id uuid NOT NULL,
    event_type text NOT NULL,
    worker_id text,
    send_gate_fingerprint text,
    provider_message_id text,
    metadata_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT engagement_delivery_events_event_type_check CHECK ((event_type = ANY (ARRAY['QUEUED'::text, 'CLAIMED'::text, 'SENT'::text, 'FAILED'::text, 'BLOCKED_STALE'::text, 'RECONCILIATION_REQUIRED'::text]))),
    CONSTRAINT engagement_delivery_events_metadata_json_check CHECK ((jsonb_typeof(metadata_json) = 'object'::text)),
    CONSTRAINT engagement_delivery_events_send_gate_fingerprint_check CHECK (((send_gate_fingerprint IS NULL) OR (send_gate_fingerprint ~ '^[a-f0-9]{64}$'::text)))
);

--
-- Name: engagement_delivery_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.engagement_delivery_jobs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    queue_item_id uuid NOT NULL,
    status text DEFAULT 'PENDING'::text NOT NULL,
    attempt_number integer DEFAULT 0 NOT NULL,
    claimed_by text,
    claimed_at timestamp with time zone,
    send_gate_fingerprint text,
    last_error_code text,
    finished_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT engagement_delivery_jobs_attempt_number_check CHECK (((attempt_number >= 0) AND (attempt_number <= 1))),
    CONSTRAINT engagement_delivery_jobs_send_gate_fingerprint_check CHECK (((send_gate_fingerprint IS NULL) OR (send_gate_fingerprint ~ '^[a-f0-9]{64}$'::text))),
    CONSTRAINT engagement_delivery_jobs_status_check CHECK ((status = ANY (ARRAY['PENDING'::text, 'RUNNING'::text, 'SENT'::text, 'FAILED'::text, 'BLOCKED_STALE'::text, 'RECONCILIATION_REQUIRED'::text])))
);

--
-- Name: engagement_manual_actions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.engagement_manual_actions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    request_id uuid NOT NULL,
    opportunity_id uuid NOT NULL,
    organisation_id uuid NOT NULL,
    campaign_id uuid NOT NULL,
    company_id uuid NOT NULL,
    strategy_id uuid NOT NULL,
    message_id uuid NOT NULL,
    actor_user_id uuid NOT NULL,
    path_fingerprint text NOT NULL,
    channel_kind text NOT NULL,
    access_point_id uuid NOT NULL,
    person_id uuid,
    authority_envelope_fingerprint text NOT NULL,
    note text,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT engagement_manual_actions_authority_envelope_fingerprint_check CHECK ((authority_envelope_fingerprint ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT engagement_manual_actions_channel_kind_check CHECK ((channel_kind = ANY (ARRAY['EMAIL'::text, 'CONTACT_FORM'::text, 'LINKEDIN'::text, 'PHONE'::text, 'OTHER'::text]))),
    CONSTRAINT engagement_manual_actions_note_check CHECK (((note IS NULL) OR (length(note) <= 1000))),
    CONSTRAINT engagement_manual_actions_path_fingerprint_check CHECK ((path_fingerprint ~ '^[a-f0-9]{64}$'::text))
);

--
-- Name: engagement_message_approvals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.engagement_message_approvals (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    approval_request_id uuid NOT NULL,
    message_id uuid NOT NULL,
    review_id uuid NOT NULL,
    approval_mode text NOT NULL,
    actor_user_id uuid,
    decision text NOT NULL,
    policy_version text NOT NULL,
    authority_envelope_json jsonb NOT NULL,
    authority_envelope_fingerprint text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT engagement_message_approvals_approval_mode_check CHECK ((approval_mode = ANY (ARRAY['HUMAN'::text, 'AUTOPILOT'::text]))),
    CONSTRAINT engagement_message_approvals_authority_envelope_fingerpri_check CHECK ((authority_envelope_fingerprint ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT engagement_message_approvals_authority_envelope_json_check CHECK ((jsonb_typeof(authority_envelope_json) = 'object'::text)),
    CONSTRAINT engagement_message_approvals_check CHECK ((((approval_mode = 'HUMAN'::text) AND (actor_user_id IS NOT NULL)) OR ((approval_mode = 'AUTOPILOT'::text) AND (actor_user_id IS NULL)))),
    CONSTRAINT engagement_message_approvals_decision_check CHECK ((decision = ANY (ARRAY['APPROVE'::text, 'REJECT'::text]))),
    CONSTRAINT engagement_message_approvals_policy_version_check CHECK ((policy_version = 'MRV2-ENGAGEMENT-POLICY-1.0.0'::text))
);

--
-- Name: engagement_messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.engagement_messages (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    generation_request_id uuid NOT NULL,
    strategy_id uuid NOT NULL,
    previous_message_id uuid,
    rewrite_ordinal integer NOT NULL,
    generation_contract_version text NOT NULL,
    generator_version text NOT NULL,
    generation_context_fingerprint text NOT NULL,
    subject_text text,
    body_text text NOT NULL,
    message_fingerprint text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT engagement_messages_body_text_check CHECK (((length(btrim(body_text)) >= 1) AND (length(btrim(body_text)) <= 8000))),
    CONSTRAINT engagement_messages_generation_context_fingerprint_check CHECK ((generation_context_fingerprint ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT engagement_messages_generation_contract_version_check CHECK ((generation_contract_version = 'MRV2-ENGAGEMENT-GENERATION-1.0.0'::text)),
    CONSTRAINT engagement_messages_generator_version_check CHECK (((length(btrim(generator_version)) >= 1) AND (length(btrim(generator_version)) <= 160))),
    CONSTRAINT engagement_messages_message_fingerprint_check CHECK ((message_fingerprint ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT engagement_messages_rewrite_ordinal_check CHECK (((rewrite_ordinal >= 0) AND (rewrite_ordinal <= 2))),
    CONSTRAINT engagement_messages_subject_text_check CHECK (((subject_text IS NULL) OR ((length(btrim(subject_text)) >= 1) AND (length(btrim(subject_text)) <= 300))))
);

--
-- Name: engagement_queue_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.engagement_queue_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    queue_request_id uuid NOT NULL,
    opportunity_id uuid NOT NULL,
    organisation_id uuid NOT NULL,
    campaign_id uuid NOT NULL,
    company_id uuid NOT NULL,
    strategy_id uuid NOT NULL,
    message_id uuid NOT NULL,
    review_id uuid NOT NULL,
    approval_id uuid NOT NULL,
    approval_mode text NOT NULL,
    authority_envelope_json jsonb NOT NULL,
    authority_envelope_fingerprint text NOT NULL,
    queued_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT engagement_queue_items_approval_mode_check CHECK ((approval_mode = ANY (ARRAY['HUMAN'::text, 'AUTOPILOT'::text]))),
    CONSTRAINT engagement_queue_items_authority_envelope_fingerprint_check CHECK ((authority_envelope_fingerprint ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT engagement_queue_items_authority_envelope_json_check CHECK ((jsonb_typeof(authority_envelope_json) = 'object'::text))
);

--
-- Name: engagement_strategies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.engagement_strategies (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    request_id uuid NOT NULL,
    opportunity_id uuid NOT NULL,
    organisation_id uuid NOT NULL,
    campaign_id uuid NOT NULL,
    company_id uuid NOT NULL,
    path_fingerprint text NOT NULL,
    access_point_id uuid NOT NULL,
    access_point_kind text NOT NULL,
    access_point_value text NOT NULL,
    route_mode text NOT NULL,
    person_id uuid,
    channel_kind text NOT NULL,
    strategy_version text NOT NULL,
    generation_context_fingerprint text NOT NULL,
    authority_envelope_fingerprint text NOT NULL,
    r6_authority_record_id uuid NOT NULL,
    r6_authority_fingerprint text NOT NULL,
    strategy_fingerprint text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT engagement_strategies_access_point_value_check CHECK (((length(btrim(access_point_value)) >= 1) AND (length(btrim(access_point_value)) <= 2048))),
    CONSTRAINT engagement_strategies_authority_envelope_fingerprint_check CHECK ((authority_envelope_fingerprint ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT engagement_strategies_channel_kind_check CHECK ((channel_kind = ANY (ARRAY['EMAIL'::text, 'CONTACT_FORM'::text, 'LINKEDIN'::text, 'PHONE'::text, 'OTHER'::text]))),
    CONSTRAINT engagement_strategies_check CHECK ((((route_mode = 'NAMED_CONTACT'::text) AND (person_id IS NOT NULL)) OR ((route_mode = 'ORGANISATIONAL_ROUTE'::text) AND (person_id IS NULL)))),
    CONSTRAINT engagement_strategies_generation_context_fingerprint_check CHECK ((generation_context_fingerprint ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT engagement_strategies_path_fingerprint_check CHECK ((path_fingerprint ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT engagement_strategies_r6_authority_fingerprint_check CHECK ((r6_authority_fingerprint ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT engagement_strategies_route_mode_check CHECK ((route_mode = ANY (ARRAY['ORGANISATIONAL_ROUTE'::text, 'NAMED_CONTACT'::text]))),
    CONSTRAINT engagement_strategies_strategy_fingerprint_check CHECK ((strategy_fingerprint ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT engagement_strategies_strategy_version_check CHECK ((strategy_version = 'MRV2-ENGAGEMENT-STRATEGY-1.0.0'::text))
);

--
-- Name: evidence_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.evidence_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    acquisition_id uuid NOT NULL,
    tenant_scope_organisation_id uuid,
    subject_type text NOT NULL,
    subject_id uuid NOT NULL,
    evidence_kind text NOT NULL,
    excerpt_text text,
    structured_value_json jsonb,
    observed_at timestamp with time zone DEFAULT now() NOT NULL,
    origin_published_at timestamp with time zone,
    extraction_method text NOT NULL,
    extraction_version text,
    evidence_fingerprint text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    source_identity_fingerprint text NOT NULL,
    dependence_family_key text NOT NULL,
    fingerprint_version text NOT NULL,
    CONSTRAINT evidence_items_check CHECK (((excerpt_text IS NOT NULL) OR (structured_value_json IS NOT NULL))),
    CONSTRAINT evidence_items_dependence_family_nonempty CHECK ((length(btrim(dependence_family_key)) > 0)),
    CONSTRAINT evidence_items_evidence_fingerprint_check CHECK ((evidence_fingerprint ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT evidence_items_evidence_kind_check CHECK ((evidence_kind = ANY (ARRAY['QUOTE'::text, 'STRUCTURED_FIELD'::text, 'OBSERVATION'::text, 'DOCUMENT_SECTION'::text, 'REGISTRY_RECORD'::text, 'USER_ASSERTION'::text, 'OTHER'::text]))),
    CONSTRAINT evidence_items_extraction_method_check CHECK ((extraction_method = ANY (ARRAY['DETERMINISTIC'::text, 'AI_EXTRACTED'::text, 'USER_PROVIDED'::text, 'MIGRATED'::text]))),
    CONSTRAINT evidence_items_fingerprint_version_nonempty CHECK ((length(btrim(fingerprint_version)) > 0)),
    CONSTRAINT evidence_items_source_identity_fingerprint_shape CHECK ((source_identity_fingerprint ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT evidence_items_subject_type_check CHECK ((subject_type = ANY (ARRAY['COMPANY'::text, 'PERSON'::text, 'SELLER_BUSINESS'::text, 'CAMPAIGN'::text, 'RELATIONSHIP'::text, 'CHANNEL'::text, 'OTHER'::text])))
);

--
-- Name: genesis_growth_action_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.genesis_growth_action_runs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    scheduler_run_id uuid NOT NULL,
    action_kind text NOT NULL,
    phase text NOT NULL,
    industry_key text,
    company_id uuid,
    status text DEFAULT 'RUNNING'::text NOT NULL,
    actual_cost_usd numeric(18,8),
    result_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    error_code text,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    completed_at timestamp with time zone,
    CONSTRAINT genesis_growth_action_runs_action_kind_check CHECK ((action_kind = ANY (ARRAY['DISCOVER_COMPANIES'::text, 'RESEARCH_CORE_PROFILE'::text, 'RESEARCH_ROUTES'::text, 'RESEARCH_CONTACTS'::text, 'REFRESH_CORE'::text]))),
    CONSTRAINT genesis_growth_action_runs_actual_cost_usd_check CHECK (((actual_cost_usd IS NULL) OR (actual_cost_usd >= (0)::numeric))),
    CONSTRAINT genesis_growth_action_runs_check CHECK ((((action_kind = 'DISCOVER_COMPANIES'::text) AND (industry_key IS NOT NULL) AND (company_id IS NULL)) OR (action_kind <> 'DISCOVER_COMPANIES'::text))),
    CONSTRAINT genesis_growth_action_runs_phase_check CHECK ((phase = ANY (ARRAY['SEED'::text, 'BREADTH'::text, 'DEPTH'::text, 'REFRESH'::text]))),
    CONSTRAINT genesis_growth_action_runs_result_json_check CHECK ((jsonb_typeof(result_json) = 'object'::text)),
    CONSTRAINT genesis_growth_action_runs_status_check CHECK ((status = ANY (ARRAY['RUNNING'::text, 'SUCCEEDED'::text, 'FAILED'::text, 'SKIPPED'::text])))
);

--
-- Name: genesis_growth_budget_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.genesis_growth_budget_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    action_run_id uuid NOT NULL,
    industry_key text,
    company_id uuid,
    amount_usd numeric(18,8) NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    metadata_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT genesis_growth_budget_events_amount_usd_check CHECK ((amount_usd >= (0)::numeric)),
    CONSTRAINT genesis_growth_budget_events_metadata_json_check CHECK ((jsonb_typeof(metadata_json) = 'object'::text))
);

--
-- Name: genesis_growth_company_memberships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.genesis_growth_company_memberships (
    industry_key text NOT NULL,
    company_id uuid NOT NULL,
    discovery_reason text,
    first_discovered_at timestamp with time zone DEFAULT now() NOT NULL
);

--
-- Name: genesis_growth_company_progress; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.genesis_growth_company_progress (
    company_id uuid NOT NULL,
    core_scan_at timestamp with time zone,
    core_complete_at timestamp with time zone,
    profile_complete_at timestamp with time zone,
    routes_scan_at timestamp with time zone,
    routes_complete_at timestamp with time zone,
    contacts_scan_at timestamp with time zone,
    contacts_complete_at timestamp with time zone,
    last_researched_at timestamp with time zone,
    retry_after timestamp with time zone,
    last_error_code text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

--
-- Name: genesis_growth_industries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.genesis_growth_industries (
    industry_key text NOT NULL,
    display_name text NOT NULL,
    priority integer NOT NULL,
    seed_target_company_count integer DEFAULT 50 NOT NULL,
    launch_target_company_count integer DEFAULT 500 NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT genesis_growth_industries_check CHECK (((launch_target_company_count >= seed_target_company_count) AND (launch_target_company_count <= 100000))),
    CONSTRAINT genesis_growth_industries_display_name_check CHECK (((length(btrim(display_name)) >= 2) AND (length(btrim(display_name)) <= 120))),
    CONSTRAINT genesis_growth_industries_industry_key_check CHECK ((industry_key ~ '^[a-z0-9][a-z0-9-]{1,62}$'::text)),
    CONSTRAINT genesis_growth_industries_priority_check CHECK (((priority >= 1) AND (priority <= 1000))),
    CONSTRAINT genesis_growth_industries_seed_target_company_count_check CHECK (((seed_target_company_count >= 1) AND (seed_target_company_count <= 10000)))
);

--
-- Name: genesis_growth_people; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.genesis_growth_people (
    identity_key text NOT NULL,
    company_id uuid NOT NULL,
    person_id uuid NOT NULL,
    canonical_name text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

--
-- Name: genesis_growth_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.genesis_growth_settings (
    singleton boolean DEFAULT true NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    seed_target_company_count integer DEFAULT 50 NOT NULL,
    launch_target_company_count integer DEFAULT 500 NOT NULL,
    daily_budget_usd numeric(18,6) DEFAULT 100 NOT NULL,
    max_action_cost_usd numeric(18,6) DEFAULT 0.50 NOT NULL,
    discovery_batch_size integer DEFAULT 10 NOT NULL,
    max_actions_per_run integer DEFAULT 1 NOT NULL,
    retry_hours integer DEFAULT 24 NOT NULL,
    refresh_days integer DEFAULT 30 NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT genesis_growth_settings_check CHECK (((launch_target_company_count >= seed_target_company_count) AND (launch_target_company_count <= 100000))),
    CONSTRAINT genesis_growth_settings_daily_budget_usd_check CHECK (((daily_budget_usd >= (0)::numeric) AND (daily_budget_usd <= (1000000)::numeric))),
    CONSTRAINT genesis_growth_settings_discovery_batch_size_check CHECK (((discovery_batch_size >= 1) AND (discovery_batch_size <= 25))),
    CONSTRAINT genesis_growth_settings_max_action_cost_usd_check CHECK (((max_action_cost_usd >= 0.001) AND (max_action_cost_usd <= (10000)::numeric))),
    CONSTRAINT genesis_growth_settings_max_actions_per_run_check CHECK (((max_actions_per_run >= 1) AND (max_actions_per_run <= 20))),
    CONSTRAINT genesis_growth_settings_refresh_days_check CHECK (((refresh_days >= 1) AND (refresh_days <= 365))),
    CONSTRAINT genesis_growth_settings_retry_hours_check CHECK (((retry_hours >= 1) AND (retry_hours <= 720))),
    CONSTRAINT genesis_growth_settings_seed_target_company_count_check CHECK (((seed_target_company_count >= 1) AND (seed_target_company_count <= 10000))),
    CONSTRAINT genesis_growth_settings_singleton_check CHECK (singleton)
);

--
-- Name: truth_claim_snapshots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.truth_claim_snapshots (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    reasoning_run_id uuid NOT NULL,
    reasoning_artifact_id uuid NOT NULL,
    claim_id uuid NOT NULL,
    tenant_scope_organisation_id uuid,
    subject_type text NOT NULL,
    subject_id uuid NOT NULL,
    claim_key text NOT NULL,
    proposition_fingerprint text NOT NULL,
    policy_key text NOT NULL,
    policy_version text NOT NULL,
    engine_version text NOT NULL,
    semantics_version text NOT NULL,
    input_fingerprint text NOT NULL,
    snapshot_fingerprint text NOT NULL,
    truth_state text NOT NULL,
    current_support_family_count integer NOT NULL,
    current_contradiction_family_count integer NOT NULL,
    stale_family_count integer NOT NULL,
    temporal_anomaly_count integer NOT NULL,
    evidence_sufficiency numeric(9,6) NOT NULL,
    support_strength numeric(9,6) NOT NULL,
    contradiction_strength numeric(9,6) NOT NULL,
    evidence_balance numeric(9,6) NOT NULL,
    freshness_coverage numeric(9,6) NOT NULL,
    truth_probability numeric,
    probability_state text NOT NULL,
    reference_time timestamp with time zone NOT NULL,
    next_revalidation_at timestamp with time zone,
    payload_json jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT truth_claim_snapshots_check CHECK (((next_revalidation_at IS NULL) OR (next_revalidation_at > reference_time))),
    CONSTRAINT truth_claim_snapshots_contradiction_strength_check CHECK (((contradiction_strength >= (0)::numeric) AND (contradiction_strength <= (1)::numeric))),
    CONSTRAINT truth_claim_snapshots_current_contradiction_family_count_check CHECK ((current_contradiction_family_count >= 0)),
    CONSTRAINT truth_claim_snapshots_current_support_family_count_check CHECK ((current_support_family_count >= 0)),
    CONSTRAINT truth_claim_snapshots_evidence_balance_check CHECK (((evidence_balance >= ('-1'::integer)::numeric) AND (evidence_balance <= (1)::numeric))),
    CONSTRAINT truth_claim_snapshots_evidence_sufficiency_check CHECK (((evidence_sufficiency >= (0)::numeric) AND (evidence_sufficiency <= (1)::numeric))),
    CONSTRAINT truth_claim_snapshots_freshness_coverage_check CHECK (((freshness_coverage >= (0)::numeric) AND (freshness_coverage <= (1)::numeric))),
    CONSTRAINT truth_claim_snapshots_input_fingerprint_check CHECK ((input_fingerprint ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT truth_claim_snapshots_payload_json_check CHECK ((jsonb_typeof(payload_json) = 'object'::text)),
    CONSTRAINT truth_claim_snapshots_probability_state_check CHECK ((probability_state = 'UNCALIBRATED'::text)),
    CONSTRAINT truth_claim_snapshots_proposition_fingerprint_check CHECK ((proposition_fingerprint ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT truth_claim_snapshots_snapshot_fingerprint_check CHECK ((snapshot_fingerprint ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT truth_claim_snapshots_stale_family_count_check CHECK ((stale_family_count >= 0)),
    CONSTRAINT truth_claim_snapshots_support_strength_check CHECK (((support_strength >= (0)::numeric) AND (support_strength <= (1)::numeric))),
    CONSTRAINT truth_claim_snapshots_temporal_anomaly_count_check CHECK ((temporal_anomaly_count >= 0)),
    CONSTRAINT truth_claim_snapshots_truth_probability_check CHECK ((truth_probability IS NULL)),
    CONSTRAINT truth_claim_snapshots_truth_state_check CHECK ((truth_state = ANY (ARRAY['KNOWN'::text, 'SUPPORTED'::text, 'UNRESOLVED'::text, 'CONTRADICTED'::text, 'STALE'::text])))
);

--
-- Name: latest_truth_claim_snapshots; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.latest_truth_claim_snapshots AS
 SELECT DISTINCT ON (claim_id) id,
    reasoning_run_id,
    reasoning_artifact_id,
    claim_id,
    tenant_scope_organisation_id,
    subject_type,
    subject_id,
    claim_key,
    proposition_fingerprint,
    policy_key,
    policy_version,
    engine_version,
    semantics_version,
    input_fingerprint,
    snapshot_fingerprint,
    truth_state,
    current_support_family_count,
    current_contradiction_family_count,
    stale_family_count,
    temporal_anomaly_count,
    evidence_sufficiency,
    support_strength,
    contradiction_strength,
    evidence_balance,
    freshness_coverage,
    truth_probability,
    probability_state,
    reference_time,
    next_revalidation_at,
    created_at
   FROM public.truth_claim_snapshots
  ORDER BY claim_id, reference_time DESC, created_at DESC;

--
-- Name: truth_entity_snapshots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.truth_entity_snapshots (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    reasoning_run_id uuid NOT NULL,
    reasoning_artifact_id uuid NOT NULL,
    tenant_scope_organisation_id uuid,
    subject_type text NOT NULL,
    subject_id uuid NOT NULL,
    profile_key text NOT NULL,
    profile_version text NOT NULL,
    aggregation_version text NOT NULL,
    semantics_version text NOT NULL,
    input_fingerprint text NOT NULL,
    snapshot_fingerprint text NOT NULL,
    entity_state text NOT NULL,
    required_claim_count integer NOT NULL,
    known_claim_count integer NOT NULL,
    supported_claim_count integer NOT NULL,
    contradicted_claim_count integer NOT NULL,
    stale_claim_count integer NOT NULL,
    unresolved_claim_count integer NOT NULL,
    coverage numeric(9,6) NOT NULL,
    current_coverage numeric(9,6) NOT NULL,
    evidence_sufficiency numeric(9,6) NOT NULL,
    freshness_coverage numeric(9,6) NOT NULL,
    coherence numeric(9,6) NOT NULL,
    truth_index numeric(6,2) NOT NULL,
    truth_probability numeric,
    probability_state text NOT NULL,
    reference_time timestamp with time zone NOT NULL,
    next_revalidation_at timestamp with time zone,
    claim_snapshot_map jsonb NOT NULL,
    payload_json jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT truth_entity_snapshots_check CHECK ((((((known_claim_count + supported_claim_count) + contradicted_claim_count) + stale_claim_count) + unresolved_claim_count) = required_claim_count)),
    CONSTRAINT truth_entity_snapshots_check1 CHECK (((next_revalidation_at IS NULL) OR (next_revalidation_at > reference_time))),
    CONSTRAINT truth_entity_snapshots_claim_snapshot_map_check CHECK ((jsonb_typeof(claim_snapshot_map) = 'object'::text)),
    CONSTRAINT truth_entity_snapshots_coherence_check CHECK (((coherence >= (0)::numeric) AND (coherence <= (1)::numeric))),
    CONSTRAINT truth_entity_snapshots_contradicted_claim_count_check CHECK ((contradicted_claim_count >= 0)),
    CONSTRAINT truth_entity_snapshots_coverage_check CHECK (((coverage >= (0)::numeric) AND (coverage <= (1)::numeric))),
    CONSTRAINT truth_entity_snapshots_current_coverage_check CHECK (((current_coverage >= (0)::numeric) AND (current_coverage <= (1)::numeric))),
    CONSTRAINT truth_entity_snapshots_entity_state_check CHECK ((entity_state = ANY (ARRAY['KNOWN'::text, 'SUPPORTED'::text, 'PARTIAL'::text, 'UNRESOLVED'::text, 'CONTRADICTED'::text, 'STALE'::text]))),
    CONSTRAINT truth_entity_snapshots_evidence_sufficiency_check CHECK (((evidence_sufficiency >= (0)::numeric) AND (evidence_sufficiency <= (1)::numeric))),
    CONSTRAINT truth_entity_snapshots_freshness_coverage_check CHECK (((freshness_coverage >= (0)::numeric) AND (freshness_coverage <= (1)::numeric))),
    CONSTRAINT truth_entity_snapshots_input_fingerprint_check CHECK ((input_fingerprint ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT truth_entity_snapshots_known_claim_count_check CHECK ((known_claim_count >= 0)),
    CONSTRAINT truth_entity_snapshots_payload_json_check CHECK ((jsonb_typeof(payload_json) = 'object'::text)),
    CONSTRAINT truth_entity_snapshots_probability_state_check CHECK ((probability_state = 'UNCALIBRATED'::text)),
    CONSTRAINT truth_entity_snapshots_required_claim_count_check CHECK ((required_claim_count > 0)),
    CONSTRAINT truth_entity_snapshots_snapshot_fingerprint_check CHECK ((snapshot_fingerprint ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT truth_entity_snapshots_stale_claim_count_check CHECK ((stale_claim_count >= 0)),
    CONSTRAINT truth_entity_snapshots_supported_claim_count_check CHECK ((supported_claim_count >= 0)),
    CONSTRAINT truth_entity_snapshots_truth_index_check CHECK (((truth_index >= (0)::numeric) AND (truth_index <= (100)::numeric))),
    CONSTRAINT truth_entity_snapshots_truth_probability_check CHECK ((truth_probability IS NULL)),
    CONSTRAINT truth_entity_snapshots_unresolved_claim_count_check CHECK ((unresolved_claim_count >= 0))
);

--
-- Name: latest_truth_entity_snapshots; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.latest_truth_entity_snapshots AS
 SELECT DISTINCT ON (tenant_scope_organisation_id, subject_type, subject_id, profile_key) id,
    reasoning_run_id,
    reasoning_artifact_id,
    tenant_scope_organisation_id,
    subject_type,
    subject_id,
    profile_key,
    profile_version,
    aggregation_version,
    semantics_version,
    input_fingerprint,
    snapshot_fingerprint,
    entity_state,
    required_claim_count,
    known_claim_count,
    supported_claim_count,
    contradicted_claim_count,
    stale_claim_count,
    unresolved_claim_count,
    coverage,
    current_coverage,
    evidence_sufficiency,
    freshness_coverage,
    coherence,
    truth_index,
    truth_probability,
    probability_state,
    reference_time,
    next_revalidation_at,
    created_at
   FROM public.truth_entity_snapshots
  ORDER BY tenant_scope_organisation_id, subject_type, subject_id, profile_key, reference_time DESC, created_at DESC;

--
-- Name: marketroute_billing_checkout_attempts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.marketroute_billing_checkout_attempts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organisation_id uuid NOT NULL,
    user_id uuid NOT NULL,
    plan_code text NOT NULL,
    provider text DEFAULT 'STRIPE'::text NOT NULL,
    status text DEFAULT 'PENDING'::text NOT NULL,
    external_checkout_session_id text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    metadata_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT marketroute_billing_checkout_attempts_metadata_json_check CHECK ((jsonb_typeof(metadata_json) = 'object'::text)),
    CONSTRAINT marketroute_billing_checkout_attempts_provider_check CHECK ((provider = 'STRIPE'::text)),
    CONSTRAINT marketroute_billing_checkout_attempts_status_check CHECK ((status = ANY (ARRAY['PENDING'::text, 'REDIRECTED'::text, 'COMPLETED'::text, 'FAILED'::text, 'EXPIRED'::text])))
);

--
-- Name: marketroute_billing_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.marketroute_billing_events (
    provider text DEFAULT 'STRIPE'::text NOT NULL,
    external_event_id text NOT NULL,
    event_type text NOT NULL,
    status text DEFAULT 'RECEIVED'::text NOT NULL,
    payload_sha256 text NOT NULL,
    error_code text,
    metadata_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    received_at timestamp with time zone DEFAULT now() NOT NULL,
    processed_at timestamp with time zone,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT marketroute_billing_events_metadata_json_check CHECK ((jsonb_typeof(metadata_json) = 'object'::text)),
    CONSTRAINT marketroute_billing_events_payload_sha256_check CHECK ((payload_sha256 ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT marketroute_billing_events_provider_check CHECK ((provider = 'STRIPE'::text)),
    CONSTRAINT marketroute_billing_events_status_check CHECK ((status = ANY (ARRAY['RECEIVED'::text, 'PROCESSED'::text, 'IGNORED'::text, 'FAILED'::text])))
);

--
-- Name: marketroute_conversation_narration_cache; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.marketroute_conversation_narration_cache (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    scope_kind text NOT NULL,
    scope_key text NOT NULL,
    input_fingerprint text NOT NULL,
    contract_version text NOT NULL,
    payload_json jsonb NOT NULL,
    model text NOT NULL,
    organisation_id uuid,
    campaign_id uuid,
    company_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    CONSTRAINT marketroute_conversation_narration_cach_input_fingerprint_check CHECK ((input_fingerprint ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT marketroute_conversation_narration_cache_check CHECK ((expires_at > created_at)),
    CONSTRAINT marketroute_conversation_narration_cache_contract_version_check CHECK (((length(btrim(contract_version)) >= 3) AND (length(btrim(contract_version)) <= 80))),
    CONSTRAINT marketroute_conversation_narration_cache_model_check CHECK (((length(btrim(model)) >= 1) AND (length(btrim(model)) <= 160))),
    CONSTRAINT marketroute_conversation_narration_cache_scope_key_check CHECK (((length(btrim(scope_key)) >= 1) AND (length(btrim(scope_key)) <= 240))),
    CONSTRAINT marketroute_conversation_narration_cache_scope_kind_check CHECK ((scope_kind = ANY (ARRAY['DISCOVERY_PROGRESS'::text, 'COMMAND_CENTRE'::text, 'CAMPAIGN_OVERVIEW'::text, 'OPPORTUNITY_SUMMARY'::text, 'OPPORTUNITY_QA'::text])))
);

--
-- Name: marketroute_plan_catalog; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.marketroute_plan_catalog (
    plan_code text NOT NULL,
    display_name text NOT NULL,
    monthly_price_gbp numeric(10,2) NOT NULL,
    research_capacity_units integer,
    active_market_limit integer DEFAULT 1 NOT NULL,
    team_seat_limit integer,
    public_visible boolean DEFAULT true NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    metadata_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT marketroute_plan_catalog_active_market_limit_check CHECK ((active_market_limit >= 1)),
    CONSTRAINT marketroute_plan_catalog_metadata_json_check CHECK ((jsonb_typeof(metadata_json) = 'object'::text)),
    CONSTRAINT marketroute_plan_catalog_monthly_price_gbp_check CHECK ((monthly_price_gbp >= (0)::numeric)),
    CONSTRAINT marketroute_plan_catalog_plan_code_check CHECK ((plan_code = ANY (ARRAY['DISCOVERY'::text, 'STARTER'::text, 'GROWTH'::text, 'SCALE'::text, 'LEGACY_FULL'::text]))),
    CONSTRAINT marketroute_plan_catalog_research_capacity_units_check CHECK (((research_capacity_units IS NULL) OR (research_capacity_units >= 0))),
    CONSTRAINT marketroute_plan_catalog_team_seat_limit_check CHECK (((team_seat_limit IS NULL) OR (team_seat_limit >= 1)))
);

--
-- Name: marketroute_schema_releases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.marketroute_schema_releases (
    release_key text NOT NULL,
    build_number integer NOT NULL,
    constitution_version text NOT NULL,
    applied_at timestamp with time zone DEFAULT now() NOT NULL,
    metadata_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT marketroute_schema_releases_build_number_check CHECK ((build_number > 0)),
    CONSTRAINT marketroute_schema_releases_metadata_json_check CHECK ((jsonb_typeof(metadata_json) = 'object'::text))
);

--
-- Name: opportunities; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.opportunities (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organisation_id uuid NOT NULL,
    campaign_id uuid NOT NULL,
    company_id uuid NOT NULL,
    workflow_state text DEFAULT 'RESEARCHING'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT opportunities_workflow_state_check CHECK ((workflow_state = ANY (ARRAY['RESEARCHING'::text, 'REVIEWABLE'::text, 'APPROVED'::text, 'REJECTED'::text, 'ENGAGED'::text, 'ARCHIVED'::text])))
);

--
-- Name: opportunity_human_reviews; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.opportunity_human_reviews (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    opportunity_id uuid NOT NULL,
    organisation_id uuid NOT NULL,
    reviewer_user_id uuid NOT NULL,
    decision text NOT NULL,
    note text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    review_request_id uuid,
    prior_workflow_state text,
    resulting_workflow_state text,
    authority_envelope_json jsonb,
    authority_envelope_fingerprint text,
    CONSTRAINT opportunity_human_reviews_authority_envelope_fingerprint_check CHECK (((authority_envelope_fingerprint IS NULL) OR (authority_envelope_fingerprint ~ '^[a-f0-9]{64}$'::text))),
    CONSTRAINT opportunity_human_reviews_authority_envelope_json_check CHECK (((authority_envelope_json IS NULL) OR (jsonb_typeof(authority_envelope_json) = 'object'::text))),
    CONSTRAINT opportunity_human_reviews_decision_check CHECK ((decision = ANY (ARRAY['APPROVE'::text, 'REJECT'::text, 'RETURN_TO_RESEARCH'::text]))),
    CONSTRAINT opportunity_human_reviews_prior_workflow_state_check CHECK (((prior_workflow_state IS NULL) OR (prior_workflow_state = ANY (ARRAY['RESEARCHING'::text, 'REVIEWABLE'::text, 'APPROVED'::text, 'REJECTED'::text, 'ENGAGED'::text, 'ARCHIVED'::text])))),
    CONSTRAINT opportunity_human_reviews_resulting_workflow_state_check CHECK (((resulting_workflow_state IS NULL) OR (resulting_workflow_state = ANY (ARRAY['RESEARCHING'::text, 'REVIEWABLE'::text, 'APPROVED'::text, 'REJECTED'::text, 'ENGAGED'::text, 'ARCHIVED'::text]))))
);

--
-- Name: opportunity_sync_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.opportunity_sync_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    request_id uuid NOT NULL,
    organisation_id uuid NOT NULL,
    campaign_id uuid NOT NULL,
    company_id uuid NOT NULL,
    opportunity_id uuid,
    outcome_code text NOT NULL,
    prior_workflow_state text,
    resulting_workflow_state text,
    authority_envelope_json jsonb NOT NULL,
    authority_envelope_fingerprint text NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT opportunity_sync_events_authority_envelope_fingerprint_check CHECK ((authority_envelope_fingerprint ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT opportunity_sync_events_authority_envelope_json_check CHECK ((jsonb_typeof(authority_envelope_json) = 'object'::text)),
    CONSTRAINT opportunity_sync_events_outcome_code_check CHECK ((outcome_code = ANY (ARRAY['NOT_MATERIALISED'::text, 'MATERIALISED_REVIEWABLE'::text, 'BECAME_REVIEWABLE'::text, 'BECAME_RESEARCHING'::text, 'UNCHANGED'::text, 'FOUNDER_RESEARCH_HOLD'::text]))),
    CONSTRAINT opportunity_sync_events_prior_workflow_state_check CHECK (((prior_workflow_state IS NULL) OR (prior_workflow_state = ANY (ARRAY['RESEARCHING'::text, 'REVIEWABLE'::text, 'APPROVED'::text, 'REJECTED'::text, 'ENGAGED'::text, 'ARCHIVED'::text])))),
    CONSTRAINT opportunity_sync_events_resulting_workflow_state_check CHECK (((resulting_workflow_state IS NULL) OR (resulting_workflow_state = ANY (ARRAY['RESEARCHING'::text, 'REVIEWABLE'::text, 'APPROVED'::text, 'REJECTED'::text, 'ENGAGED'::text, 'ARCHIVED'::text]))))
);

--
-- Name: opportunity_workflow_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.opportunity_workflow_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    opportunity_id uuid NOT NULL,
    organisation_id uuid NOT NULL,
    event_type text NOT NULL,
    prior_workflow_state text NOT NULL,
    resulting_workflow_state text NOT NULL,
    actor_user_id uuid,
    request_id uuid NOT NULL,
    reason_code text NOT NULL,
    authority_envelope_json jsonb NOT NULL,
    authority_envelope_fingerprint text NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT opportunity_workflow_events_authority_envelope_fingerprin_check CHECK ((authority_envelope_fingerprint ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT opportunity_workflow_events_authority_envelope_json_check CHECK ((jsonb_typeof(authority_envelope_json) = 'object'::text)),
    CONSTRAINT opportunity_workflow_events_event_type_check CHECK ((event_type = ANY (ARRAY['HUMAN_REVIEW'::text, 'SYSTEM_REVIEWABILITY'::text, 'ENGAGEMENT'::text, 'ARCHIVE'::text, 'RESTORE'::text]))),
    CONSTRAINT opportunity_workflow_events_prior_workflow_state_check CHECK ((prior_workflow_state = ANY (ARRAY['RESEARCHING'::text, 'REVIEWABLE'::text, 'APPROVED'::text, 'REJECTED'::text, 'ENGAGED'::text, 'ARCHIVED'::text]))),
    CONSTRAINT opportunity_workflow_events_resulting_workflow_state_check CHECK ((resulting_workflow_state = ANY (ARRAY['RESEARCHING'::text, 'REVIEWABLE'::text, 'APPROVED'::text, 'REJECTED'::text, 'ENGAGED'::text, 'ARCHIVED'::text])))
);

--
-- Name: organisation_commercial_entitlements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organisation_commercial_entitlements (
    organisation_id uuid NOT NULL,
    plan_code text NOT NULL,
    status text NOT NULL,
    source text NOT NULL,
    external_customer_id text,
    external_subscription_id text,
    current_period_start timestamp with time zone,
    current_period_end timestamp with time zone,
    activated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    metadata_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT organisation_commercial_entitlements_check CHECK (((current_period_end IS NULL) OR (current_period_start IS NULL) OR (current_period_end > current_period_start))),
    CONSTRAINT organisation_commercial_entitlements_metadata_json_check CHECK ((jsonb_typeof(metadata_json) = 'object'::text)),
    CONSTRAINT organisation_commercial_entitlements_source_check CHECK ((source = ANY (ARRAY['SYSTEM'::text, 'MANUAL'::text, 'BILLING'::text]))),
    CONSTRAINT organisation_commercial_entitlements_status_check CHECK ((status = ANY (ARRAY['ACTIVE'::text, 'PAST_DUE'::text, 'CANCELLED'::text, 'EXPIRED'::text])))
);

--
-- Name: organisation_company_scopes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organisation_company_scopes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organisation_id uuid NOT NULL,
    company_id uuid NOT NULL,
    campaign_id uuid,
    scope_kind text DEFAULT 'RESEARCH'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT organisation_company_scopes_check CHECK (((scope_kind <> 'CAMPAIGN'::text) OR (campaign_id IS NOT NULL))),
    CONSTRAINT organisation_company_scopes_scope_kind_check CHECK ((scope_kind = ANY (ARRAY['RESEARCH'::text, 'CAMPAIGN'::text, 'MIGRATION'::text, 'MANUAL'::text])))
);

--
-- Name: organisation_memberships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organisation_memberships (
    organisation_id uuid NOT NULL,
    user_id uuid NOT NULL,
    role text NOT NULL,
    status text DEFAULT 'ACTIVE'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT organisation_memberships_role_check CHECK ((role = ANY (ARRAY['OWNER'::text, 'ADMIN'::text, 'MEMBER'::text, 'VIEWER'::text]))),
    CONSTRAINT organisation_memberships_status_check CHECK ((status = ANY (ARRAY['ACTIVE'::text, 'INVITED'::text, 'DISABLED'::text])))
);

--
-- Name: organisations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organisations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    slug text NOT NULL,
    status text DEFAULT 'ACTIVE'::text NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    workspace_kind text DEFAULT 'CUSTOMER'::text NOT NULL,
    CONSTRAINT organisations_creator_kind_consistent CHECK ((((workspace_kind = 'CUSTOMER'::text) AND (created_by IS NOT NULL)) OR ((workspace_kind = 'ANONYMOUS_DISCOVERY'::text) AND (created_by IS NULL)))),
    CONSTRAINT organisations_name_check CHECK (((length(btrim(name)) >= 1) AND (length(btrim(name)) <= 160))),
    CONSTRAINT organisations_slug_check CHECK (((slug = lower(slug)) AND (slug ~ '^[a-z0-9][a-z0-9-]{1,62}$'::text))),
    CONSTRAINT organisations_status_check CHECK ((status = ANY (ARRAY['ACTIVE'::text, 'SUSPENDED'::text, 'CLOSED'::text]))),
    CONSTRAINT organisations_workspace_kind_valid CHECK ((workspace_kind = ANY (ARRAY['CUSTOMER'::text, 'ANONYMOUS_DISCOVERY'::text])))
);

--
-- Name: paid_campaign_refill_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.paid_campaign_refill_jobs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organisation_id uuid NOT NULL,
    campaign_id uuid NOT NULL,
    target_count integer DEFAULT 10 NOT NULL,
    candidate_ceiling integer DEFAULT 60 NOT NULL,
    status text NOT NULL,
    attempt_count integer DEFAULT 0 NOT NULL,
    available_at timestamp with time zone DEFAULT now() NOT NULL,
    worker_id text,
    lease_expires_at timestamp with time zone,
    last_error_code text,
    result_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT paid_campaign_refill_jobs_attempt_count_check CHECK (((attempt_count >= 0) AND (attempt_count <= 20))),
    CONSTRAINT paid_campaign_refill_jobs_candidate_ceiling_check CHECK (((candidate_ceiling >= 10) AND (candidate_ceiling <= 250))),
    CONSTRAINT paid_campaign_refill_jobs_result_json_check CHECK ((jsonb_typeof(result_json) = 'object'::text)),
    CONSTRAINT paid_campaign_refill_jobs_status_check CHECK ((status = ANY (ARRAY['PENDING'::text, 'RUNNING'::text, 'DEFERRED'::text, 'SUCCEEDED'::text, 'EXHAUSTED'::text, 'FAILED'::text]))),
    CONSTRAINT paid_campaign_refill_jobs_target_count_check CHECK (((target_count >= 1) AND (target_count <= 50)))
);

--
-- Name: people; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.people (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    display_name text NOT NULL,
    canonical_name text,
    lifecycle_state text DEFAULT 'ACTIVE'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT people_display_name_check CHECK (((length(btrim(display_name)) >= 1) AND (length(btrim(display_name)) <= 240))),
    CONSTRAINT people_lifecycle_state_check CHECK ((lifecycle_state = ANY (ARRAY['ACTIVE'::text, 'MERGED'::text, 'ARCHIVED'::text])))
);

--
-- Name: production_runtime_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.production_runtime_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    correlation_id uuid NOT NULL,
    runtime_kind text NOT NULL,
    event_type text NOT NULL,
    duration_ms integer,
    error_code text,
    metadata_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT production_runtime_events_duration_ms_check CHECK (((duration_ms IS NULL) OR (duration_ms >= 0))),
    CONSTRAINT production_runtime_events_event_type_check CHECK ((event_type = ANY (ARRAY['STARTED'::text, 'SUCCEEDED'::text, 'FAILED'::text, 'DISABLED'::text]))),
    CONSTRAINT production_runtime_events_metadata_json_check CHECK ((jsonb_typeof(metadata_json) = 'object'::text)),
    CONSTRAINT production_runtime_events_runtime_kind_check CHECK ((runtime_kind = ANY (ARRAY['BOOTSTRAP'::text, 'GROWTH'::text, 'RESEARCH'::text, 'DELIVERY'::text, 'PREFLIGHT'::text, 'SMOKE'::text])))
);

--
-- Name: reasoning_artifacts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reasoning_artifacts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    reasoning_run_id uuid NOT NULL,
    artifact_kind text NOT NULL,
    subject_type text NOT NULL,
    subject_id uuid NOT NULL,
    artifact_fingerprint text NOT NULL,
    payload_json jsonb NOT NULL,
    evaluated_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT reasoning_artifacts_artifact_fingerprint_check CHECK ((artifact_fingerprint ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT reasoning_artifacts_payload_json_check CHECK ((jsonb_typeof(payload_json) = 'object'::text))
);

--
-- Name: reasoning_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reasoning_runs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organisation_id uuid,
    campaign_id uuid,
    reasoning_kind text NOT NULL,
    engine_version text NOT NULL,
    input_fingerprint text NOT NULL,
    status text DEFAULT 'RUNNING'::text NOT NULL,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    completed_at timestamp with time zone,
    error_code text,
    metadata_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT reasoning_runs_check CHECK ((((status = 'RUNNING'::text) AND (completed_at IS NULL)) OR ((status <> 'RUNNING'::text) AND (completed_at IS NOT NULL)))),
    CONSTRAINT reasoning_runs_check1 CHECK (((campaign_id IS NULL) OR (organisation_id IS NOT NULL))),
    CONSTRAINT reasoning_runs_input_fingerprint_check CHECK ((input_fingerprint ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT reasoning_runs_metadata_json_check CHECK ((jsonb_typeof(metadata_json) = 'object'::text)),
    CONSTRAINT reasoning_runs_reasoning_kind_check CHECK ((reasoning_kind = ANY (ARRAY['TRUTH'::text, 'SELLER_GENOME'::text, 'COMMERCIAL_REALITY'::text, 'RELATIONSHIP_GRAPH'::text, 'CONTACT_TRUTH'::text, 'RESEARCH_PLAN'::text, 'ENGAGEMENT_REVIEW'::text, 'OTHER'::text]))),
    CONSTRAINT reasoning_runs_status_check CHECK ((status = ANY (ARRAY['RUNNING'::text, 'SUCCEEDED'::text, 'FAILED'::text, 'CANCELLED'::text])))
);

--
-- Name: research_budget_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.research_budget_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organisation_id uuid NOT NULL,
    campaign_id uuid NOT NULL,
    work_unit_id uuid NOT NULL,
    scheduler_run_id uuid,
    attempt_number integer NOT NULL,
    event_type text NOT NULL,
    amount_usd numeric(18,8) NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    metadata_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT research_budget_events_amount_usd_check CHECK ((amount_usd >= (0)::numeric)),
    CONSTRAINT research_budget_events_attempt_number_check CHECK ((attempt_number > 0)),
    CONSTRAINT research_budget_events_event_type_check CHECK ((event_type = ANY (ARRAY['RESERVE'::text, 'COMMIT'::text, 'RELEASE'::text]))),
    CONSTRAINT research_budget_events_metadata_json_check CHECK ((jsonb_typeof(metadata_json) = 'object'::text))
);

--
-- Name: research_budget_policies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.research_budget_policies (
    organisation_id uuid NOT NULL,
    campaign_id uuid NOT NULL,
    daily_budget_usd numeric(18,8) NOT NULL,
    max_job_cost_usd numeric(18,8) NOT NULL,
    max_concurrent_jobs integer NOT NULL,
    max_work_units_per_plan integer NOT NULL,
    refresh_horizon_hours integer NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    policy_version text DEFAULT 'MRV2-RESEARCH-BUDGET-1.0.0'::text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT research_budget_policies_check CHECK (((max_job_cost_usd >= (0)::numeric) AND (max_job_cost_usd <= daily_budget_usd))),
    CONSTRAINT research_budget_policies_daily_budget_usd_check CHECK (((daily_budget_usd >= (0)::numeric) AND (daily_budget_usd <= (100000)::numeric))),
    CONSTRAINT research_budget_policies_max_concurrent_jobs_check CHECK (((max_concurrent_jobs >= 0) AND (max_concurrent_jobs <= 100))),
    CONSTRAINT research_budget_policies_max_work_units_per_plan_check CHECK (((max_work_units_per_plan >= 0) AND (max_work_units_per_plan <= 100))),
    CONSTRAINT research_budget_policies_refresh_horizon_hours_check CHECK (((refresh_horizon_hours >= 0) AND (refresh_horizon_hours <= 168)))
);

--
-- Name: research_plan_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.research_plan_runs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organisation_id uuid NOT NULL,
    campaign_id uuid NOT NULL,
    company_id uuid NOT NULL,
    reference_time timestamp with time zone NOT NULL,
    lifecycle_state text NOT NULL,
    authority_envelope_fingerprint text NOT NULL,
    planner_version text NOT NULL,
    semantics_version text NOT NULL,
    gap_set_fingerprint text NOT NULL,
    gap_context_json jsonb NOT NULL,
    work_units_json jsonb NOT NULL,
    budget_policy_snapshot_json jsonb NOT NULL,
    budget_snapshot_json jsonb NOT NULL,
    plan_fingerprint text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT research_plan_runs_authority_envelope_fingerprint_check CHECK ((authority_envelope_fingerprint ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT research_plan_runs_budget_policy_snapshot_json_check CHECK ((jsonb_typeof(budget_policy_snapshot_json) = 'object'::text)),
    CONSTRAINT research_plan_runs_budget_snapshot_json_check CHECK ((jsonb_typeof(budget_snapshot_json) = 'object'::text)),
    CONSTRAINT research_plan_runs_gap_context_json_check CHECK ((jsonb_typeof(gap_context_json) = 'object'::text)),
    CONSTRAINT research_plan_runs_gap_set_fingerprint_check CHECK ((gap_set_fingerprint ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT research_plan_runs_plan_fingerprint_check CHECK ((plan_fingerprint ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT research_plan_runs_work_units_json_check CHECK ((jsonb_typeof(work_units_json) = 'array'::text))
);

--
-- Name: research_work_units; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.research_work_units (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    plan_id uuid NOT NULL,
    organisation_id uuid NOT NULL,
    campaign_id uuid NOT NULL,
    company_id uuid NOT NULL,
    ordinal integer NOT NULL,
    gap_key text NOT NULL,
    layer text NOT NULL,
    tier text NOT NULL,
    action text NOT NULL,
    subject_type text NOT NULL,
    subject_id text NOT NULL,
    claim_key text,
    reason_code text NOT NULL,
    query_hints_json jsonb NOT NULL,
    payload_json jsonb NOT NULL,
    cost_ceiling_usd numeric(18,8) NOT NULL,
    dedupe_key text NOT NULL,
    background_job_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT research_work_units_action_check CHECK ((action = ANY (ARRAY['ACQUIRE_CLAIM_EVIDENCE'::text, 'DISCOVER_ROUTE_STRUCTURE'::text, 'RESEARCH_CONTACT_BINDING'::text, 'REVALIDATE_R4'::text, 'REVALIDATE_R5'::text, 'REVALIDATE_R6'::text]))),
    CONSTRAINT research_work_units_cost_ceiling_usd_check CHECK ((cost_ceiling_usd >= (0)::numeric)),
    CONSTRAINT research_work_units_dedupe_key_check CHECK ((dedupe_key ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT research_work_units_layer_check CHECK ((layer = ANY (ARRAY['R4'::text, 'R5'::text, 'R6'::text]))),
    CONSTRAINT research_work_units_ordinal_check CHECK ((ordinal > 0)),
    CONSTRAINT research_work_units_payload_json_check CHECK ((jsonb_typeof(payload_json) = 'object'::text)),
    CONSTRAINT research_work_units_query_hints_json_check CHECK ((jsonb_typeof(query_hints_json) = 'array'::text)),
    CONSTRAINT research_work_units_subject_type_check CHECK ((subject_type = ANY (ARRAY['COMPANY'::text, 'PERSON'::text, 'RELATIONSHIP'::text, 'CHANNEL'::text, 'CAMPAIGN'::text]))),
    CONSTRAINT research_work_units_tier_check CHECK ((tier = ANY (ARRAY['DECISION_BLOCKER'::text, 'CURRENTNESS_REPAIR'::text, 'EXPIRING_SOON'::text, 'ENRICHMENT'::text])))
);

--
-- Name: scheduler_leases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.scheduler_leases (
    lease_key text NOT NULL,
    owner_run_id uuid NOT NULL,
    acquired_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    heartbeat_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT scheduler_leases_check CHECK ((expires_at > acquired_at))
);

--
-- Name: scheduler_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.scheduler_runs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    runner_key text NOT NULL,
    status text DEFAULT 'RUNNING'::text NOT NULL,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    completed_at timestamp with time zone,
    metadata_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT scheduler_runs_metadata_json_check CHECK ((jsonb_typeof(metadata_json) = 'object'::text)),
    CONSTRAINT scheduler_runs_status_check CHECK ((status = ANY (ARRAY['RUNNING'::text, 'SUCCEEDED'::text, 'PARTIAL'::text, 'FAILED'::text, 'CANCELLED'::text])))
);

--
-- Name: seller_businesses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.seller_businesses (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organisation_id uuid NOT NULL,
    name text NOT NULL,
    canonical_domain text,
    website_url text,
    lifecycle_state text DEFAULT 'ACTIVE'::text NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT seller_businesses_canonical_domain_check CHECK (((canonical_domain IS NULL) OR (canonical_domain = lower(canonical_domain)))),
    CONSTRAINT seller_businesses_lifecycle_state_check CHECK ((lifecycle_state = ANY (ARRAY['ACTIVE'::text, 'ARCHIVED'::text]))),
    CONSTRAINT seller_businesses_name_check CHECK (((length(btrim(name)) >= 1) AND (length(btrim(name)) <= 200)))
);

--
-- Name: seller_commercial_genome_snapshots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.seller_commercial_genome_snapshots (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organisation_id uuid NOT NULL,
    seller_business_id uuid NOT NULL,
    source_material_id uuid NOT NULL,
    schema_version text NOT NULL,
    canonicalisation_version text NOT NULL,
    extraction_contract_version text NOT NULL,
    extractor_version text NOT NULL,
    canonical_genome_json jsonb NOT NULL,
    content_fingerprint text NOT NULL,
    semantic_fingerprint text NOT NULL,
    semantic_completeness text NOT NULL,
    missing_dimensions text[] DEFAULT '{}'::text[] NOT NULL,
    explicit_unknown_count integer NOT NULL,
    offering_count integer NOT NULL,
    objective_count integer NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT seller_commercial_genome_snap_extraction_contract_version_check CHECK ((extraction_contract_version = 'MRV2-SELLER-EXTRACT-1.0.0'::text)),
    CONSTRAINT seller_commercial_genome_snapsho_canonicalisation_version_check CHECK ((canonicalisation_version = 'MRV2-SELLER-CANON-1.0.0'::text)),
    CONSTRAINT seller_commercial_genome_snapshots_canonical_genome_json_check CHECK ((jsonb_typeof(canonical_genome_json) = 'object'::text)),
    CONSTRAINT seller_commercial_genome_snapshots_content_fingerprint_check CHECK ((content_fingerprint ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT seller_commercial_genome_snapshots_explicit_unknown_count_check CHECK ((explicit_unknown_count >= 0)),
    CONSTRAINT seller_commercial_genome_snapshots_extractor_version_check CHECK (((length(btrim(extractor_version)) >= 1) AND (length(btrim(extractor_version)) <= 160))),
    CONSTRAINT seller_commercial_genome_snapshots_objective_count_check CHECK ((objective_count >= 0)),
    CONSTRAINT seller_commercial_genome_snapshots_offering_count_check CHECK ((offering_count >= 0)),
    CONSTRAINT seller_commercial_genome_snapshots_schema_version_check CHECK ((schema_version = 'MRV2-SELLER-GENOME-1.0.0'::text)),
    CONSTRAINT seller_commercial_genome_snapshots_semantic_completeness_check CHECK ((semantic_completeness = ANY (ARRAY['COMPLETE'::text, 'PARTIAL'::text]))),
    CONSTRAINT seller_commercial_genome_snapshots_semantic_fingerprint_check CHECK ((semantic_fingerprint ~ '^[a-f0-9]{64}$'::text))
);

--
-- Name: seller_genome_source_materials; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.seller_genome_source_materials (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organisation_id uuid NOT NULL,
    seller_business_id uuid NOT NULL,
    material_kind text NOT NULL,
    material_version text DEFAULT 'MRV2-SELLER-SOURCE-1.0.0'::text NOT NULL,
    content_json jsonb NOT NULL,
    material_fingerprint text NOT NULL,
    created_by_user_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT seller_genome_source_materials_content_json_check CHECK ((jsonb_typeof(content_json) = ANY (ARRAY['object'::text, 'array'::text, 'string'::text]))),
    CONSTRAINT seller_genome_source_materials_material_fingerprint_check CHECK ((material_fingerprint ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT seller_genome_source_materials_material_kind_check CHECK ((material_kind = ANY (ARRAY['USER_DECLARED'::text, 'WEBSITE_ANALYSIS'::text, 'IMPORT'::text, 'COMPOSITE'::text])))
);

--
-- Name: source_acquisitions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.source_acquisitions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    source_id uuid NOT NULL,
    acquired_at timestamp with time zone DEFAULT now() NOT NULL,
    acquisition_method text NOT NULL,
    observed_content_fingerprint text,
    http_status integer,
    raw_locator text,
    parser_version text,
    request_id text,
    metadata_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT source_acquisitions_acquisition_method_check CHECK ((acquisition_method = ANY (ARRAY['WEB_FETCH'::text, 'SEARCH_RESULT'::text, 'API'::text, 'IMPORT'::text, 'USER_UPLOAD'::text, 'MANUAL'::text]))),
    CONSTRAINT source_acquisitions_http_status_check CHECK (((http_status IS NULL) OR ((http_status >= 100) AND (http_status <= 599)))),
    CONSTRAINT source_acquisitions_metadata_json_check CHECK ((jsonb_typeof(metadata_json) = 'object'::text)),
    CONSTRAINT source_acquisitions_observed_content_fingerprint_shape CHECK (((observed_content_fingerprint IS NULL) OR (observed_content_fingerprint ~ '^[a-f0-9]{64}$'::text)))
);

--
-- Name: source_records; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.source_records (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    source_kind text NOT NULL,
    canonical_url text,
    publisher_domain text,
    title text,
    published_at timestamp with time zone,
    first_observed_at timestamp with time zone DEFAULT now() NOT NULL,
    last_observed_at timestamp with time zone DEFAULT now() NOT NULL,
    content_fingerprint text,
    metadata_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    source_identity_fingerprint text NOT NULL,
    stable_locator text NOT NULL,
    dependence_family_key text NOT NULL,
    normalisation_version text NOT NULL,
    CONSTRAINT source_records_check CHECK ((last_observed_at >= first_observed_at)),
    CONSTRAINT source_records_dependence_family_nonempty CHECK ((length(btrim(dependence_family_key)) > 0)),
    CONSTRAINT source_records_identity_fingerprint_shape CHECK ((source_identity_fingerprint ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT source_records_metadata_json_check CHECK ((jsonb_typeof(metadata_json) = 'object'::text)),
    CONSTRAINT source_records_normalisation_version_nonempty CHECK ((length(btrim(normalisation_version)) > 0)),
    CONSTRAINT source_records_publisher_domain_check CHECK (((publisher_domain IS NULL) OR (publisher_domain = lower(publisher_domain)))),
    CONSTRAINT source_records_source_kind_check CHECK ((source_kind = ANY (ARRAY['WEB'::text, 'DOCUMENT'::text, 'API'::text, 'REGISTRY'::text, 'USER_PROVIDED'::text, 'INTERNAL'::text, 'OTHER'::text])))
);

--
-- Name: truth_claim_policy_bindings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.truth_claim_policy_bindings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    subject_type text NOT NULL,
    claim_key text NOT NULL,
    policy_key text NOT NULL,
    precedence integer NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT truth_claim_policy_bindings_claim_key_check CHECK ((length(btrim(claim_key)) > 0)),
    CONSTRAINT truth_claim_policy_bindings_precedence_check CHECK (((precedence >= 1) AND (precedence <= 10000))),
    CONSTRAINT truth_claim_policy_bindings_subject_type_check CHECK (((subject_type = '*'::text) OR (subject_type = ANY (ARRAY['COMPANY'::text, 'PERSON'::text, 'SELLER_BUSINESS'::text, 'CAMPAIGN'::text, 'RELATIONSHIP'::text, 'CHANNEL'::text, 'OTHER'::text]))))
);

--
-- Name: truth_claim_policy_registry; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.truth_claim_policy_registry (
    policy_key text NOT NULL,
    policy_version text NOT NULL,
    max_age_days integer NOT NULL,
    known_support_family_requirement integer NOT NULL,
    active boolean DEFAULT true NOT NULL,
    metadata_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    registered_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT truth_claim_policy_registry_known_support_family_requirem_check CHECK ((known_support_family_requirement >= 2)),
    CONSTRAINT truth_claim_policy_registry_max_age_days_check CHECK (((max_age_days >= 1) AND (max_age_days <= 3650))),
    CONSTRAINT truth_claim_policy_registry_metadata_json_check CHECK ((jsonb_typeof(metadata_json) = 'object'::text))
);

--
-- Name: truth_entity_profile_registry; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.truth_entity_profile_registry (
    profile_key text NOT NULL,
    profile_version text NOT NULL,
    subject_type text NOT NULL,
    required_claim_keys jsonb NOT NULL,
    active boolean DEFAULT true NOT NULL,
    metadata_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    registered_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT truth_entity_profile_registry_metadata_json_check CHECK ((jsonb_typeof(metadata_json) = 'object'::text)),
    CONSTRAINT truth_entity_profile_registry_required_claim_keys_check CHECK (((jsonb_typeof(required_claim_keys) = 'array'::text) AND (jsonb_array_length(required_claim_keys) > 0))),
    CONSTRAINT truth_entity_profile_registry_subject_type_check CHECK ((subject_type = ANY (ARRAY['COMPANY'::text, 'PERSON'::text, 'SELLER_BUSINESS'::text, 'CAMPAIGN'::text, 'RELATIONSHIP'::text, 'CHANNEL'::text, 'OTHER'::text])))
);

--
-- Name: workspace_activation_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.workspace_activation_jobs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organisation_id uuid NOT NULL,
    seller_business_id uuid NOT NULL,
    objective_text text NOT NULL,
    target_market_text text NOT NULL,
    hard_constraints_text text,
    no_hard_constraints boolean DEFAULT false NOT NULL,
    status text DEFAULT 'PENDING'::text NOT NULL,
    attempt_count integer DEFAULT 0 NOT NULL,
    available_at timestamp with time zone DEFAULT now() NOT NULL,
    worker_id text,
    lease_expires_at timestamp with time zone,
    last_error_code text,
    result_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    seller_offering_text text,
    campaign_name text,
    activation_stage text DEFAULT 'QUEUED'::text NOT NULL,
    activation_progress integer DEFAULT 5 NOT NULL,
    activation_stage_detail_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    activation_kind text DEFAULT 'WORKSPACE_INITIAL'::text NOT NULL,
    CONSTRAINT workspace_activation_campaign_name_length CHECK (((campaign_name IS NULL) OR ((length(btrim(campaign_name)) >= 3) AND (length(btrim(campaign_name)) <= 120)))),
    CONSTRAINT workspace_activation_jobs_attempt_count_check CHECK ((attempt_count >= 0)),
    CONSTRAINT workspace_activation_jobs_check CHECK ((no_hard_constraints OR (NULLIF(btrim(COALESCE(hard_constraints_text, ''::text)), ''::text) IS NOT NULL))),
    CONSTRAINT workspace_activation_jobs_objective_text_check CHECK (((length(btrim(objective_text)) >= 8) AND (length(btrim(objective_text)) <= 2000))),
    CONSTRAINT workspace_activation_jobs_result_json_check CHECK ((jsonb_typeof(result_json) = 'object'::text)),
    CONSTRAINT workspace_activation_jobs_status_check CHECK ((status = ANY (ARRAY['PENDING'::text, 'RUNNING'::text, 'FAILED'::text, 'NEEDS_INPUT'::text, 'SUCCEEDED'::text]))),
    CONSTRAINT workspace_activation_jobs_target_market_text_check CHECK (((length(btrim(target_market_text)) >= 3) AND (length(btrim(target_market_text)) <= 2000))),
    CONSTRAINT workspace_activation_kind_valid CHECK ((activation_kind = ANY (ARRAY['WORKSPACE_INITIAL'::text, 'ANONYMOUS_DISCOVERY'::text, 'CUSTOMER_CAMPAIGN'::text]))),
    CONSTRAINT workspace_activation_progress_valid CHECK (((activation_progress >= 0) AND (activation_progress <= 100))),
    CONSTRAINT workspace_activation_seller_offering_length CHECK (((seller_offering_text IS NULL) OR ((length(btrim(seller_offering_text)) >= 8) AND (length(btrim(seller_offering_text)) <= 2000)))),
    CONSTRAINT workspace_activation_stage_detail_object CHECK ((jsonb_typeof(activation_stage_detail_json) = 'object'::text)),
    CONSTRAINT workspace_activation_stage_valid CHECK ((activation_stage = ANY (ARRAY['QUEUED'::text, 'ANALYSING_SELLER'::text, 'SELLER_CONTEXT_READY'::text, 'CREATING_CAMPAIGN'::text, 'CAMPAIGN_CREATED'::text, 'SELECTING_TARGETS'::text, 'DISCOVERING_TARGETS'::text, 'LINKING_COMPANIES'::text, 'FINALISING'::text, 'READY'::text, 'FAILED'::text])))
);

--
-- Name: ai_usage_events ai_usage_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_usage_events
    ADD CONSTRAINT ai_usage_events_pkey PRIMARY KEY (id);

--
-- Name: anonymous_discovery_extension_jobs anonymous_discovery_extension_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anonymous_discovery_extension_jobs
    ADD CONSTRAINT anonymous_discovery_extension_jobs_pkey PRIMARY KEY (id);

--
-- Name: anonymous_discovery_extension_jobs anonymous_discovery_extension_jobs_run_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anonymous_discovery_extension_jobs
    ADD CONSTRAINT anonymous_discovery_extension_jobs_run_id_key UNIQUE (run_id);

--
-- Name: anonymous_discovery_opportunity_unlocks anonymous_discovery_opportunity_unlocks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anonymous_discovery_opportunity_unlocks
    ADD CONSTRAINT anonymous_discovery_opportunity_unlocks_pkey PRIMARY KEY (run_id, opportunity_id);

--
-- Name: anonymous_discovery_opportunity_unlocks anonymous_discovery_opportunity_unlocks_run_id_ordinal_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anonymous_discovery_opportunity_unlocks
    ADD CONSTRAINT anonymous_discovery_opportunity_unlocks_run_id_ordinal_key UNIQUE (run_id, ordinal);

--
-- Name: anonymous_discovery_runs anonymous_discovery_runs_activation_job_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anonymous_discovery_runs
    ADD CONSTRAINT anonymous_discovery_runs_activation_job_id_key UNIQUE (activation_job_id);

--
-- Name: anonymous_discovery_runs anonymous_discovery_runs_browser_key_hash_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anonymous_discovery_runs
    ADD CONSTRAINT anonymous_discovery_runs_browser_key_hash_key UNIQUE (browser_key_hash);

--
-- Name: anonymous_discovery_runs anonymous_discovery_runs_organisation_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anonymous_discovery_runs
    ADD CONSTRAINT anonymous_discovery_runs_organisation_id_key UNIQUE (organisation_id);

--
-- Name: anonymous_discovery_runs anonymous_discovery_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anonymous_discovery_runs
    ADD CONSTRAINT anonymous_discovery_runs_pkey PRIMARY KEY (id);

--
-- Name: anonymous_discovery_runs anonymous_discovery_runs_seller_business_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anonymous_discovery_runs
    ADD CONSTRAINT anonymous_discovery_runs_seller_business_id_key UNIQUE (seller_business_id);

--
-- Name: audit_events audit_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT audit_events_pkey PRIMARY KEY (id);

--
-- Name: authority_events authority_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.authority_events
    ADD CONSTRAINT authority_events_pkey PRIMARY KEY (id);

--
-- Name: authority_records authority_records_authority_stage_subject_type_subject_id_a_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.authority_records
    ADD CONSTRAINT authority_records_authority_stage_subject_type_subject_id_a_key UNIQUE (authority_stage, subject_type, subject_id, authority_fingerprint);

--
-- Name: authority_records authority_records_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.authority_records
    ADD CONSTRAINT authority_records_pkey PRIMARY KEY (id);

--
-- Name: authority_writer_registry authority_writer_registry_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.authority_writer_registry
    ADD CONSTRAINT authority_writer_registry_pkey PRIMARY KEY (writer_key);

--
-- Name: background_job_attempts background_job_attempts_job_id_attempt_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.background_job_attempts
    ADD CONSTRAINT background_job_attempts_job_id_attempt_number_key UNIQUE (job_id, attempt_number);

--
-- Name: background_job_attempts background_job_attempts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.background_job_attempts
    ADD CONSTRAINT background_job_attempts_pkey PRIMARY KEY (id);

--
-- Name: background_jobs background_jobs_job_type_dedupe_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.background_jobs
    ADD CONSTRAINT background_jobs_job_type_dedupe_key_key UNIQUE (job_type, dedupe_key);

--
-- Name: background_jobs background_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.background_jobs
    ADD CONSTRAINT background_jobs_pkey PRIMARY KEY (id);

--
-- Name: campaign_engagement_policy_events campaign_engagement_policy_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.campaign_engagement_policy_events
    ADD CONSTRAINT campaign_engagement_policy_events_pkey PRIMARY KEY (id);

--
-- Name: campaign_engagement_policy_events campaign_engagement_policy_events_request_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.campaign_engagement_policy_events
    ADD CONSTRAINT campaign_engagement_policy_events_request_id_key UNIQUE (request_id);

--
-- Name: campaign_seller_context_selections campaign_seller_context_selections_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.campaign_seller_context_selections
    ADD CONSTRAINT campaign_seller_context_selections_pkey PRIMARY KEY (id);

--
-- Name: campaign_seller_context_selections campaign_seller_context_selections_selection_request_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.campaign_seller_context_selections
    ADD CONSTRAINT campaign_seller_context_selections_selection_request_id_key UNIQUE (selection_request_id);

--
-- Name: campaign_workflow_events campaign_workflow_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.campaign_workflow_events
    ADD CONSTRAINT campaign_workflow_events_pkey PRIMARY KEY (id);

--
-- Name: campaigns campaigns_organisation_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.campaigns
    ADD CONSTRAINT campaigns_organisation_id_id_key UNIQUE (organisation_id, id);

--
-- Name: campaigns campaigns_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.campaigns
    ADD CONSTRAINT campaigns_pkey PRIMARY KEY (id);

--
-- Name: claim_evidence_links claim_evidence_links_claim_id_evidence_item_id_polarity_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.claim_evidence_links
    ADD CONSTRAINT claim_evidence_links_claim_id_evidence_item_id_polarity_key UNIQUE (claim_id, evidence_item_id, polarity);

--
-- Name: claim_evidence_links claim_evidence_links_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.claim_evidence_links
    ADD CONSTRAINT claim_evidence_links_pkey PRIMARY KEY (id);

--
-- Name: claim_supersessions claim_supersessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.claim_supersessions
    ADD CONSTRAINT claim_supersessions_pkey PRIMARY KEY (id);

--
-- Name: claim_supersessions claim_supersessions_prior_claim_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.claim_supersessions
    ADD CONSTRAINT claim_supersessions_prior_claim_id_key UNIQUE (prior_claim_id);

--
-- Name: claims claims_claim_fingerprint_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.claims
    ADD CONSTRAINT claims_claim_fingerprint_key UNIQUE (claim_fingerprint);

--
-- Name: claims claims_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.claims
    ADD CONSTRAINT claims_pkey PRIMARY KEY (id);

--
-- Name: commercial_graph_nodes commercial_graph_nodes_node_fingerprint_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_graph_nodes
    ADD CONSTRAINT commercial_graph_nodes_node_fingerprint_key UNIQUE (node_fingerprint);

--
-- Name: commercial_graph_nodes commercial_graph_nodes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_graph_nodes
    ADD CONSTRAINT commercial_graph_nodes_pkey PRIMARY KEY (id);

--
-- Name: commercial_reality_boundary_constitutions commercial_reality_boundary_constitutions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_reality_boundary_constitutions
    ADD CONSTRAINT commercial_reality_boundary_constitutions_pkey PRIMARY KEY (constitution_key);

--
-- Name: commercial_reality_r4_records commercial_reality_r4_records_authority_record_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_reality_r4_records
    ADD CONSTRAINT commercial_reality_r4_records_authority_record_id_key UNIQUE (authority_record_id);

--
-- Name: commercial_reality_r4_records commercial_reality_r4_records_organisation_id_campaign_id_c_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_reality_r4_records
    ADD CONSTRAINT commercial_reality_r4_records_organisation_id_campaign_id_c_key UNIQUE (organisation_id, campaign_id, company_id, input_fingerprint);

--
-- Name: commercial_reality_r4_records commercial_reality_r4_records_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_reality_r4_records
    ADD CONSTRAINT commercial_reality_r4_records_pkey PRIMARY KEY (id);

--
-- Name: commercial_relationship_type_registry commercial_relationship_type_registry_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_relationship_type_registry
    ADD CONSTRAINT commercial_relationship_type_registry_pkey PRIMARY KEY (relation_type);

--
-- Name: commercial_relationships commercial_relationships_claim_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_relationships
    ADD CONSTRAINT commercial_relationships_claim_id_key UNIQUE (claim_id);

--
-- Name: commercial_relationships commercial_relationships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_relationships
    ADD CONSTRAINT commercial_relationships_pkey PRIMARY KEY (id);

--
-- Name: commercial_relationships commercial_relationships_relationship_fingerprint_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_relationships
    ADD CONSTRAINT commercial_relationships_relationship_fingerprint_key UNIQUE (relationship_fingerprint);

--
-- Name: companies companies_canonical_domain_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.companies
    ADD CONSTRAINT companies_canonical_domain_key UNIQUE (canonical_domain);

--
-- Name: companies companies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.companies
    ADD CONSTRAINT companies_pkey PRIMARY KEY (id);

--
-- Name: contact_authority_r6_records contact_authority_r6_records_authority_record_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contact_authority_r6_records
    ADD CONSTRAINT contact_authority_r6_records_authority_record_id_key UNIQUE (authority_record_id);

--
-- Name: contact_authority_r6_records contact_authority_r6_records_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contact_authority_r6_records
    ADD CONSTRAINT contact_authority_r6_records_pkey PRIMARY KEY (id);

--
-- Name: engagement_ai_reviews engagement_ai_reviews_message_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_ai_reviews
    ADD CONSTRAINT engagement_ai_reviews_message_id_key UNIQUE (message_id);

--
-- Name: engagement_ai_reviews engagement_ai_reviews_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_ai_reviews
    ADD CONSTRAINT engagement_ai_reviews_pkey PRIMARY KEY (id);

--
-- Name: engagement_ai_reviews engagement_ai_reviews_review_fingerprint_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_ai_reviews
    ADD CONSTRAINT engagement_ai_reviews_review_fingerprint_key UNIQUE (review_fingerprint);

--
-- Name: engagement_ai_reviews engagement_ai_reviews_review_request_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_ai_reviews
    ADD CONSTRAINT engagement_ai_reviews_review_request_id_key UNIQUE (review_request_id);

--
-- Name: engagement_delivery_events engagement_delivery_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_delivery_events
    ADD CONSTRAINT engagement_delivery_events_pkey PRIMARY KEY (id);

--
-- Name: engagement_delivery_jobs engagement_delivery_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_delivery_jobs
    ADD CONSTRAINT engagement_delivery_jobs_pkey PRIMARY KEY (id);

--
-- Name: engagement_delivery_jobs engagement_delivery_jobs_queue_item_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_delivery_jobs
    ADD CONSTRAINT engagement_delivery_jobs_queue_item_id_key UNIQUE (queue_item_id);

--
-- Name: engagement_manual_actions engagement_manual_actions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_manual_actions
    ADD CONSTRAINT engagement_manual_actions_pkey PRIMARY KEY (id);

--
-- Name: engagement_manual_actions engagement_manual_actions_request_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_manual_actions
    ADD CONSTRAINT engagement_manual_actions_request_id_key UNIQUE (request_id);

--
-- Name: engagement_message_approvals engagement_message_approvals_approval_request_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_message_approvals
    ADD CONSTRAINT engagement_message_approvals_approval_request_id_key UNIQUE (approval_request_id);

--
-- Name: engagement_message_approvals engagement_message_approvals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_message_approvals
    ADD CONSTRAINT engagement_message_approvals_pkey PRIMARY KEY (id);

--
-- Name: engagement_messages engagement_messages_generation_request_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_messages
    ADD CONSTRAINT engagement_messages_generation_request_id_key UNIQUE (generation_request_id);

--
-- Name: engagement_messages engagement_messages_message_fingerprint_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_messages
    ADD CONSTRAINT engagement_messages_message_fingerprint_key UNIQUE (message_fingerprint);

--
-- Name: engagement_messages engagement_messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_messages
    ADD CONSTRAINT engagement_messages_pkey PRIMARY KEY (id);

--
-- Name: engagement_queue_items engagement_queue_items_message_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_queue_items
    ADD CONSTRAINT engagement_queue_items_message_id_key UNIQUE (message_id);

--
-- Name: engagement_queue_items engagement_queue_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_queue_items
    ADD CONSTRAINT engagement_queue_items_pkey PRIMARY KEY (id);

--
-- Name: engagement_queue_items engagement_queue_items_queue_request_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_queue_items
    ADD CONSTRAINT engagement_queue_items_queue_request_id_key UNIQUE (queue_request_id);

--
-- Name: engagement_strategies engagement_strategies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_strategies
    ADD CONSTRAINT engagement_strategies_pkey PRIMARY KEY (id);

--
-- Name: engagement_strategies engagement_strategies_request_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_strategies
    ADD CONSTRAINT engagement_strategies_request_id_key UNIQUE (request_id);

--
-- Name: engagement_strategies engagement_strategies_strategy_fingerprint_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_strategies
    ADD CONSTRAINT engagement_strategies_strategy_fingerprint_key UNIQUE (strategy_fingerprint);

--
-- Name: evidence_items evidence_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evidence_items
    ADD CONSTRAINT evidence_items_pkey PRIMARY KEY (id);

--
-- Name: genesis_growth_action_runs genesis_growth_action_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.genesis_growth_action_runs
    ADD CONSTRAINT genesis_growth_action_runs_pkey PRIMARY KEY (id);

--
-- Name: genesis_growth_budget_events genesis_growth_budget_events_action_run_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.genesis_growth_budget_events
    ADD CONSTRAINT genesis_growth_budget_events_action_run_id_key UNIQUE (action_run_id);

--
-- Name: genesis_growth_budget_events genesis_growth_budget_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.genesis_growth_budget_events
    ADD CONSTRAINT genesis_growth_budget_events_pkey PRIMARY KEY (id);

--
-- Name: genesis_growth_company_memberships genesis_growth_company_memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.genesis_growth_company_memberships
    ADD CONSTRAINT genesis_growth_company_memberships_pkey PRIMARY KEY (industry_key, company_id);

--
-- Name: genesis_growth_company_progress genesis_growth_company_progress_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.genesis_growth_company_progress
    ADD CONSTRAINT genesis_growth_company_progress_pkey PRIMARY KEY (company_id);

--
-- Name: genesis_growth_industries genesis_growth_industries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.genesis_growth_industries
    ADD CONSTRAINT genesis_growth_industries_pkey PRIMARY KEY (industry_key);

--
-- Name: genesis_growth_people genesis_growth_people_company_id_person_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.genesis_growth_people
    ADD CONSTRAINT genesis_growth_people_company_id_person_id_key UNIQUE (company_id, person_id);

--
-- Name: genesis_growth_people genesis_growth_people_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.genesis_growth_people
    ADD CONSTRAINT genesis_growth_people_pkey PRIMARY KEY (identity_key);

--
-- Name: genesis_growth_settings genesis_growth_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.genesis_growth_settings
    ADD CONSTRAINT genesis_growth_settings_pkey PRIMARY KEY (singleton);

--
-- Name: marketroute_billing_checkout_attempts marketroute_billing_checkout_attempts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.marketroute_billing_checkout_attempts
    ADD CONSTRAINT marketroute_billing_checkout_attempts_pkey PRIMARY KEY (id);

--
-- Name: marketroute_billing_events marketroute_billing_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.marketroute_billing_events
    ADD CONSTRAINT marketroute_billing_events_pkey PRIMARY KEY (external_event_id);

--
-- Name: marketroute_conversation_narration_cache marketroute_conversation_narr_scope_kind_scope_key_input_fi_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.marketroute_conversation_narration_cache
    ADD CONSTRAINT marketroute_conversation_narr_scope_kind_scope_key_input_fi_key UNIQUE (scope_kind, scope_key, input_fingerprint, contract_version);

--
-- Name: marketroute_conversation_narration_cache marketroute_conversation_narration_cache_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.marketroute_conversation_narration_cache
    ADD CONSTRAINT marketroute_conversation_narration_cache_pkey PRIMARY KEY (id);

--
-- Name: marketroute_plan_catalog marketroute_plan_catalog_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.marketroute_plan_catalog
    ADD CONSTRAINT marketroute_plan_catalog_pkey PRIMARY KEY (plan_code);

--
-- Name: marketroute_schema_releases marketroute_schema_releases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.marketroute_schema_releases
    ADD CONSTRAINT marketroute_schema_releases_pkey PRIMARY KEY (release_key);

--
-- Name: opportunities opportunities_campaign_id_company_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opportunities
    ADD CONSTRAINT opportunities_campaign_id_company_id_key UNIQUE (campaign_id, company_id);

--
-- Name: opportunities opportunities_id_organisation_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opportunities
    ADD CONSTRAINT opportunities_id_organisation_id_key UNIQUE (id, organisation_id);

--
-- Name: opportunities opportunities_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opportunities
    ADD CONSTRAINT opportunities_pkey PRIMARY KEY (id);

--
-- Name: opportunity_human_reviews opportunity_human_reviews_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opportunity_human_reviews
    ADD CONSTRAINT opportunity_human_reviews_pkey PRIMARY KEY (id);

--
-- Name: opportunity_sync_events opportunity_sync_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opportunity_sync_events
    ADD CONSTRAINT opportunity_sync_events_pkey PRIMARY KEY (id);

--
-- Name: opportunity_sync_events opportunity_sync_events_request_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opportunity_sync_events
    ADD CONSTRAINT opportunity_sync_events_request_id_key UNIQUE (request_id);

--
-- Name: opportunity_workflow_events opportunity_workflow_events_opportunity_id_request_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opportunity_workflow_events
    ADD CONSTRAINT opportunity_workflow_events_opportunity_id_request_id_key UNIQUE (opportunity_id, request_id);

--
-- Name: opportunity_workflow_events opportunity_workflow_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opportunity_workflow_events
    ADD CONSTRAINT opportunity_workflow_events_pkey PRIMARY KEY (id);

--
-- Name: organisation_commercial_entitlements organisation_commercial_entitlements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organisation_commercial_entitlements
    ADD CONSTRAINT organisation_commercial_entitlements_pkey PRIMARY KEY (organisation_id);

--
-- Name: organisation_company_scopes organisation_company_scopes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organisation_company_scopes
    ADD CONSTRAINT organisation_company_scopes_pkey PRIMARY KEY (id);

--
-- Name: organisation_memberships organisation_memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organisation_memberships
    ADD CONSTRAINT organisation_memberships_pkey PRIMARY KEY (organisation_id, user_id);

--
-- Name: organisations organisations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organisations
    ADD CONSTRAINT organisations_pkey PRIMARY KEY (id);

--
-- Name: organisations organisations_slug_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organisations
    ADD CONSTRAINT organisations_slug_key UNIQUE (slug);

--
-- Name: paid_campaign_refill_jobs paid_campaign_refill_jobs_organisation_id_campaign_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.paid_campaign_refill_jobs
    ADD CONSTRAINT paid_campaign_refill_jobs_organisation_id_campaign_id_key UNIQUE (organisation_id, campaign_id);

--
-- Name: paid_campaign_refill_jobs paid_campaign_refill_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.paid_campaign_refill_jobs
    ADD CONSTRAINT paid_campaign_refill_jobs_pkey PRIMARY KEY (id);

--
-- Name: people people_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.people
    ADD CONSTRAINT people_pkey PRIMARY KEY (id);

--
-- Name: production_runtime_events production_runtime_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.production_runtime_events
    ADD CONSTRAINT production_runtime_events_pkey PRIMARY KEY (id);

--
-- Name: reasoning_artifacts reasoning_artifacts_id_reasoning_run_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reasoning_artifacts
    ADD CONSTRAINT reasoning_artifacts_id_reasoning_run_id_key UNIQUE (id, reasoning_run_id);

--
-- Name: reasoning_artifacts reasoning_artifacts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reasoning_artifacts
    ADD CONSTRAINT reasoning_artifacts_pkey PRIMARY KEY (id);

--
-- Name: reasoning_artifacts reasoning_artifacts_reasoning_run_id_artifact_fingerprint_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reasoning_artifacts
    ADD CONSTRAINT reasoning_artifacts_reasoning_run_id_artifact_fingerprint_key UNIQUE (reasoning_run_id, artifact_fingerprint);

--
-- Name: reasoning_runs reasoning_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reasoning_runs
    ADD CONSTRAINT reasoning_runs_pkey PRIMARY KEY (id);

--
-- Name: research_budget_events research_budget_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_budget_events
    ADD CONSTRAINT research_budget_events_pkey PRIMARY KEY (id);

--
-- Name: research_budget_events research_budget_events_work_unit_id_attempt_number_event_ty_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_budget_events
    ADD CONSTRAINT research_budget_events_work_unit_id_attempt_number_event_ty_key UNIQUE (work_unit_id, attempt_number, event_type);

--
-- Name: research_budget_policies research_budget_policies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_budget_policies
    ADD CONSTRAINT research_budget_policies_pkey PRIMARY KEY (organisation_id, campaign_id);

--
-- Name: research_plan_runs research_plan_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_plan_runs
    ADD CONSTRAINT research_plan_runs_pkey PRIMARY KEY (id);

--
-- Name: research_plan_runs research_plan_runs_plan_fingerprint_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_plan_runs
    ADD CONSTRAINT research_plan_runs_plan_fingerprint_key UNIQUE (plan_fingerprint);

--
-- Name: research_work_units research_work_units_background_job_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_work_units
    ADD CONSTRAINT research_work_units_background_job_id_key UNIQUE (background_job_id);

--
-- Name: research_work_units research_work_units_dedupe_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_work_units
    ADD CONSTRAINT research_work_units_dedupe_key_key UNIQUE (dedupe_key);

--
-- Name: research_work_units research_work_units_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_work_units
    ADD CONSTRAINT research_work_units_pkey PRIMARY KEY (id);

--
-- Name: research_work_units research_work_units_plan_id_gap_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_work_units
    ADD CONSTRAINT research_work_units_plan_id_gap_key_key UNIQUE (plan_id, gap_key);

--
-- Name: research_work_units research_work_units_plan_id_ordinal_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_work_units
    ADD CONSTRAINT research_work_units_plan_id_ordinal_key UNIQUE (plan_id, ordinal);

--
-- Name: route_authority_r5_records route_authority_r5_records_authority_record_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.route_authority_r5_records
    ADD CONSTRAINT route_authority_r5_records_authority_record_id_key UNIQUE (authority_record_id);

--
-- Name: route_authority_r5_records route_authority_r5_records_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.route_authority_r5_records
    ADD CONSTRAINT route_authority_r5_records_pkey PRIMARY KEY (id);

--
-- Name: scheduler_leases scheduler_leases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scheduler_leases
    ADD CONSTRAINT scheduler_leases_pkey PRIMARY KEY (lease_key);

--
-- Name: scheduler_runs scheduler_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scheduler_runs
    ADD CONSTRAINT scheduler_runs_pkey PRIMARY KEY (id);

--
-- Name: seller_businesses seller_businesses_organisation_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_businesses
    ADD CONSTRAINT seller_businesses_organisation_id_id_key UNIQUE (organisation_id, id);

--
-- Name: seller_businesses seller_businesses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_businesses
    ADD CONSTRAINT seller_businesses_pkey PRIMARY KEY (id);

--
-- Name: seller_commercial_genome_snapshots seller_commercial_genome_snap_organisation_id_seller_busine_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_commercial_genome_snapshots
    ADD CONSTRAINT seller_commercial_genome_snap_organisation_id_seller_busine_key UNIQUE (organisation_id, seller_business_id, id);

--
-- Name: seller_commercial_genome_snapshots seller_commercial_genome_snapshots_content_fingerprint_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_commercial_genome_snapshots
    ADD CONSTRAINT seller_commercial_genome_snapshots_content_fingerprint_key UNIQUE (content_fingerprint);

--
-- Name: seller_commercial_genome_snapshots seller_commercial_genome_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_commercial_genome_snapshots
    ADD CONSTRAINT seller_commercial_genome_snapshots_pkey PRIMARY KEY (id);

--
-- Name: seller_genome_source_materials seller_genome_source_materials_material_fingerprint_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_genome_source_materials
    ADD CONSTRAINT seller_genome_source_materials_material_fingerprint_key UNIQUE (material_fingerprint);

--
-- Name: seller_genome_source_materials seller_genome_source_materials_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_genome_source_materials
    ADD CONSTRAINT seller_genome_source_materials_pkey PRIMARY KEY (id);

--
-- Name: source_acquisitions source_acquisitions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.source_acquisitions
    ADD CONSTRAINT source_acquisitions_pkey PRIMARY KEY (id);

--
-- Name: source_records source_records_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.source_records
    ADD CONSTRAINT source_records_pkey PRIMARY KEY (id);

--
-- Name: truth_claim_policy_bindings truth_claim_policy_bindings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.truth_claim_policy_bindings
    ADD CONSTRAINT truth_claim_policy_bindings_pkey PRIMARY KEY (id);

--
-- Name: truth_claim_policy_bindings truth_claim_policy_bindings_precedence_subject_type_claim_k_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.truth_claim_policy_bindings
    ADD CONSTRAINT truth_claim_policy_bindings_precedence_subject_type_claim_k_key UNIQUE (precedence, subject_type, claim_key);

--
-- Name: truth_claim_policy_bindings truth_claim_policy_bindings_subject_type_claim_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.truth_claim_policy_bindings
    ADD CONSTRAINT truth_claim_policy_bindings_subject_type_claim_key_key UNIQUE (subject_type, claim_key);

--
-- Name: truth_claim_policy_registry truth_claim_policy_registry_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.truth_claim_policy_registry
    ADD CONSTRAINT truth_claim_policy_registry_pkey PRIMARY KEY (policy_key);

--
-- Name: truth_claim_snapshots truth_claim_snapshots_claim_id_input_fingerprint_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.truth_claim_snapshots
    ADD CONSTRAINT truth_claim_snapshots_claim_id_input_fingerprint_key UNIQUE (claim_id, input_fingerprint);

--
-- Name: truth_claim_snapshots truth_claim_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.truth_claim_snapshots
    ADD CONSTRAINT truth_claim_snapshots_pkey PRIMARY KEY (id);

--
-- Name: truth_claim_snapshots truth_claim_snapshots_snapshot_fingerprint_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.truth_claim_snapshots
    ADD CONSTRAINT truth_claim_snapshots_snapshot_fingerprint_key UNIQUE (snapshot_fingerprint);

--
-- Name: truth_entity_profile_registry truth_entity_profile_registry_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.truth_entity_profile_registry
    ADD CONSTRAINT truth_entity_profile_registry_pkey PRIMARY KEY (profile_key);

--
-- Name: truth_entity_snapshots truth_entity_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.truth_entity_snapshots
    ADD CONSTRAINT truth_entity_snapshots_pkey PRIMARY KEY (id);

--
-- Name: truth_entity_snapshots truth_entity_snapshots_snapshot_fingerprint_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.truth_entity_snapshots
    ADD CONSTRAINT truth_entity_snapshots_snapshot_fingerprint_key UNIQUE (snapshot_fingerprint);

--
-- Name: truth_entity_snapshots truth_entity_snapshots_tenant_scope_organisation_id_subject_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.truth_entity_snapshots
    ADD CONSTRAINT truth_entity_snapshots_tenant_scope_organisation_id_subject_key UNIQUE NULLS NOT DISTINCT (tenant_scope_organisation_id, subject_type, subject_id, profile_key, input_fingerprint);

--
-- Name: workspace_activation_jobs workspace_activation_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_activation_jobs
    ADD CONSTRAINT workspace_activation_jobs_pkey PRIMARY KEY (id);

--
-- Name: anonymous_discovery_expiry_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX anonymous_discovery_expiry_idx ON public.anonymous_discovery_runs USING btree (status, research_expires_at);

--
-- Name: anonymous_discovery_extension_queue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX anonymous_discovery_extension_queue_idx ON public.anonymous_discovery_extension_jobs USING btree (status, available_at, created_at);

--
-- Name: anonymous_discovery_ip_time_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX anonymous_discovery_ip_time_idx ON public.anonymous_discovery_runs USING btree (ip_hash, created_at DESC);

--
-- Name: anonymous_discovery_unlock_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX anonymous_discovery_unlock_company_idx ON public.anonymous_discovery_opportunity_unlocks USING btree (run_id, company_id);

--
-- Name: authority_events_record_time_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX authority_events_record_time_idx ON public.authority_events USING btree (authority_record_id, occurred_at DESC);

--
-- Name: authority_records_fingerprint_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX authority_records_fingerprint_idx ON public.authority_records USING btree (authority_fingerprint);

--
-- Name: authority_records_subject_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX authority_records_subject_idx ON public.authority_records USING btree (organisation_id, authority_stage, subject_type, subject_id, valid_until DESC);

--
-- Name: background_job_attempts_job_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX background_job_attempts_job_idx ON public.background_job_attempts USING btree (job_id, attempt_number DESC);

--
-- Name: background_jobs_claim_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX background_jobs_claim_idx ON public.background_jobs USING btree (status, available_at, priority, created_at);

--
-- Name: background_jobs_scope_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX background_jobs_scope_idx ON public.background_jobs USING btree (organisation_id, campaign_id, status);

--
-- Name: campaign_engagement_policy_scope_time_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX campaign_engagement_policy_scope_time_idx ON public.campaign_engagement_policy_events USING btree (organisation_id, campaign_id, occurred_at DESC, id DESC);

--
-- Name: campaign_seller_context_latest_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX campaign_seller_context_latest_idx ON public.campaign_seller_context_selections USING btree (organisation_id, campaign_id, created_at DESC, id DESC);

--
-- Name: campaign_workflow_events_campaign_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX campaign_workflow_events_campaign_idx ON public.campaign_workflow_events USING btree (organisation_id, campaign_id, occurred_at DESC, id DESC);

--
-- Name: campaigns_activation_job_unique_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX campaigns_activation_job_unique_idx ON public.campaigns USING btree (activation_job_id) WHERE (activation_job_id IS NOT NULL);

--
-- Name: campaigns_org_state_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX campaigns_org_state_idx ON public.campaigns USING btree (organisation_id, workflow_state);

--
-- Name: claim_evidence_links_claim_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX claim_evidence_links_claim_idx ON public.claim_evidence_links USING btree (claim_id, created_at);

--
-- Name: claim_evidence_links_evidence_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX claim_evidence_links_evidence_idx ON public.claim_evidence_links USING btree (evidence_item_id, created_at);

--
-- Name: claim_evidence_links_single_polarity_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX claim_evidence_links_single_polarity_unique ON public.claim_evidence_links USING btree (claim_id, evidence_item_id);

--
-- Name: claim_supersessions_replacement_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX claim_supersessions_replacement_idx ON public.claim_supersessions USING btree (replacement_claim_id) WHERE (replacement_claim_id IS NOT NULL);

--
-- Name: claims_subject_key_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX claims_subject_key_idx ON public.claims USING btree (subject_type, subject_id, claim_key, created_at DESC);

--
-- Name: claims_tenant_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX claims_tenant_idx ON public.claims USING btree (tenant_scope_organisation_id, created_at DESC);

--
-- Name: commercial_graph_nodes_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX commercial_graph_nodes_company_idx ON public.commercial_graph_nodes USING btree (company_id) WHERE (company_id IS NOT NULL);

--
-- Name: commercial_graph_nodes_person_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX commercial_graph_nodes_person_idx ON public.commercial_graph_nodes USING btree (person_id) WHERE (person_id IS NOT NULL);

--
-- Name: commercial_graph_nodes_scope_kind_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX commercial_graph_nodes_scope_kind_idx ON public.commercial_graph_nodes USING btree (tenant_scope_organisation_id, node_kind);

--
-- Name: commercial_reality_r4_scope_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX commercial_reality_r4_scope_idx ON public.commercial_reality_r4_records USING btree (organisation_id, campaign_id, company_id, created_at DESC);

--
-- Name: commercial_relationships_from_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX commercial_relationships_from_idx ON public.commercial_relationships USING btree (from_node_id);

--
-- Name: commercial_relationships_scope_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX commercial_relationships_scope_idx ON public.commercial_relationships USING btree (tenant_scope_organisation_id, relation_type, created_at DESC);

--
-- Name: commercial_relationships_to_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX commercial_relationships_to_idx ON public.commercial_relationships USING btree (to_node_id);

--
-- Name: contact_authority_r6_scope_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX contact_authority_r6_scope_idx ON public.contact_authority_r6_records USING btree (organisation_id, campaign_id, company_id, created_at DESC);

--
-- Name: engagement_ai_reviews_verdict_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX engagement_ai_reviews_verdict_idx ON public.engagement_ai_reviews USING btree (verdict, created_at DESC);

--
-- Name: engagement_delivery_events_queue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX engagement_delivery_events_queue_idx ON public.engagement_delivery_events USING btree (queue_item_id, occurred_at DESC, id DESC);

--
-- Name: engagement_delivery_jobs_claim_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX engagement_delivery_jobs_claim_idx ON public.engagement_delivery_jobs USING btree (status, created_at, id);

--
-- Name: engagement_manual_actions_opportunity_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX engagement_manual_actions_opportunity_idx ON public.engagement_manual_actions USING btree (opportunity_id, occurred_at DESC, id DESC);

--
-- Name: engagement_manual_actions_scope_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX engagement_manual_actions_scope_idx ON public.engagement_manual_actions USING btree (organisation_id, campaign_id, occurred_at DESC, id DESC);

--
-- Name: engagement_message_approvals_message_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX engagement_message_approvals_message_idx ON public.engagement_message_approvals USING btree (message_id, created_at DESC, id DESC);

--
-- Name: engagement_messages_strategy_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX engagement_messages_strategy_idx ON public.engagement_messages USING btree (strategy_id, rewrite_ordinal DESC, created_at DESC);

--
-- Name: engagement_queue_items_scope_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX engagement_queue_items_scope_idx ON public.engagement_queue_items USING btree (organisation_id, campaign_id, queued_at DESC);

--
-- Name: engagement_strategies_opportunity_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX engagement_strategies_opportunity_idx ON public.engagement_strategies USING btree (opportunity_id, created_at DESC);

--
-- Name: evidence_items_fingerprint_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX evidence_items_fingerprint_unique ON public.evidence_items USING btree (evidence_fingerprint);

--
-- Name: evidence_items_subject_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX evidence_items_subject_idx ON public.evidence_items USING btree (subject_type, subject_id, observed_at DESC);

--
-- Name: evidence_items_tenant_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX evidence_items_tenant_idx ON public.evidence_items USING btree (tenant_scope_organisation_id, created_at DESC);

--
-- Name: genesis_growth_actions_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX genesis_growth_actions_company_idx ON public.genesis_growth_action_runs USING btree (company_id, started_at DESC);

--
-- Name: genesis_growth_actions_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX genesis_growth_actions_status_idx ON public.genesis_growth_action_runs USING btree (status, started_at DESC);

--
-- Name: genesis_growth_budget_time_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX genesis_growth_budget_time_idx ON public.genesis_growth_budget_events USING btree (occurred_at DESC);

--
-- Name: genesis_growth_membership_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX genesis_growth_membership_company_idx ON public.genesis_growth_company_memberships USING btree (company_id);

--
-- Name: genesis_growth_progress_retry_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX genesis_growth_progress_retry_idx ON public.genesis_growth_company_progress USING btree (retry_after, last_researched_at);

--
-- Name: marketroute_billing_checkout_external_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX marketroute_billing_checkout_external_unique ON public.marketroute_billing_checkout_attempts USING btree (external_checkout_session_id) WHERE (external_checkout_session_id IS NOT NULL);

--
-- Name: marketroute_billing_checkout_org_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX marketroute_billing_checkout_org_idx ON public.marketroute_billing_checkout_attempts USING btree (organisation_id, created_at DESC);

--
-- Name: marketroute_conversation_narration_expiry_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX marketroute_conversation_narration_expiry_idx ON public.marketroute_conversation_narration_cache USING btree (expires_at);

--
-- Name: marketroute_conversation_narration_scope_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX marketroute_conversation_narration_scope_idx ON public.marketroute_conversation_narration_cache USING btree (scope_kind, scope_key, created_at DESC);

--
-- Name: opportunities_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX opportunities_company_idx ON public.opportunities USING btree (company_id);

--
-- Name: opportunities_scope_state_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX opportunities_scope_state_idx ON public.opportunities USING btree (organisation_id, campaign_id, workflow_state);

--
-- Name: opportunity_human_reviews_opp_time_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX opportunity_human_reviews_opp_time_idx ON public.opportunity_human_reviews USING btree (opportunity_id, created_at DESC);

--
-- Name: opportunity_human_reviews_request_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX opportunity_human_reviews_request_idx ON public.opportunity_human_reviews USING btree (opportunity_id, review_request_id) WHERE (review_request_id IS NOT NULL);

--
-- Name: opportunity_sync_events_scope_time_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX opportunity_sync_events_scope_time_idx ON public.opportunity_sync_events USING btree (organisation_id, campaign_id, company_id, occurred_at DESC);

--
-- Name: opportunity_workflow_events_opp_time_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX opportunity_workflow_events_opp_time_idx ON public.opportunity_workflow_events USING btree (opportunity_id, occurred_at DESC, id DESC);

--
-- Name: organisation_commercial_external_subscription_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX organisation_commercial_external_subscription_unique ON public.organisation_commercial_entitlements USING btree (external_subscription_id) WHERE (external_subscription_id IS NOT NULL);

--
-- Name: organisation_company_scopes_company_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX organisation_company_scopes_company_idx ON public.organisation_company_scopes USING btree (company_id);

--
-- Name: organisation_company_scopes_identity_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX organisation_company_scopes_identity_unique ON public.organisation_company_scopes USING btree (organisation_id, company_id, scope_kind, campaign_id) NULLS NOT DISTINCT;

--
-- Name: organisation_company_scopes_org_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX organisation_company_scopes_org_idx ON public.organisation_company_scopes USING btree (organisation_id, campaign_id);

--
-- Name: organisation_memberships_user_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX organisation_memberships_user_idx ON public.organisation_memberships USING btree (user_id, status);

--
-- Name: organisations_created_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX organisations_created_by_idx ON public.organisations USING btree (created_by);

--
-- Name: paid_campaign_refill_claim_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX paid_campaign_refill_claim_idx ON public.paid_campaign_refill_jobs USING btree (status, available_at, created_at);

--
-- Name: production_runtime_events_correlation_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX production_runtime_events_correlation_idx ON public.production_runtime_events USING btree (correlation_id, occurred_at, id);

--
-- Name: production_runtime_events_kind_time_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX production_runtime_events_kind_time_idx ON public.production_runtime_events USING btree (runtime_kind, occurred_at DESC, id DESC);

--
-- Name: reasoning_artifacts_subject_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reasoning_artifacts_subject_idx ON public.reasoning_artifacts USING btree (subject_type, subject_id, evaluated_at DESC);

--
-- Name: reasoning_runs_input_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reasoning_runs_input_idx ON public.reasoning_runs USING btree (input_fingerprint);

--
-- Name: reasoning_runs_scope_state_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reasoning_runs_scope_state_idx ON public.reasoning_runs USING btree (organisation_id, campaign_id, reasoning_kind, status);

--
-- Name: research_budget_day_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX research_budget_day_idx ON public.research_budget_events USING btree (organisation_id, campaign_id, occurred_at, event_type);

--
-- Name: research_plan_scope_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX research_plan_scope_idx ON public.research_plan_runs USING btree (organisation_id, campaign_id, company_id, created_at DESC);

--
-- Name: research_work_queue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX research_work_queue_idx ON public.research_work_units USING btree (organisation_id, campaign_id, created_at, id);

--
-- Name: route_authority_r5_scope_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX route_authority_r5_scope_idx ON public.route_authority_r5_records USING btree (organisation_id, campaign_id, company_id, created_at DESC);

--
-- Name: seller_businesses_org_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX seller_businesses_org_idx ON public.seller_businesses USING btree (organisation_id, lifecycle_state);

--
-- Name: seller_commercial_genome_snapshots_semantic_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX seller_commercial_genome_snapshots_semantic_idx ON public.seller_commercial_genome_snapshots USING btree (organisation_id, seller_business_id, semantic_fingerprint, created_at DESC);

--
-- Name: seller_genome_source_materials_seller_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX seller_genome_source_materials_seller_idx ON public.seller_genome_source_materials USING btree (organisation_id, seller_business_id, created_at DESC);

--
-- Name: source_acquisitions_source_time_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX source_acquisitions_source_time_idx ON public.source_acquisitions USING btree (source_id, acquired_at DESC);

--
-- Name: source_records_canonical_url_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX source_records_canonical_url_unique ON public.source_records USING btree (canonical_url) WHERE (canonical_url IS NOT NULL);

--
-- Name: source_records_domain_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX source_records_domain_idx ON public.source_records USING btree (publisher_domain);

--
-- Name: source_records_identity_fingerprint_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX source_records_identity_fingerprint_unique ON public.source_records USING btree (source_identity_fingerprint);

--
-- Name: truth_claim_snapshots_claim_time_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX truth_claim_snapshots_claim_time_idx ON public.truth_claim_snapshots USING btree (claim_id, reference_time DESC);

--
-- Name: truth_claim_snapshots_org_time_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX truth_claim_snapshots_org_time_idx ON public.truth_claim_snapshots USING btree (tenant_scope_organisation_id, reference_time DESC);

--
-- Name: truth_claim_snapshots_subject_time_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX truth_claim_snapshots_subject_time_idx ON public.truth_claim_snapshots USING btree (subject_type, subject_id, reference_time DESC);

--
-- Name: truth_entity_snapshots_subject_time_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX truth_entity_snapshots_subject_time_idx ON public.truth_entity_snapshots USING btree (tenant_scope_organisation_id, subject_type, subject_id, profile_key, reference_time DESC);

--
-- Name: workspace_activation_claim_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX workspace_activation_claim_idx ON public.workspace_activation_jobs USING btree (status, available_at, created_at);

--
-- Name: workspace_activation_kind_claim_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX workspace_activation_kind_claim_idx ON public.workspace_activation_jobs USING btree (activation_kind, status, available_at, created_at);

--
-- Name: workspace_activation_one_processing_per_org_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX workspace_activation_one_processing_per_org_idx ON public.workspace_activation_jobs USING btree (organisation_id) WHERE (status = ANY (ARRAY['PENDING'::text, 'RUNNING'::text]));

--
-- Name: workspace_activation_org_history_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX workspace_activation_org_history_idx ON public.workspace_activation_jobs USING btree (organisation_id, created_at DESC, id DESC);

--
-- Name: ai_usage_events ai_usage_events_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER ai_usage_events_append_only BEFORE DELETE OR UPDATE ON public.ai_usage_events FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

--
-- Name: anonymous_discovery_extension_jobs anonymous_discovery_extension_touch_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER anonymous_discovery_extension_touch_updated_at BEFORE UPDATE ON public.anonymous_discovery_extension_jobs FOR EACH ROW EXECUTE FUNCTION public.marketroute_touch_updated_at();

--
-- Name: anonymous_discovery_runs anonymous_discovery_touch_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER anonymous_discovery_touch_updated_at BEFORE UPDATE ON public.anonymous_discovery_runs FOR EACH ROW EXECUTE FUNCTION public.marketroute_touch_updated_at();

--
-- Name: audit_events audit_events_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER audit_events_append_only BEFORE DELETE OR UPDATE ON public.audit_events FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

--
-- Name: authority_events authority_events_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER authority_events_append_only BEFORE DELETE OR UPDATE ON public.authority_events FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

--
-- Name: authority_events authority_events_declared_writer_gate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER authority_events_declared_writer_gate BEFORE INSERT ON public.authority_events FOR EACH ROW EXECUTE FUNCTION public.marketroute_enforce_declared_authority_writer();

--
-- Name: authority_records authority_records_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER authority_records_append_only BEFORE DELETE OR UPDATE ON public.authority_records FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

--
-- Name: authority_records authority_records_declared_writer_gate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER authority_records_declared_writer_gate BEFORE INSERT ON public.authority_records FOR EACH ROW EXECUTE FUNCTION public.marketroute_enforce_declared_authority_writer();

--
-- Name: background_jobs background_jobs_touch_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER background_jobs_touch_updated_at BEFORE UPDATE ON public.background_jobs FOR EACH ROW EXECUTE FUNCTION public.marketroute_touch_updated_at();

--
-- Name: campaigns campaign_discovery_archive_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER campaign_discovery_archive_guard AFTER UPDATE OF workflow_state ON public.campaigns FOR EACH ROW EXECUTE FUNCTION public.marketroute_discovery_campaign_archive_guard_v1();

--
-- Name: campaign_engagement_policy_events campaign_engagement_policy_events_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER campaign_engagement_policy_events_append_only BEFORE DELETE OR UPDATE ON public.campaign_engagement_policy_events FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

--
-- Name: campaign_seller_context_selections campaign_seller_context_selections_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER campaign_seller_context_selections_append_only BEFORE DELETE OR UPDATE ON public.campaign_seller_context_selections FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

--
-- Name: campaign_workflow_events campaign_workflow_events_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER campaign_workflow_events_append_only BEFORE DELETE OR UPDATE ON public.campaign_workflow_events FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

--
-- Name: campaigns campaigns_touch_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER campaigns_touch_updated_at BEFORE UPDATE ON public.campaigns FOR EACH ROW EXECUTE FUNCTION public.marketroute_touch_updated_at();

--
-- Name: campaigns campaigns_workspace_creator_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER campaigns_workspace_creator_guard BEFORE INSERT OR UPDATE OF organisation_id, created_by ON public.campaigns FOR EACH ROW EXECUTE FUNCTION public.marketroute_enforce_workspace_creator_v1();

--
-- Name: claim_evidence_links claim_evidence_links_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER claim_evidence_links_append_only BEFORE DELETE OR UPDATE ON public.claim_evidence_links FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

--
-- Name: claim_evidence_links claim_evidence_scope_gate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER claim_evidence_scope_gate BEFORE INSERT ON public.claim_evidence_links FOR EACH ROW EXECUTE FUNCTION public.marketroute_validate_claim_evidence_scope();

--
-- Name: claim_supersessions claim_supersession_scope_gate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER claim_supersession_scope_gate BEFORE INSERT ON public.claim_supersessions FOR EACH ROW EXECUTE FUNCTION public.marketroute_validate_claim_supersession_scope();

--
-- Name: claim_supersessions claim_supersessions_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER claim_supersessions_append_only BEFORE DELETE OR UPDATE ON public.claim_supersessions FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

--
-- Name: claims claims_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER claims_append_only BEFORE DELETE OR UPDATE ON public.claims FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

--
-- Name: commercial_graph_nodes commercial_graph_nodes_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER commercial_graph_nodes_append_only BEFORE DELETE OR UPDATE ON public.commercial_graph_nodes FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

--
-- Name: commercial_reality_r4_records commercial_reality_r4_records_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER commercial_reality_r4_records_append_only BEFORE DELETE OR UPDATE ON public.commercial_reality_r4_records FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

--
-- Name: commercial_relationship_type_registry commercial_relationship_type_registry_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER commercial_relationship_type_registry_append_only BEFORE DELETE OR UPDATE ON public.commercial_relationship_type_registry FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

--
-- Name: commercial_relationships commercial_relationships_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER commercial_relationships_append_only BEFORE DELETE OR UPDATE ON public.commercial_relationships FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

--
-- Name: companies companies_touch_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER companies_touch_updated_at BEFORE UPDATE ON public.companies FOR EACH ROW EXECUTE FUNCTION public.marketroute_touch_updated_at();

--
-- Name: contact_authority_r6_records contact_authority_r6_records_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER contact_authority_r6_records_append_only BEFORE DELETE OR UPDATE ON public.contact_authority_r6_records FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

--
-- Name: claim_supersessions contact_claim_supersession_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER contact_claim_supersession_guard BEFORE INSERT ON public.claim_supersessions FOR EACH ROW EXECUTE FUNCTION public.marketroute_prevent_contact_claim_supersession_v1();

--
-- Name: engagement_ai_reviews engagement_ai_reviews_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER engagement_ai_reviews_append_only BEFORE DELETE OR UPDATE ON public.engagement_ai_reviews FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

--
-- Name: engagement_delivery_events engagement_delivery_events_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER engagement_delivery_events_append_only BEFORE DELETE OR UPDATE ON public.engagement_delivery_events FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

--
-- Name: engagement_delivery_jobs engagement_delivery_jobs_touch_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER engagement_delivery_jobs_touch_updated_at BEFORE UPDATE ON public.engagement_delivery_jobs FOR EACH ROW EXECUTE FUNCTION public.marketroute_touch_updated_at();

--
-- Name: engagement_manual_actions engagement_manual_actions_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER engagement_manual_actions_append_only BEFORE DELETE OR UPDATE ON public.engagement_manual_actions FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

--
-- Name: engagement_message_approvals engagement_message_approvals_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER engagement_message_approvals_append_only BEFORE DELETE OR UPDATE ON public.engagement_message_approvals FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

--
-- Name: engagement_messages engagement_messages_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER engagement_messages_append_only BEFORE DELETE OR UPDATE ON public.engagement_messages FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

--
-- Name: engagement_queue_items engagement_queue_items_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER engagement_queue_items_append_only BEFORE DELETE OR UPDATE ON public.engagement_queue_items FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

--
-- Name: engagement_strategies engagement_strategies_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER engagement_strategies_append_only BEFORE DELETE OR UPDATE ON public.engagement_strategies FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

--
-- Name: evidence_items evidence_items_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER evidence_items_append_only BEFORE DELETE OR UPDATE ON public.evidence_items FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

--
-- Name: genesis_growth_budget_events genesis_growth_budget_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER genesis_growth_budget_append_only BEFORE DELETE OR UPDATE ON public.genesis_growth_budget_events FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

--
-- Name: genesis_growth_industries genesis_growth_industries_touch_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER genesis_growth_industries_touch_updated_at BEFORE UPDATE ON public.genesis_growth_industries FOR EACH ROW EXECUTE FUNCTION public.marketroute_touch_updated_at();

--
-- Name: genesis_growth_company_progress genesis_growth_progress_touch_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER genesis_growth_progress_touch_updated_at BEFORE UPDATE ON public.genesis_growth_company_progress FOR EACH ROW EXECUTE FUNCTION public.marketroute_touch_updated_at();

--
-- Name: genesis_growth_settings genesis_growth_settings_touch_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER genesis_growth_settings_touch_updated_at BEFORE UPDATE ON public.genesis_growth_settings FOR EACH ROW EXECUTE FUNCTION public.marketroute_touch_updated_at();

--
-- Name: opportunities opportunities_touch_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER opportunities_touch_updated_at BEFORE UPDATE ON public.opportunities FOR EACH ROW EXECUTE FUNCTION public.marketroute_touch_updated_at();

--
-- Name: opportunity_human_reviews opportunity_human_reviews_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER opportunity_human_reviews_append_only BEFORE DELETE OR UPDATE ON public.opportunity_human_reviews FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

--
-- Name: opportunity_sync_events opportunity_sync_events_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER opportunity_sync_events_append_only BEFORE DELETE OR UPDATE ON public.opportunity_sync_events FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

--
-- Name: opportunity_workflow_events opportunity_workflow_events_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER opportunity_workflow_events_append_only BEFORE DELETE OR UPDATE ON public.opportunity_workflow_events FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

--
-- Name: organisation_memberships organisation_memberships_touch_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER organisation_memberships_touch_updated_at BEFORE UPDATE ON public.organisation_memberships FOR EACH ROW EXECUTE FUNCTION public.marketroute_touch_updated_at();

--
-- Name: organisations organisations_touch_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER organisations_touch_updated_at BEFORE UPDATE ON public.organisations FOR EACH ROW EXECUTE FUNCTION public.marketroute_touch_updated_at();

--
-- Name: people people_touch_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER people_touch_updated_at BEFORE UPDATE ON public.people FOR EACH ROW EXECUTE FUNCTION public.marketroute_touch_updated_at();

--
-- Name: production_runtime_events production_runtime_events_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER production_runtime_events_append_only BEFORE DELETE OR UPDATE ON public.production_runtime_events FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

--
-- Name: reasoning_artifacts reasoning_artifacts_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER reasoning_artifacts_append_only BEFORE DELETE OR UPDATE ON public.reasoning_artifacts FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

--
-- Name: claim_supersessions relationship_claim_supersession_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER relationship_claim_supersession_guard BEFORE INSERT ON public.claim_supersessions FOR EACH ROW EXECUTE FUNCTION public.marketroute_prevent_relationship_claim_supersession_v1();

--
-- Name: research_budget_events research_budget_events_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER research_budget_events_append_only BEFORE DELETE OR UPDATE ON public.research_budget_events FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

--
-- Name: research_plan_runs research_plan_runs_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER research_plan_runs_append_only BEFORE DELETE OR UPDATE ON public.research_plan_runs FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

--
-- Name: research_work_units research_work_units_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER research_work_units_append_only BEFORE DELETE OR UPDATE ON public.research_work_units FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

--
-- Name: route_authority_r5_records route_authority_r5_records_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER route_authority_r5_records_append_only BEFORE DELETE OR UPDATE ON public.route_authority_r5_records FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

--
-- Name: seller_businesses seller_businesses_touch_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER seller_businesses_touch_updated_at BEFORE UPDATE ON public.seller_businesses FOR EACH ROW EXECUTE FUNCTION public.marketroute_touch_updated_at();

--
-- Name: seller_businesses seller_businesses_workspace_creator_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER seller_businesses_workspace_creator_guard BEFORE INSERT OR UPDATE OF organisation_id, created_by ON public.seller_businesses FOR EACH ROW EXECUTE FUNCTION public.marketroute_enforce_workspace_creator_v1();

--
-- Name: seller_commercial_genome_snapshots seller_commercial_genome_snapshots_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER seller_commercial_genome_snapshots_append_only BEFORE DELETE OR UPDATE ON public.seller_commercial_genome_snapshots FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

--
-- Name: seller_genome_source_materials seller_genome_source_materials_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER seller_genome_source_materials_append_only BEFORE DELETE OR UPDATE ON public.seller_genome_source_materials FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

--
-- Name: source_acquisitions source_acquisitions_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER source_acquisitions_append_only BEFORE DELETE OR UPDATE ON public.source_acquisitions FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

--
-- Name: source_records source_records_identity_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER source_records_identity_immutable BEFORE UPDATE ON public.source_records FOR EACH ROW EXECUTE FUNCTION public.marketroute_protect_source_identity();

--
-- Name: truth_claim_snapshots truth_claim_snapshots_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER truth_claim_snapshots_append_only BEFORE DELETE OR UPDATE ON public.truth_claim_snapshots FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

--
-- Name: truth_entity_snapshots truth_entity_snapshots_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER truth_entity_snapshots_append_only BEFORE DELETE OR UPDATE ON public.truth_entity_snapshots FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

--
-- Name: workspace_activation_jobs workspace_activation_status_transition; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER workspace_activation_status_transition BEFORE UPDATE OF status ON public.workspace_activation_jobs FOR EACH ROW EXECUTE FUNCTION public.marketroute_workspace_activation_status_transition_v1();

--
-- Name: workspace_activation_jobs workspace_activation_touch_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER workspace_activation_touch_updated_at BEFORE UPDATE ON public.workspace_activation_jobs FOR EACH ROW EXECUTE FUNCTION public.marketroute_touch_updated_at();

--
-- Name: ai_usage_events ai_usage_events_campaign_scope_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_usage_events
    ADD CONSTRAINT ai_usage_events_campaign_scope_fk FOREIGN KEY (organisation_id, campaign_id) REFERENCES public.campaigns(organisation_id, id) ON DELETE SET NULL;

--
-- Name: ai_usage_events ai_usage_events_organisation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_usage_events
    ADD CONSTRAINT ai_usage_events_organisation_id_fkey FOREIGN KEY (organisation_id) REFERENCES public.organisations(id) ON DELETE SET NULL;

--
-- Name: ai_usage_events ai_usage_events_reasoning_run_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_usage_events
    ADD CONSTRAINT ai_usage_events_reasoning_run_id_fkey FOREIGN KEY (reasoning_run_id) REFERENCES public.reasoning_runs(id) ON DELETE SET NULL;

--
-- Name: anonymous_discovery_extension_jobs anonymous_discovery_extension_campaign_scope_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anonymous_discovery_extension_jobs
    ADD CONSTRAINT anonymous_discovery_extension_campaign_scope_fk FOREIGN KEY (organisation_id, campaign_id) REFERENCES public.campaigns(organisation_id, id) ON DELETE RESTRICT;

--
-- Name: anonymous_discovery_extension_jobs anonymous_discovery_extension_jobs_organisation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anonymous_discovery_extension_jobs
    ADD CONSTRAINT anonymous_discovery_extension_jobs_organisation_id_fkey FOREIGN KEY (organisation_id) REFERENCES public.organisations(id) ON DELETE RESTRICT;

--
-- Name: anonymous_discovery_extension_jobs anonymous_discovery_extension_jobs_run_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anonymous_discovery_extension_jobs
    ADD CONSTRAINT anonymous_discovery_extension_jobs_run_id_fkey FOREIGN KEY (run_id) REFERENCES public.anonymous_discovery_runs(id) ON DELETE RESTRICT;

--
-- Name: anonymous_discovery_opportunity_unlocks anonymous_discovery_opportunity_unlocks_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anonymous_discovery_opportunity_unlocks
    ADD CONSTRAINT anonymous_discovery_opportunity_unlocks_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;

--
-- Name: anonymous_discovery_opportunity_unlocks anonymous_discovery_opportunity_unlocks_opportunity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anonymous_discovery_opportunity_unlocks
    ADD CONSTRAINT anonymous_discovery_opportunity_unlocks_opportunity_id_fkey FOREIGN KEY (opportunity_id) REFERENCES public.opportunities(id) ON DELETE RESTRICT;

--
-- Name: anonymous_discovery_opportunity_unlocks anonymous_discovery_opportunity_unlocks_run_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anonymous_discovery_opportunity_unlocks
    ADD CONSTRAINT anonymous_discovery_opportunity_unlocks_run_id_fkey FOREIGN KEY (run_id) REFERENCES public.anonymous_discovery_runs(id) ON DELETE RESTRICT;

--
-- Name: anonymous_discovery_runs anonymous_discovery_runs_activation_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anonymous_discovery_runs
    ADD CONSTRAINT anonymous_discovery_runs_activation_job_id_fkey FOREIGN KEY (activation_job_id) REFERENCES public.workspace_activation_jobs(id) ON DELETE RESTRICT;

--
-- Name: anonymous_discovery_runs anonymous_discovery_runs_claimed_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anonymous_discovery_runs
    ADD CONSTRAINT anonymous_discovery_runs_claimed_by_user_id_fkey FOREIGN KEY (claimed_by_user_id) REFERENCES public.marketroute_users(id) ON DELETE SET NULL;

--
-- Name: anonymous_discovery_runs anonymous_discovery_runs_organisation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anonymous_discovery_runs
    ADD CONSTRAINT anonymous_discovery_runs_organisation_id_fkey FOREIGN KEY (organisation_id) REFERENCES public.organisations(id) ON DELETE RESTRICT;

--
-- Name: anonymous_discovery_runs anonymous_discovery_seller_scope_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.anonymous_discovery_runs
    ADD CONSTRAINT anonymous_discovery_seller_scope_fk FOREIGN KEY (organisation_id, seller_business_id) REFERENCES public.seller_businesses(organisation_id, id) ON DELETE RESTRICT;

--
-- Name: audit_events audit_events_organisation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT audit_events_organisation_id_fkey FOREIGN KEY (organisation_id) REFERENCES public.organisations(id) ON DELETE SET NULL;

--
-- Name: authority_events authority_events_authority_record_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.authority_events
    ADD CONSTRAINT authority_events_authority_record_id_fkey FOREIGN KEY (authority_record_id) REFERENCES public.authority_records(id) ON DELETE RESTRICT;

--
-- Name: authority_events authority_events_writer_key_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.authority_events
    ADD CONSTRAINT authority_events_writer_key_fkey FOREIGN KEY (writer_key) REFERENCES public.authority_writer_registry(writer_key) ON DELETE RESTRICT;

--
-- Name: authority_records authority_records_campaign_scope_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.authority_records
    ADD CONSTRAINT authority_records_campaign_scope_fk FOREIGN KEY (organisation_id, campaign_id) REFERENCES public.campaigns(organisation_id, id) ON DELETE RESTRICT;

--
-- Name: authority_records authority_records_organisation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.authority_records
    ADD CONSTRAINT authority_records_organisation_id_fkey FOREIGN KEY (organisation_id) REFERENCES public.organisations(id) ON DELETE RESTRICT;

--
-- Name: authority_records authority_records_reasoning_artifact_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.authority_records
    ADD CONSTRAINT authority_records_reasoning_artifact_fk FOREIGN KEY (reasoning_artifact_id, reasoning_run_id) REFERENCES public.reasoning_artifacts(id, reasoning_run_id) ON DELETE RESTRICT;

--
-- Name: authority_records authority_records_writer_key_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.authority_records
    ADD CONSTRAINT authority_records_writer_key_fkey FOREIGN KEY (writer_key) REFERENCES public.authority_writer_registry(writer_key) ON DELETE RESTRICT;

--
-- Name: background_job_attempts background_job_attempts_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.background_job_attempts
    ADD CONSTRAINT background_job_attempts_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.background_jobs(id) ON DELETE CASCADE;

--
-- Name: background_job_attempts background_job_attempts_scheduler_run_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.background_job_attempts
    ADD CONSTRAINT background_job_attempts_scheduler_run_id_fkey FOREIGN KEY (scheduler_run_id) REFERENCES public.scheduler_runs(id) ON DELETE SET NULL;

--
-- Name: background_jobs background_jobs_campaign_scope_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.background_jobs
    ADD CONSTRAINT background_jobs_campaign_scope_fk FOREIGN KEY (organisation_id, campaign_id) REFERENCES public.campaigns(organisation_id, id) ON DELETE CASCADE;

--
-- Name: background_jobs background_jobs_organisation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.background_jobs
    ADD CONSTRAINT background_jobs_organisation_id_fkey FOREIGN KEY (organisation_id) REFERENCES public.organisations(id) ON DELETE CASCADE;

--
-- Name: background_jobs background_jobs_reserved_by_run_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.background_jobs
    ADD CONSTRAINT background_jobs_reserved_by_run_id_fkey FOREIGN KEY (reserved_by_run_id) REFERENCES public.scheduler_runs(id) ON DELETE SET NULL;

--
-- Name: campaign_engagement_policy_events campaign_engagement_policy_campaign_scope_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.campaign_engagement_policy_events
    ADD CONSTRAINT campaign_engagement_policy_campaign_scope_fk FOREIGN KEY (organisation_id, campaign_id) REFERENCES public.campaigns(organisation_id, id) ON DELETE RESTRICT;

--
-- Name: campaign_engagement_policy_events campaign_engagement_policy_events_actor_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.campaign_engagement_policy_events
    ADD CONSTRAINT campaign_engagement_policy_events_actor_user_id_fkey FOREIGN KEY (actor_user_id) REFERENCES public.marketroute_users(id) ON DELETE RESTRICT;

--
-- Name: campaign_engagement_policy_events campaign_engagement_policy_events_organisation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.campaign_engagement_policy_events
    ADD CONSTRAINT campaign_engagement_policy_events_organisation_id_fkey FOREIGN KEY (organisation_id) REFERENCES public.organisations(id) ON DELETE RESTRICT;

--
-- Name: campaign_seller_context_selections campaign_seller_context_campaign_scope_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.campaign_seller_context_selections
    ADD CONSTRAINT campaign_seller_context_campaign_scope_fk FOREIGN KEY (organisation_id, campaign_id) REFERENCES public.campaigns(organisation_id, id) ON DELETE RESTRICT;

--
-- Name: campaign_seller_context_selections campaign_seller_context_genome_scope_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.campaign_seller_context_selections
    ADD CONSTRAINT campaign_seller_context_genome_scope_fk FOREIGN KEY (organisation_id, seller_business_id, genome_snapshot_id) REFERENCES public.seller_commercial_genome_snapshots(organisation_id, seller_business_id, id) ON DELETE RESTRICT;

--
-- Name: campaign_seller_context_selections campaign_seller_context_seller_scope_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.campaign_seller_context_selections
    ADD CONSTRAINT campaign_seller_context_seller_scope_fk FOREIGN KEY (organisation_id, seller_business_id) REFERENCES public.seller_businesses(organisation_id, id) ON DELETE RESTRICT;

--
-- Name: campaign_workflow_events campaign_workflow_events_actor_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.campaign_workflow_events
    ADD CONSTRAINT campaign_workflow_events_actor_user_id_fkey FOREIGN KEY (actor_user_id) REFERENCES public.marketroute_users(id) ON DELETE RESTRICT;

--
-- Name: campaign_workflow_events campaign_workflow_events_campaign_scope_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.campaign_workflow_events
    ADD CONSTRAINT campaign_workflow_events_campaign_scope_fk FOREIGN KEY (organisation_id, campaign_id) REFERENCES public.campaigns(organisation_id, id) ON DELETE RESTRICT;

--
-- Name: campaigns campaigns_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.campaigns
    ADD CONSTRAINT campaigns_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.marketroute_users(id) ON DELETE RESTRICT;

--
-- Name: campaigns campaigns_organisation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.campaigns
    ADD CONSTRAINT campaigns_organisation_id_fkey FOREIGN KEY (organisation_id) REFERENCES public.organisations(id) ON DELETE RESTRICT;

--
-- Name: campaigns campaigns_seller_business_scope_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.campaigns
    ADD CONSTRAINT campaigns_seller_business_scope_fk FOREIGN KEY (organisation_id, seller_business_id) REFERENCES public.seller_businesses(organisation_id, id) ON DELETE RESTRICT;

--
-- Name: claim_evidence_links claim_evidence_links_claim_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.claim_evidence_links
    ADD CONSTRAINT claim_evidence_links_claim_id_fkey FOREIGN KEY (claim_id) REFERENCES public.claims(id) ON DELETE RESTRICT;

--
-- Name: claim_evidence_links claim_evidence_links_evidence_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.claim_evidence_links
    ADD CONSTRAINT claim_evidence_links_evidence_item_id_fkey FOREIGN KEY (evidence_item_id) REFERENCES public.evidence_items(id) ON DELETE RESTRICT;

--
-- Name: claim_supersessions claim_supersessions_prior_claim_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.claim_supersessions
    ADD CONSTRAINT claim_supersessions_prior_claim_id_fkey FOREIGN KEY (prior_claim_id) REFERENCES public.claims(id) ON DELETE RESTRICT;

--
-- Name: claim_supersessions claim_supersessions_replacement_claim_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.claim_supersessions
    ADD CONSTRAINT claim_supersessions_replacement_claim_id_fkey FOREIGN KEY (replacement_claim_id) REFERENCES public.claims(id) ON DELETE RESTRICT;

--
-- Name: claims claims_tenant_scope_organisation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.claims
    ADD CONSTRAINT claims_tenant_scope_organisation_id_fkey FOREIGN KEY (tenant_scope_organisation_id) REFERENCES public.organisations(id) ON DELETE RESTRICT;

--
-- Name: commercial_graph_nodes commercial_graph_nodes_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_graph_nodes
    ADD CONSTRAINT commercial_graph_nodes_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;

--
-- Name: commercial_graph_nodes commercial_graph_nodes_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_graph_nodes
    ADD CONSTRAINT commercial_graph_nodes_person_id_fkey FOREIGN KEY (person_id) REFERENCES public.people(id) ON DELETE RESTRICT;

--
-- Name: commercial_graph_nodes commercial_graph_nodes_tenant_scope_organisation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_graph_nodes
    ADD CONSTRAINT commercial_graph_nodes_tenant_scope_organisation_id_fkey FOREIGN KEY (tenant_scope_organisation_id) REFERENCES public.organisations(id) ON DELETE RESTRICT;

--
-- Name: commercial_reality_r4_records commercial_reality_r4_campaign_scope_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_reality_r4_records
    ADD CONSTRAINT commercial_reality_r4_campaign_scope_fk FOREIGN KEY (organisation_id, campaign_id) REFERENCES public.campaigns(organisation_id, id) ON DELETE RESTRICT;

--
-- Name: commercial_reality_r4_records commercial_reality_r4_records_authority_record_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_reality_r4_records
    ADD CONSTRAINT commercial_reality_r4_records_authority_record_id_fkey FOREIGN KEY (authority_record_id) REFERENCES public.authority_records(id) ON DELETE RESTRICT;

--
-- Name: commercial_reality_r4_records commercial_reality_r4_records_boundary_constitution_key_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_reality_r4_records
    ADD CONSTRAINT commercial_reality_r4_records_boundary_constitution_key_fkey FOREIGN KEY (boundary_constitution_key) REFERENCES public.commercial_reality_boundary_constitutions(constitution_key) ON DELETE RESTRICT;

--
-- Name: commercial_reality_r4_records commercial_reality_r4_records_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_reality_r4_records
    ADD CONSTRAINT commercial_reality_r4_records_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;

--
-- Name: commercial_reality_r4_records commercial_reality_r4_records_organisation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_reality_r4_records
    ADD CONSTRAINT commercial_reality_r4_records_organisation_id_fkey FOREIGN KEY (organisation_id) REFERENCES public.organisations(id) ON DELETE RESTRICT;

--
-- Name: commercial_reality_r4_records commercial_reality_r4_records_seller_context_selection_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_reality_r4_records
    ADD CONSTRAINT commercial_reality_r4_records_seller_context_selection_id_fkey FOREIGN KEY (seller_context_selection_id) REFERENCES public.campaign_seller_context_selections(id) ON DELETE RESTRICT;

--
-- Name: commercial_reality_r4_records commercial_reality_r4_records_target_truth_entity_snapshot_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_reality_r4_records
    ADD CONSTRAINT commercial_reality_r4_records_target_truth_entity_snapshot_fkey FOREIGN KEY (target_truth_entity_snapshot_id) REFERENCES public.truth_entity_snapshots(id) ON DELETE RESTRICT;

--
-- Name: commercial_relationships commercial_relationships_claim_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_relationships
    ADD CONSTRAINT commercial_relationships_claim_id_fkey FOREIGN KEY (claim_id) REFERENCES public.claims(id) ON DELETE RESTRICT;

--
-- Name: commercial_relationships commercial_relationships_from_node_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_relationships
    ADD CONSTRAINT commercial_relationships_from_node_id_fkey FOREIGN KEY (from_node_id) REFERENCES public.commercial_graph_nodes(id) ON DELETE RESTRICT;

--
-- Name: commercial_relationships commercial_relationships_relation_type_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_relationships
    ADD CONSTRAINT commercial_relationships_relation_type_fkey FOREIGN KEY (relation_type) REFERENCES public.commercial_relationship_type_registry(relation_type) ON DELETE RESTRICT;

--
-- Name: commercial_relationships commercial_relationships_tenant_scope_organisation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_relationships
    ADD CONSTRAINT commercial_relationships_tenant_scope_organisation_id_fkey FOREIGN KEY (tenant_scope_organisation_id) REFERENCES public.organisations(id) ON DELETE RESTRICT;

--
-- Name: commercial_relationships commercial_relationships_to_node_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_relationships
    ADD CONSTRAINT commercial_relationships_to_node_id_fkey FOREIGN KEY (to_node_id) REFERENCES public.commercial_graph_nodes(id) ON DELETE RESTRICT;

--
-- Name: contact_authority_r6_records contact_authority_r6_campaign_scope_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contact_authority_r6_records
    ADD CONSTRAINT contact_authority_r6_campaign_scope_fk FOREIGN KEY (organisation_id, campaign_id) REFERENCES public.campaigns(organisation_id, id) ON DELETE RESTRICT;

--
-- Name: contact_authority_r6_records contact_authority_r6_records_authority_record_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contact_authority_r6_records
    ADD CONSTRAINT contact_authority_r6_records_authority_record_id_fkey FOREIGN KEY (authority_record_id) REFERENCES public.authority_records(id) ON DELETE RESTRICT;

--
-- Name: contact_authority_r6_records contact_authority_r6_records_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contact_authority_r6_records
    ADD CONSTRAINT contact_authority_r6_records_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;

--
-- Name: contact_authority_r6_records contact_authority_r6_records_organisation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contact_authority_r6_records
    ADD CONSTRAINT contact_authority_r6_records_organisation_id_fkey FOREIGN KEY (organisation_id) REFERENCES public.organisations(id) ON DELETE RESTRICT;

--
-- Name: contact_authority_r6_records contact_authority_r6_records_parent_r5_authority_record_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contact_authority_r6_records
    ADD CONSTRAINT contact_authority_r6_records_parent_r5_authority_record_id_fkey FOREIGN KEY (parent_r5_authority_record_id) REFERENCES public.authority_records(id) ON DELETE RESTRICT;

--
-- Name: engagement_ai_reviews engagement_ai_reviews_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_ai_reviews
    ADD CONSTRAINT engagement_ai_reviews_message_id_fkey FOREIGN KEY (message_id) REFERENCES public.engagement_messages(id) ON DELETE RESTRICT;

--
-- Name: engagement_delivery_events engagement_delivery_events_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_delivery_events
    ADD CONSTRAINT engagement_delivery_events_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.engagement_delivery_jobs(id) ON DELETE RESTRICT;

--
-- Name: engagement_delivery_events engagement_delivery_events_queue_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_delivery_events
    ADD CONSTRAINT engagement_delivery_events_queue_item_id_fkey FOREIGN KEY (queue_item_id) REFERENCES public.engagement_queue_items(id) ON DELETE RESTRICT;

--
-- Name: engagement_delivery_jobs engagement_delivery_jobs_queue_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_delivery_jobs
    ADD CONSTRAINT engagement_delivery_jobs_queue_item_id_fkey FOREIGN KEY (queue_item_id) REFERENCES public.engagement_queue_items(id) ON DELETE RESTRICT;

--
-- Name: engagement_manual_actions engagement_manual_actions_access_point_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_manual_actions
    ADD CONSTRAINT engagement_manual_actions_access_point_id_fkey FOREIGN KEY (access_point_id) REFERENCES public.commercial_graph_nodes(id) ON DELETE RESTRICT;

--
-- Name: engagement_manual_actions engagement_manual_actions_actor_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_manual_actions
    ADD CONSTRAINT engagement_manual_actions_actor_user_id_fkey FOREIGN KEY (actor_user_id) REFERENCES public.marketroute_users(id) ON DELETE RESTRICT;

--
-- Name: engagement_manual_actions engagement_manual_actions_campaign_scope_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_manual_actions
    ADD CONSTRAINT engagement_manual_actions_campaign_scope_fk FOREIGN KEY (organisation_id, campaign_id) REFERENCES public.campaigns(organisation_id, id) ON DELETE RESTRICT;

--
-- Name: engagement_manual_actions engagement_manual_actions_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_manual_actions
    ADD CONSTRAINT engagement_manual_actions_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;

--
-- Name: engagement_manual_actions engagement_manual_actions_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_manual_actions
    ADD CONSTRAINT engagement_manual_actions_message_id_fkey FOREIGN KEY (message_id) REFERENCES public.engagement_messages(id) ON DELETE RESTRICT;

--
-- Name: engagement_manual_actions engagement_manual_actions_opportunity_scope_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_manual_actions
    ADD CONSTRAINT engagement_manual_actions_opportunity_scope_fk FOREIGN KEY (opportunity_id, organisation_id) REFERENCES public.opportunities(id, organisation_id) ON DELETE RESTRICT;

--
-- Name: engagement_manual_actions engagement_manual_actions_organisation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_manual_actions
    ADD CONSTRAINT engagement_manual_actions_organisation_id_fkey FOREIGN KEY (organisation_id) REFERENCES public.organisations(id) ON DELETE RESTRICT;

--
-- Name: engagement_manual_actions engagement_manual_actions_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_manual_actions
    ADD CONSTRAINT engagement_manual_actions_person_id_fkey FOREIGN KEY (person_id) REFERENCES public.people(id) ON DELETE RESTRICT;

--
-- Name: engagement_manual_actions engagement_manual_actions_strategy_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_manual_actions
    ADD CONSTRAINT engagement_manual_actions_strategy_id_fkey FOREIGN KEY (strategy_id) REFERENCES public.engagement_strategies(id) ON DELETE RESTRICT;

--
-- Name: engagement_message_approvals engagement_message_approvals_actor_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_message_approvals
    ADD CONSTRAINT engagement_message_approvals_actor_user_id_fkey FOREIGN KEY (actor_user_id) REFERENCES public.marketroute_users(id) ON DELETE RESTRICT;

--
-- Name: engagement_message_approvals engagement_message_approvals_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_message_approvals
    ADD CONSTRAINT engagement_message_approvals_message_id_fkey FOREIGN KEY (message_id) REFERENCES public.engagement_messages(id) ON DELETE RESTRICT;

--
-- Name: engagement_message_approvals engagement_message_approvals_review_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_message_approvals
    ADD CONSTRAINT engagement_message_approvals_review_id_fkey FOREIGN KEY (review_id) REFERENCES public.engagement_ai_reviews(id) ON DELETE RESTRICT;

--
-- Name: engagement_messages engagement_messages_previous_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_messages
    ADD CONSTRAINT engagement_messages_previous_message_id_fkey FOREIGN KEY (previous_message_id) REFERENCES public.engagement_messages(id) ON DELETE RESTRICT;

--
-- Name: engagement_messages engagement_messages_strategy_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_messages
    ADD CONSTRAINT engagement_messages_strategy_id_fkey FOREIGN KEY (strategy_id) REFERENCES public.engagement_strategies(id) ON DELETE RESTRICT;

--
-- Name: engagement_queue_items engagement_queue_items_approval_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_queue_items
    ADD CONSTRAINT engagement_queue_items_approval_id_fkey FOREIGN KEY (approval_id) REFERENCES public.engagement_message_approvals(id) ON DELETE RESTRICT;

--
-- Name: engagement_queue_items engagement_queue_items_campaign_scope_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_queue_items
    ADD CONSTRAINT engagement_queue_items_campaign_scope_fk FOREIGN KEY (organisation_id, campaign_id) REFERENCES public.campaigns(organisation_id, id) ON DELETE RESTRICT;

--
-- Name: engagement_queue_items engagement_queue_items_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_queue_items
    ADD CONSTRAINT engagement_queue_items_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;

--
-- Name: engagement_queue_items engagement_queue_items_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_queue_items
    ADD CONSTRAINT engagement_queue_items_message_id_fkey FOREIGN KEY (message_id) REFERENCES public.engagement_messages(id) ON DELETE RESTRICT;

--
-- Name: engagement_queue_items engagement_queue_items_opportunity_scope_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_queue_items
    ADD CONSTRAINT engagement_queue_items_opportunity_scope_fk FOREIGN KEY (opportunity_id, organisation_id) REFERENCES public.opportunities(id, organisation_id) ON DELETE RESTRICT;

--
-- Name: engagement_queue_items engagement_queue_items_organisation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_queue_items
    ADD CONSTRAINT engagement_queue_items_organisation_id_fkey FOREIGN KEY (organisation_id) REFERENCES public.organisations(id) ON DELETE RESTRICT;

--
-- Name: engagement_queue_items engagement_queue_items_review_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_queue_items
    ADD CONSTRAINT engagement_queue_items_review_id_fkey FOREIGN KEY (review_id) REFERENCES public.engagement_ai_reviews(id) ON DELETE RESTRICT;

--
-- Name: engagement_queue_items engagement_queue_items_strategy_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_queue_items
    ADD CONSTRAINT engagement_queue_items_strategy_id_fkey FOREIGN KEY (strategy_id) REFERENCES public.engagement_strategies(id) ON DELETE RESTRICT;

--
-- Name: engagement_strategies engagement_strategies_access_point_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_strategies
    ADD CONSTRAINT engagement_strategies_access_point_id_fkey FOREIGN KEY (access_point_id) REFERENCES public.commercial_graph_nodes(id) ON DELETE RESTRICT;

--
-- Name: engagement_strategies engagement_strategies_campaign_scope_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_strategies
    ADD CONSTRAINT engagement_strategies_campaign_scope_fk FOREIGN KEY (organisation_id, campaign_id) REFERENCES public.campaigns(organisation_id, id) ON DELETE RESTRICT;

--
-- Name: engagement_strategies engagement_strategies_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_strategies
    ADD CONSTRAINT engagement_strategies_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;

--
-- Name: engagement_strategies engagement_strategies_opportunity_scope_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_strategies
    ADD CONSTRAINT engagement_strategies_opportunity_scope_fk FOREIGN KEY (opportunity_id, organisation_id) REFERENCES public.opportunities(id, organisation_id) ON DELETE RESTRICT;

--
-- Name: engagement_strategies engagement_strategies_organisation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_strategies
    ADD CONSTRAINT engagement_strategies_organisation_id_fkey FOREIGN KEY (organisation_id) REFERENCES public.organisations(id) ON DELETE RESTRICT;

--
-- Name: engagement_strategies engagement_strategies_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_strategies
    ADD CONSTRAINT engagement_strategies_person_id_fkey FOREIGN KEY (person_id) REFERENCES public.people(id) ON DELETE RESTRICT;

--
-- Name: engagement_strategies engagement_strategies_r6_authority_record_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.engagement_strategies
    ADD CONSTRAINT engagement_strategies_r6_authority_record_id_fkey FOREIGN KEY (r6_authority_record_id) REFERENCES public.authority_records(id) ON DELETE RESTRICT;

--
-- Name: evidence_items evidence_items_acquisition_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evidence_items
    ADD CONSTRAINT evidence_items_acquisition_id_fkey FOREIGN KEY (acquisition_id) REFERENCES public.source_acquisitions(id) ON DELETE RESTRICT;

--
-- Name: evidence_items evidence_items_tenant_scope_organisation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.evidence_items
    ADD CONSTRAINT evidence_items_tenant_scope_organisation_id_fkey FOREIGN KEY (tenant_scope_organisation_id) REFERENCES public.organisations(id) ON DELETE RESTRICT;

--
-- Name: genesis_growth_action_runs genesis_growth_action_runs_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.genesis_growth_action_runs
    ADD CONSTRAINT genesis_growth_action_runs_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;

--
-- Name: genesis_growth_action_runs genesis_growth_action_runs_industry_key_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.genesis_growth_action_runs
    ADD CONSTRAINT genesis_growth_action_runs_industry_key_fkey FOREIGN KEY (industry_key) REFERENCES public.genesis_growth_industries(industry_key) ON DELETE RESTRICT;

--
-- Name: genesis_growth_action_runs genesis_growth_action_runs_scheduler_run_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.genesis_growth_action_runs
    ADD CONSTRAINT genesis_growth_action_runs_scheduler_run_id_fkey FOREIGN KEY (scheduler_run_id) REFERENCES public.scheduler_runs(id) ON DELETE CASCADE;

--
-- Name: genesis_growth_budget_events genesis_growth_budget_events_action_run_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.genesis_growth_budget_events
    ADD CONSTRAINT genesis_growth_budget_events_action_run_id_fkey FOREIGN KEY (action_run_id) REFERENCES public.genesis_growth_action_runs(id) ON DELETE RESTRICT;

--
-- Name: genesis_growth_budget_events genesis_growth_budget_events_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.genesis_growth_budget_events
    ADD CONSTRAINT genesis_growth_budget_events_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE SET NULL;

--
-- Name: genesis_growth_budget_events genesis_growth_budget_events_industry_key_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.genesis_growth_budget_events
    ADD CONSTRAINT genesis_growth_budget_events_industry_key_fkey FOREIGN KEY (industry_key) REFERENCES public.genesis_growth_industries(industry_key) ON DELETE RESTRICT;

--
-- Name: genesis_growth_company_memberships genesis_growth_company_memberships_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.genesis_growth_company_memberships
    ADD CONSTRAINT genesis_growth_company_memberships_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;

--
-- Name: genesis_growth_company_memberships genesis_growth_company_memberships_industry_key_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.genesis_growth_company_memberships
    ADD CONSTRAINT genesis_growth_company_memberships_industry_key_fkey FOREIGN KEY (industry_key) REFERENCES public.genesis_growth_industries(industry_key) ON DELETE RESTRICT;

--
-- Name: genesis_growth_company_progress genesis_growth_company_progress_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.genesis_growth_company_progress
    ADD CONSTRAINT genesis_growth_company_progress_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;

--
-- Name: genesis_growth_people genesis_growth_people_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.genesis_growth_people
    ADD CONSTRAINT genesis_growth_people_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;

--
-- Name: genesis_growth_people genesis_growth_people_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.genesis_growth_people
    ADD CONSTRAINT genesis_growth_people_person_id_fkey FOREIGN KEY (person_id) REFERENCES public.people(id) ON DELETE CASCADE;

--
-- Name: marketroute_billing_checkout_attempts marketroute_billing_checkout_attempts_organisation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.marketroute_billing_checkout_attempts
    ADD CONSTRAINT marketroute_billing_checkout_attempts_organisation_id_fkey FOREIGN KEY (organisation_id) REFERENCES public.organisations(id) ON DELETE RESTRICT;

--
-- Name: marketroute_billing_checkout_attempts marketroute_billing_checkout_attempts_plan_code_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.marketroute_billing_checkout_attempts
    ADD CONSTRAINT marketroute_billing_checkout_attempts_plan_code_fkey FOREIGN KEY (plan_code) REFERENCES public.marketroute_plan_catalog(plan_code) ON DELETE RESTRICT;

--
-- Name: marketroute_billing_checkout_attempts marketroute_billing_checkout_attempts_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.marketroute_billing_checkout_attempts
    ADD CONSTRAINT marketroute_billing_checkout_attempts_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.marketroute_users(id) ON DELETE RESTRICT;

--
-- Name: marketroute_conversation_narration_cache marketroute_conversation_narration_cache_campaign_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.marketroute_conversation_narration_cache
    ADD CONSTRAINT marketroute_conversation_narration_cache_campaign_id_fkey FOREIGN KEY (campaign_id) REFERENCES public.campaigns(id) ON DELETE CASCADE;

--
-- Name: marketroute_conversation_narration_cache marketroute_conversation_narration_cache_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.marketroute_conversation_narration_cache
    ADD CONSTRAINT marketroute_conversation_narration_cache_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;

--
-- Name: marketroute_conversation_narration_cache marketroute_conversation_narration_cache_organisation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.marketroute_conversation_narration_cache
    ADD CONSTRAINT marketroute_conversation_narration_cache_organisation_id_fkey FOREIGN KEY (organisation_id) REFERENCES public.organisations(id) ON DELETE CASCADE;

--
-- Name: opportunities opportunities_campaign_scope_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opportunities
    ADD CONSTRAINT opportunities_campaign_scope_fk FOREIGN KEY (organisation_id, campaign_id) REFERENCES public.campaigns(organisation_id, id) ON DELETE RESTRICT;

--
-- Name: opportunities opportunities_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opportunities
    ADD CONSTRAINT opportunities_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;

--
-- Name: opportunities opportunities_organisation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opportunities
    ADD CONSTRAINT opportunities_organisation_id_fkey FOREIGN KEY (organisation_id) REFERENCES public.organisations(id) ON DELETE RESTRICT;

--
-- Name: opportunity_human_reviews opportunity_human_reviews_organisation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opportunity_human_reviews
    ADD CONSTRAINT opportunity_human_reviews_organisation_id_fkey FOREIGN KEY (organisation_id) REFERENCES public.organisations(id) ON DELETE RESTRICT;

--
-- Name: opportunity_human_reviews opportunity_human_reviews_reviewer_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opportunity_human_reviews
    ADD CONSTRAINT opportunity_human_reviews_reviewer_user_id_fkey FOREIGN KEY (reviewer_user_id) REFERENCES public.marketroute_users(id) ON DELETE RESTRICT;

--
-- Name: opportunity_human_reviews opportunity_human_reviews_scope_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opportunity_human_reviews
    ADD CONSTRAINT opportunity_human_reviews_scope_fk FOREIGN KEY (opportunity_id, organisation_id) REFERENCES public.opportunities(id, organisation_id) ON DELETE RESTRICT;

--
-- Name: opportunity_sync_events opportunity_sync_events_campaign_scope_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opportunity_sync_events
    ADD CONSTRAINT opportunity_sync_events_campaign_scope_fk FOREIGN KEY (organisation_id, campaign_id) REFERENCES public.campaigns(organisation_id, id) ON DELETE RESTRICT;

--
-- Name: opportunity_sync_events opportunity_sync_events_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opportunity_sync_events
    ADD CONSTRAINT opportunity_sync_events_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;

--
-- Name: opportunity_sync_events opportunity_sync_events_opportunity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opportunity_sync_events
    ADD CONSTRAINT opportunity_sync_events_opportunity_id_fkey FOREIGN KEY (opportunity_id) REFERENCES public.opportunities(id) ON DELETE RESTRICT;

--
-- Name: opportunity_sync_events opportunity_sync_events_opportunity_scope_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opportunity_sync_events
    ADD CONSTRAINT opportunity_sync_events_opportunity_scope_fk FOREIGN KEY (opportunity_id, organisation_id) REFERENCES public.opportunities(id, organisation_id) ON DELETE RESTRICT;

--
-- Name: opportunity_sync_events opportunity_sync_events_organisation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opportunity_sync_events
    ADD CONSTRAINT opportunity_sync_events_organisation_id_fkey FOREIGN KEY (organisation_id) REFERENCES public.organisations(id) ON DELETE RESTRICT;

--
-- Name: opportunity_workflow_events opportunity_workflow_events_actor_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opportunity_workflow_events
    ADD CONSTRAINT opportunity_workflow_events_actor_user_id_fkey FOREIGN KEY (actor_user_id) REFERENCES public.marketroute_users(id) ON DELETE RESTRICT;

--
-- Name: opportunity_workflow_events opportunity_workflow_events_organisation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opportunity_workflow_events
    ADD CONSTRAINT opportunity_workflow_events_organisation_id_fkey FOREIGN KEY (organisation_id) REFERENCES public.organisations(id) ON DELETE RESTRICT;

--
-- Name: opportunity_workflow_events opportunity_workflow_events_scope_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opportunity_workflow_events
    ADD CONSTRAINT opportunity_workflow_events_scope_fk FOREIGN KEY (opportunity_id, organisation_id) REFERENCES public.opportunities(id, organisation_id) ON DELETE RESTRICT;

--
-- Name: organisation_commercial_entitlements organisation_commercial_entitlements_organisation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organisation_commercial_entitlements
    ADD CONSTRAINT organisation_commercial_entitlements_organisation_id_fkey FOREIGN KEY (organisation_id) REFERENCES public.organisations(id) ON DELETE RESTRICT;

--
-- Name: organisation_commercial_entitlements organisation_commercial_entitlements_plan_code_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organisation_commercial_entitlements
    ADD CONSTRAINT organisation_commercial_entitlements_plan_code_fkey FOREIGN KEY (plan_code) REFERENCES public.marketroute_plan_catalog(plan_code) ON DELETE RESTRICT;

--
-- Name: organisation_company_scopes organisation_company_scopes_campaign_scope_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organisation_company_scopes
    ADD CONSTRAINT organisation_company_scopes_campaign_scope_fk FOREIGN KEY (organisation_id, campaign_id) REFERENCES public.campaigns(organisation_id, id) ON DELETE CASCADE;

--
-- Name: organisation_company_scopes organisation_company_scopes_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organisation_company_scopes
    ADD CONSTRAINT organisation_company_scopes_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;

--
-- Name: organisation_company_scopes organisation_company_scopes_organisation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organisation_company_scopes
    ADD CONSTRAINT organisation_company_scopes_organisation_id_fkey FOREIGN KEY (organisation_id) REFERENCES public.organisations(id) ON DELETE CASCADE;

--
-- Name: organisation_memberships organisation_memberships_organisation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organisation_memberships
    ADD CONSTRAINT organisation_memberships_organisation_id_fkey FOREIGN KEY (organisation_id) REFERENCES public.organisations(id) ON DELETE RESTRICT;

--
-- Name: organisation_memberships organisation_memberships_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organisation_memberships
    ADD CONSTRAINT organisation_memberships_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.marketroute_users(id) ON DELETE CASCADE;

--
-- Name: organisations organisations_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organisations
    ADD CONSTRAINT organisations_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.marketroute_users(id) ON DELETE RESTRICT;

--
-- Name: paid_campaign_refill_jobs paid_campaign_refill_campaign_scope_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.paid_campaign_refill_jobs
    ADD CONSTRAINT paid_campaign_refill_campaign_scope_fk FOREIGN KEY (organisation_id, campaign_id) REFERENCES public.campaigns(organisation_id, id) ON DELETE RESTRICT;

--
-- Name: paid_campaign_refill_jobs paid_campaign_refill_jobs_organisation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.paid_campaign_refill_jobs
    ADD CONSTRAINT paid_campaign_refill_jobs_organisation_id_fkey FOREIGN KEY (organisation_id) REFERENCES public.organisations(id) ON DELETE RESTRICT;

--
-- Name: reasoning_artifacts reasoning_artifacts_reasoning_run_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reasoning_artifacts
    ADD CONSTRAINT reasoning_artifacts_reasoning_run_id_fkey FOREIGN KEY (reasoning_run_id) REFERENCES public.reasoning_runs(id) ON DELETE RESTRICT;

--
-- Name: reasoning_runs reasoning_runs_campaign_scope_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reasoning_runs
    ADD CONSTRAINT reasoning_runs_campaign_scope_fk FOREIGN KEY (organisation_id, campaign_id) REFERENCES public.campaigns(organisation_id, id) ON DELETE RESTRICT;

--
-- Name: reasoning_runs reasoning_runs_organisation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reasoning_runs
    ADD CONSTRAINT reasoning_runs_organisation_id_fkey FOREIGN KEY (organisation_id) REFERENCES public.organisations(id) ON DELETE RESTRICT;

--
-- Name: research_budget_events research_budget_events_campaign_scope_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_budget_events
    ADD CONSTRAINT research_budget_events_campaign_scope_fk FOREIGN KEY (organisation_id, campaign_id) REFERENCES public.campaigns(organisation_id, id) ON DELETE RESTRICT;

--
-- Name: research_budget_events research_budget_events_organisation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_budget_events
    ADD CONSTRAINT research_budget_events_organisation_id_fkey FOREIGN KEY (organisation_id) REFERENCES public.organisations(id) ON DELETE RESTRICT;

--
-- Name: research_budget_events research_budget_events_scheduler_run_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_budget_events
    ADD CONSTRAINT research_budget_events_scheduler_run_id_fkey FOREIGN KEY (scheduler_run_id) REFERENCES public.scheduler_runs(id) ON DELETE SET NULL;

--
-- Name: research_budget_events research_budget_events_work_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_budget_events
    ADD CONSTRAINT research_budget_events_work_unit_id_fkey FOREIGN KEY (work_unit_id) REFERENCES public.research_work_units(id) ON DELETE RESTRICT;

--
-- Name: research_budget_policies research_budget_policies_campaign_scope_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_budget_policies
    ADD CONSTRAINT research_budget_policies_campaign_scope_fk FOREIGN KEY (organisation_id, campaign_id) REFERENCES public.campaigns(organisation_id, id) ON DELETE CASCADE;

--
-- Name: research_budget_policies research_budget_policies_organisation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_budget_policies
    ADD CONSTRAINT research_budget_policies_organisation_id_fkey FOREIGN KEY (organisation_id) REFERENCES public.organisations(id) ON DELETE CASCADE;

--
-- Name: research_plan_runs research_plan_runs_campaign_scope_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_plan_runs
    ADD CONSTRAINT research_plan_runs_campaign_scope_fk FOREIGN KEY (organisation_id, campaign_id) REFERENCES public.campaigns(organisation_id, id) ON DELETE RESTRICT;

--
-- Name: research_plan_runs research_plan_runs_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_plan_runs
    ADD CONSTRAINT research_plan_runs_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;

--
-- Name: research_plan_runs research_plan_runs_organisation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_plan_runs
    ADD CONSTRAINT research_plan_runs_organisation_id_fkey FOREIGN KEY (organisation_id) REFERENCES public.organisations(id) ON DELETE RESTRICT;

--
-- Name: research_work_units research_work_units_background_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_work_units
    ADD CONSTRAINT research_work_units_background_job_id_fkey FOREIGN KEY (background_job_id) REFERENCES public.background_jobs(id) ON DELETE RESTRICT;

--
-- Name: research_work_units research_work_units_campaign_scope_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_work_units
    ADD CONSTRAINT research_work_units_campaign_scope_fk FOREIGN KEY (organisation_id, campaign_id) REFERENCES public.campaigns(organisation_id, id) ON DELETE RESTRICT;

--
-- Name: research_work_units research_work_units_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_work_units
    ADD CONSTRAINT research_work_units_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;

--
-- Name: research_work_units research_work_units_organisation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_work_units
    ADD CONSTRAINT research_work_units_organisation_id_fkey FOREIGN KEY (organisation_id) REFERENCES public.organisations(id) ON DELETE RESTRICT;

--
-- Name: research_work_units research_work_units_plan_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.research_work_units
    ADD CONSTRAINT research_work_units_plan_id_fkey FOREIGN KEY (plan_id) REFERENCES public.research_plan_runs(id) ON DELETE RESTRICT;

--
-- Name: route_authority_r5_records route_authority_r5_campaign_scope_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.route_authority_r5_records
    ADD CONSTRAINT route_authority_r5_campaign_scope_fk FOREIGN KEY (organisation_id, campaign_id) REFERENCES public.campaigns(organisation_id, id) ON DELETE RESTRICT;

--
-- Name: route_authority_r5_records route_authority_r5_records_authority_record_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.route_authority_r5_records
    ADD CONSTRAINT route_authority_r5_records_authority_record_id_fkey FOREIGN KEY (authority_record_id) REFERENCES public.authority_records(id) ON DELETE RESTRICT;

--
-- Name: route_authority_r5_records route_authority_r5_records_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.route_authority_r5_records
    ADD CONSTRAINT route_authority_r5_records_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;

--
-- Name: route_authority_r5_records route_authority_r5_records_organisation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.route_authority_r5_records
    ADD CONSTRAINT route_authority_r5_records_organisation_id_fkey FOREIGN KEY (organisation_id) REFERENCES public.organisations(id) ON DELETE RESTRICT;

--
-- Name: route_authority_r5_records route_authority_r5_records_parent_r4_authority_record_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.route_authority_r5_records
    ADD CONSTRAINT route_authority_r5_records_parent_r4_authority_record_id_fkey FOREIGN KEY (parent_r4_authority_record_id) REFERENCES public.authority_records(id) ON DELETE RESTRICT;

--
-- Name: scheduler_leases scheduler_leases_owner_run_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scheduler_leases
    ADD CONSTRAINT scheduler_leases_owner_run_id_fkey FOREIGN KEY (owner_run_id) REFERENCES public.scheduler_runs(id) ON DELETE CASCADE;

--
-- Name: seller_businesses seller_businesses_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_businesses
    ADD CONSTRAINT seller_businesses_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.marketroute_users(id) ON DELETE RESTRICT;

--
-- Name: seller_businesses seller_businesses_organisation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_businesses
    ADD CONSTRAINT seller_businesses_organisation_id_fkey FOREIGN KEY (organisation_id) REFERENCES public.organisations(id) ON DELETE RESTRICT;

--
-- Name: seller_commercial_genome_snapshots seller_commercial_genome_snapshots_organisation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_commercial_genome_snapshots
    ADD CONSTRAINT seller_commercial_genome_snapshots_organisation_id_fkey FOREIGN KEY (organisation_id) REFERENCES public.organisations(id) ON DELETE RESTRICT;

--
-- Name: seller_commercial_genome_snapshots seller_commercial_genome_snapshots_source_material_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_commercial_genome_snapshots
    ADD CONSTRAINT seller_commercial_genome_snapshots_source_material_id_fkey FOREIGN KEY (source_material_id) REFERENCES public.seller_genome_source_materials(id) ON DELETE RESTRICT;

--
-- Name: seller_commercial_genome_snapshots seller_genome_snapshots_scope_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_commercial_genome_snapshots
    ADD CONSTRAINT seller_genome_snapshots_scope_fk FOREIGN KEY (organisation_id, seller_business_id) REFERENCES public.seller_businesses(organisation_id, id) ON DELETE RESTRICT;

--
-- Name: seller_genome_source_materials seller_genome_source_materials_created_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_genome_source_materials
    ADD CONSTRAINT seller_genome_source_materials_created_by_user_id_fkey FOREIGN KEY (created_by_user_id) REFERENCES public.marketroute_users(id) ON DELETE SET NULL;

--
-- Name: seller_genome_source_materials seller_genome_source_materials_organisation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_genome_source_materials
    ADD CONSTRAINT seller_genome_source_materials_organisation_id_fkey FOREIGN KEY (organisation_id) REFERENCES public.organisations(id) ON DELETE RESTRICT;

--
-- Name: seller_genome_source_materials seller_genome_source_materials_scope_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_genome_source_materials
    ADD CONSTRAINT seller_genome_source_materials_scope_fk FOREIGN KEY (organisation_id, seller_business_id) REFERENCES public.seller_businesses(organisation_id, id) ON DELETE RESTRICT;

--
-- Name: source_acquisitions source_acquisitions_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.source_acquisitions
    ADD CONSTRAINT source_acquisitions_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.source_records(id) ON DELETE RESTRICT;

--
-- Name: truth_claim_policy_bindings truth_claim_policy_bindings_policy_key_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.truth_claim_policy_bindings
    ADD CONSTRAINT truth_claim_policy_bindings_policy_key_fkey FOREIGN KEY (policy_key) REFERENCES public.truth_claim_policy_registry(policy_key) ON DELETE RESTRICT;

--
-- Name: truth_claim_snapshots truth_claim_snapshots_claim_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.truth_claim_snapshots
    ADD CONSTRAINT truth_claim_snapshots_claim_id_fkey FOREIGN KEY (claim_id) REFERENCES public.claims(id) ON DELETE RESTRICT;

--
-- Name: truth_claim_snapshots truth_claim_snapshots_policy_key_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.truth_claim_snapshots
    ADD CONSTRAINT truth_claim_snapshots_policy_key_fkey FOREIGN KEY (policy_key) REFERENCES public.truth_claim_policy_registry(policy_key) ON DELETE RESTRICT;

--
-- Name: truth_claim_snapshots truth_claim_snapshots_reasoning_artifact_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.truth_claim_snapshots
    ADD CONSTRAINT truth_claim_snapshots_reasoning_artifact_fk FOREIGN KEY (reasoning_artifact_id, reasoning_run_id) REFERENCES public.reasoning_artifacts(id, reasoning_run_id) ON DELETE RESTRICT;

--
-- Name: truth_claim_snapshots truth_claim_snapshots_tenant_scope_organisation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.truth_claim_snapshots
    ADD CONSTRAINT truth_claim_snapshots_tenant_scope_organisation_id_fkey FOREIGN KEY (tenant_scope_organisation_id) REFERENCES public.organisations(id) ON DELETE RESTRICT;

--
-- Name: truth_entity_snapshots truth_entity_snapshots_profile_key_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.truth_entity_snapshots
    ADD CONSTRAINT truth_entity_snapshots_profile_key_fkey FOREIGN KEY (profile_key) REFERENCES public.truth_entity_profile_registry(profile_key) ON DELETE RESTRICT;

--
-- Name: truth_entity_snapshots truth_entity_snapshots_reasoning_artifact_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.truth_entity_snapshots
    ADD CONSTRAINT truth_entity_snapshots_reasoning_artifact_fk FOREIGN KEY (reasoning_artifact_id, reasoning_run_id) REFERENCES public.reasoning_artifacts(id, reasoning_run_id) ON DELETE RESTRICT;

--
-- Name: truth_entity_snapshots truth_entity_snapshots_tenant_scope_organisation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.truth_entity_snapshots
    ADD CONSTRAINT truth_entity_snapshots_tenant_scope_organisation_id_fkey FOREIGN KEY (tenant_scope_organisation_id) REFERENCES public.organisations(id) ON DELETE RESTRICT;

--
-- Name: workspace_activation_jobs workspace_activation_jobs_organisation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_activation_jobs
    ADD CONSTRAINT workspace_activation_jobs_organisation_id_fkey FOREIGN KEY (organisation_id) REFERENCES public.organisations(id) ON DELETE CASCADE;

--
-- Name: workspace_activation_jobs workspace_activation_seller_scope_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_activation_jobs
    ADD CONSTRAINT workspace_activation_seller_scope_fk FOREIGN KEY (organisation_id, seller_business_id) REFERENCES public.seller_businesses(organisation_id, id) ON DELETE CASCADE;

--
-- PostgreSQL database dump complete
--

\unrestrict H6oion6irRscKYY6yIc16BK2Fblj2c5ajYd4s2c05hb6HmTNdecG436YImEwPZ3

-- REVIEWED CANONICAL CONFIGURATION — 19 SOURCE STATEMENTS
-- source 0007_truth_engine_v2.sql:5 INCLUDE_CANONICAL_CONFIGURATION
INSERT INTO public.truth_claim_policy_registry(
  policy_key, policy_version, max_age_days, known_support_family_requirement, metadata_json
) VALUES
  ('GENERAL_FACT_V1', '1.0.0', 180, 2, jsonb_build_object('purpose', 'default factual claim')),
  ('IDENTITY_V1', '1.0.0', 365, 2, jsonb_build_object('purpose', 'entity identity claim')),
  ('CURRENT_STATE_V1', '1.0.0', 120, 2, jsonb_build_object('purpose', 'time-sensitive current-state claim'));

-- source 0007_truth_engine_v2.sql:6 INCLUDE_CANONICAL_CONFIGURATION
INSERT INTO public.truth_claim_policy_bindings(subject_type, claim_key, policy_key, precedence) VALUES
  ('COMPANY', 'identity.canonical_name', 'IDENTITY_V1', 10),
  ('COMPANY', 'identity.canonical_domain', 'IDENTITY_V1', 11),
  ('COMPANY', 'operation.current', 'CURRENT_STATE_V1', 12),
  ('PERSON', 'identity.canonical_name', 'IDENTITY_V1', 20),
  ('PERSON', 'employment.current', 'CURRENT_STATE_V1', 21),
  ('PERSON', 'role.current', 'CURRENT_STATE_V1', 22),
  ('CHANNEL', 'ownership.current', 'CURRENT_STATE_V1', 30),
  ('*', '*', 'GENERAL_FACT_V1', 10000);

-- source 0007_truth_engine_v2.sql:7 INCLUDE_CANONICAL_CONFIGURATION
INSERT INTO public.truth_entity_profile_registry(
  profile_key, profile_version, subject_type, required_claim_keys, metadata_json
) VALUES
  (
    'COMPANY_CORE_V1', '1.0.0', 'COMPANY',
    '["identity.canonical_name","identity.canonical_domain","operation.current"]'::jsonb,
    jsonb_build_object('truth_index_semantics', 'MAXIMIN_EPISTEMIC_READINESS_NOT_PROBABILITY')
  ),
  (
    'SELLER_BUSINESS_CORE_V1', '1.0.0', 'SELLER_BUSINESS',
    '["identity.canonical_name","identity.canonical_domain"]'::jsonb,
    jsonb_build_object('truth_index_semantics', 'MAXIMIN_EPISTEMIC_READINESS_NOT_PROBABILITY')
  );

-- ===== 0009_commercial_reality_r4.sql =====
-- source 0009_commercial_reality_r4.sql:2 INCLUDE_CANONICAL_CONFIGURATION
-- MarketRoute V2 Build 6: Commercial Reality / R4
-- First and only commercial authority writer introduced by this build.

INSERT INTO public.authority_writer_registry(
  writer_key, authority_stage, writer_version, enabled, registered_by_build, metadata_json
) VALUES (
  'marketroute.r4.commercial-reality',
  'COMMERCIAL_REALITY',
  '1.0.0',
  true,
  6,
  jsonb_build_object(
    'engine_version', 'MRV2-R4-1.0.0',
    'semantics_version', 'MRV2-R4-SEM-1.0.0',
    'boundary_constitution_version', 'MRV2-R4-BOUNDARIES-1.0.0',
    'reality_class', 'SELLER_TO_TARGET_COMMERCIAL_ENGAGEMENT_V1',
    'numeric_authority', false
  )
)
ON CONFLICT (writer_key) DO NOTHING;

-- source 0009_commercial_reality_r4.sql:5 INCLUDE_CANONICAL_CONFIGURATION
INSERT INTO public.commercial_reality_boundary_constitutions(
  constitution_key, constitution_version, reality_class, mandatory_boundary_keys,
  max_authority_hours, accepted_truth_states, metadata_json
) VALUES (
  'SELLER_TO_TARGET_V1',
  'MRV2-R4-BOUNDARIES-1.0.0',
  'SELLER_TO_TARGET_COMMERCIAL_ENGAGEMENT_V1',
  '["seller.offering_present","seller.objective_selected","seller.constraints_known","target.identity","target.canonical_domain","target.current_operation"]'::jsonb,
  24,
  '["KNOWN","SUPPORTED"]'::jsonb,
  jsonb_build_object(
    'rule', 'ALL_MANDATORY_AND_HARD_CONSTRAINT_BOUNDARIES_MUST_BE_SATISFIED_FOR_CANDIDATE',
    'contradiction_precedence', true,
    'continuous_thresholds', false,
    'unsupported_hard_constraint', 'RESEARCH_REQUIRED'
  )
);

-- ===== 0010_relationship_truth_and_route_authority_r5.sql =====
-- source 0010_relationship_truth_and_route_authority_r5.sql:2 INCLUDE_CANONICAL_CONFIGURATION
-- MarketRoute V2 Build 7: Relationship Truth + Canonical Commercial Graph / R5
-- Relationships are canonical world assertions whose existence must pass Truth before graph traversal.

INSERT INTO public.truth_claim_policy_registry(policy_key,policy_version,max_age_days,known_support_family_requirement,metadata_json)
VALUES('RELATIONSHIP_CURRENT_V1','1.0.0',120,2,jsonb_build_object('purpose','commercial relationship/access structural currentness'))
ON CONFLICT (policy_key) DO UPDATE SET
  policy_version=EXCLUDED.policy_version,
  max_age_days=EXCLUDED.max_age_days,
  known_support_family_requirement=EXCLUDED.known_support_family_requirement,
  metadata_json=EXCLUDED.metadata_json;

-- source 0010_relationship_truth_and_route_authority_r5.sql:3 INCLUDE_CANONICAL_CONFIGURATION
INSERT INTO public.truth_claim_policy_bindings(subject_type,claim_key,policy_key,precedence)
VALUES('RELATIONSHIP','relationship.exists','RELATIONSHIP_CURRENT_V1',40)
ON CONFLICT (subject_type,claim_key) DO UPDATE SET policy_key=EXCLUDED.policy_key, precedence=EXCLUDED.precedence;

-- source 0010_relationship_truth_and_route_authority_r5.sql:5 INCLUDE_CANONICAL_CONFIGURATION
INSERT INTO public.commercial_relationship_type_registry(relation_type,edge_class,direction,route_traversable,allowed_from_kinds,allowed_to_kinds,ontology_version) VALUES
('depends_on','DEPENDENCY','DIRECTED',false,'["COMPANY"]','["COMPANY","TECHNOLOGY"]','MRV2-RELATIONSHIP-ONTOLOGY-1.0.0'),
('equivalent_to','ASSOCIATION','UNDIRECTED',false,'["COMPANY","TECHNOLOGY"]','["COMPANY","TECHNOLOGY"]','MRV2-RELATIONSHIP-ONTOLOGY-1.0.0'),
('part_of','HIERARCHY','DIRECTED',false,'["ORGANISATIONAL_UNIT","COMPANY"]','["COMPANY"]','MRV2-RELATIONSHIP-ONTOLOGY-1.0.0'),
('parent_of','HIERARCHY','DIRECTED',true,'["COMPANY"]','["ORGANISATIONAL_UNIT"]','MRV2-RELATIONSHIP-ONTOLOGY-1.0.0'),
('subsidiary_of','HIERARCHY','DIRECTED',false,'["COMPANY"]','["COMPANY"]','MRV2-RELATIONSHIP-ONTOLOGY-1.0.0'),
('partners_with','ASSOCIATION','UNDIRECTED',false,'["COMPANY"]','["COMPANY"]','MRV2-RELATIONSHIP-ONTOLOGY-1.0.0'),
('supplies','ASSOCIATION','DIRECTED',false,'["COMPANY"]','["COMPANY"]','MRV2-RELATIONSHIP-ONTOLOGY-1.0.0'),
('customer_of','ASSOCIATION','DIRECTED',false,'["COMPANY"]','["COMPANY"]','MRV2-RELATIONSHIP-ONTOLOGY-1.0.0'),
('uses_technology_from','DEPENDENCY','DIRECTED',false,'["COMPANY"]','["COMPANY","TECHNOLOGY"]','MRV2-RELATIONSHIP-ONTOLOGY-1.0.0'),
('supersedes','ASSOCIATION','DIRECTED',false,'["COMPANY","TECHNOLOGY"]','["COMPANY","TECHNOLOGY"]','MRV2-RELATIONSHIP-ONTOLOGY-1.0.0'),
('employs','COMPOSITION','DIRECTED',true,'["COMPANY"]','["PERSON"]','MRV2-RELATIONSHIP-ONTOLOGY-1.0.0'),
('has_access_point','ACCESS','DIRECTED',true,'["COMPANY","PERSON","ORGANISATIONAL_UNIT"]','["ACCESS_POINT"]','MRV2-RELATIONSHIP-ONTOLOGY-1.0.0'),
('introduced_by','ACCESS','DIRECTED',true,'["COMPANY"]','["COMPANY"]','MRV2-RELATIONSHIP-ONTOLOGY-1.0.0')
ON CONFLICT (relation_type) DO NOTHING;

-- source 0010_relationship_truth_and_route_authority_r5.sql:22 INCLUDE_CANONICAL_CONFIGURATION
INSERT INTO public.authority_writer_registry(writer_key,authority_stage,writer_version,enabled,registered_by_build,metadata_json)
VALUES('marketroute.r5.relationship-graph','ROUTE_AUTHORITY','1.0.0',true,7,jsonb_build_object('numeric_authority',false,'database_recomputes_decision',true,'database_recomputes_fingerprint',true))
ON CONFLICT (writer_key) DO NOTHING;

-- ===== 0011_contact_truth_and_authority_r6.sql =====
-- source 0011_contact_truth_and_authority_r6.sql:2 INCLUDE_CANONICAL_CONFIGURATION
-- MarketRoute V2 Build 8: Contact Truth / R6
-- R5 proves route structure. R6 proves named-person identity, current employment, current role and exact channel ownership.

INSERT INTO public.authority_writer_registry(writer_key,authority_stage,writer_version,enabled,registered_by_build,metadata_json)
VALUES('marketroute.r6.contact-truth','CONTACT_AUTHORITY','1.0.0',true,8,jsonb_build_object('engine_version','MRV2-R6-ENGINE-1.0.0','semantics_version','MRV2-R6-SEMANTICS-1.0.0','numeric_authority',false,'named_contact_truth_required',true,'organisational_routes_do_not_require_person',true))
ON CONFLICT(writer_key) DO NOTHING;

-- source 0011_contact_truth_and_authority_r6.sql:4 INCLUDE_CANONICAL_CONFIGURATION
INSERT INTO public.truth_claim_policy_registry(policy_key,policy_version,max_age_days,known_support_family_requirement,metadata_json) VALUES
('PERSON_CURRENT_EMPLOYMENT_V1','1.0.0',180,2,jsonb_build_object('purpose','current employer relationship for contact authority')),
('PERSON_CURRENT_ROLE_V1','1.0.0',180,2,jsonb_build_object('purpose','current role at employer for contact authority')),
('CHANNEL_OWNERSHIP_CURRENT_V1','1.0.0',120,2,jsonb_build_object('purpose','current person ownership of personal contact channel'))
ON CONFLICT(policy_key) DO NOTHING;

-- source 0011_contact_truth_and_authority_r6.sql:5 INCLUDE_CANONICAL_CONFIGURATION
UPDATE public.truth_claim_policy_bindings SET policy_key='PERSON_CURRENT_EMPLOYMENT_V1' WHERE subject_type='PERSON' AND claim_key='employment.current';

-- source 0011_contact_truth_and_authority_r6.sql:6 INCLUDE_CANONICAL_CONFIGURATION
UPDATE public.truth_claim_policy_bindings SET policy_key='PERSON_CURRENT_ROLE_V1' WHERE subject_type='PERSON' AND claim_key='role.current';

-- source 0011_contact_truth_and_authority_r6.sql:7 INCLUDE_CANONICAL_CONFIGURATION
UPDATE public.truth_claim_policy_bindings SET policy_key='CHANNEL_OWNERSHIP_CURRENT_V1' WHERE subject_type='CHANNEL' AND claim_key='ownership.current';

-- source 0022_genesis_database_growth.sql:3 INCLUDE_CANONICAL_CONFIGURATION
INSERT INTO public.genesis_growth_industries(industry_key,display_name,priority,seed_target_company_count,launch_target_company_count)
VALUES
 ('software','Software & SaaS',100,50,500),
 ('professional-services','Professional Services',95,50,500),
 ('marketing','Marketing & Advertising',90,50,500),
 ('recruitment','Recruitment & HR',90,50,500),
 ('finance','Finance & FinTech',85,50,500),
 ('healthcare','Healthcare & HealthTech',85,50,500),
 ('retail','Retail & E-commerce',80,50,500),
 ('manufacturing','Manufacturing',80,50,500),
 ('logistics','Logistics & Supply Chain',80,50,500),
 ('construction','Construction & PropTech',75,50,500)
ON CONFLICT(industry_key) DO UPDATE SET display_name=EXCLUDED.display_name,priority=EXCLUDED.priority;

-- source 0022_genesis_database_growth.sql:10 INCLUDE_CANONICAL_CONFIGURATION
INSERT INTO public.genesis_growth_settings(singleton) VALUES(true) ON CONFLICT(singleton) DO NOTHING;

-- ===== 0039_product_demand_driven_genesis.sql =====
-- source 0039_product_demand_driven_genesis.sql:2 INCLUDE_CANONICAL_CONFIGURATION
-- MarketRoute V2 Product Build 19: Demand-Driven Genesis.
--
-- Product policy:
--   * speculative/background Genesis database growth is paused;
--   * existing global Genesis intelligence remains fully reusable;
--   * customer campaign activation/research remains active and budget-governed;
--   * autonomous growth can only be intentionally re-enabled later.
--
-- This migration creates no authority writer and changes no Truth/R4/R5/R6/opportunity mathematics.

UPDATE public.genesis_growth_settings
SET enabled = false,
    updated_at = now()
WHERE singleton = true;

-- source 0044_product_locked_opportunities_commercial_boundary.sql:3 INCLUDE_CANONICAL_CONFIGURATION
INSERT INTO public.marketroute_plan_catalog(plan_code,display_name,monthly_price_gbp,research_capacity_units,active_market_limit,team_seat_limit,public_visible,sort_order,metadata_json)
VALUES
 ('DISCOVERY','MarketRoute Discovery',0,0,1,1,false,0,jsonb_build_object('billingCadence','ONE_TIME','freeOpportunityLimit',8,'capacityLabel','Discovery run only')),
 ('STARTER','Starter',99,100,1,1,true,10,jsonb_build_object('capacityLabel','Core research capacity','depthLabel','Standard research depth','monitoringLabel','Essential monitoring')),
 ('GROWTH','Growth',249,400,1,5,true,20,jsonb_build_object('recommended',true,'capacityLabel','Expanded research capacity','depthLabel','Deeper company research','monitoringLabel','Continuous monitoring')),
 ('SCALE','Scale',599,1200,1,15,true,30,jsonb_build_object('capacityLabel','Highest research capacity','depthLabel','Priority research depth','monitoringLabel','Priority monitoring')),
 ('LEGACY_FULL','Legacy full access',0,NULL,1,NULL,false,100,jsonb_build_object('migrationOnly',true,'capacityLabel','Unmetered legacy access'))
ON CONFLICT(plan_code) DO UPDATE SET
  display_name=EXCLUDED.display_name,monthly_price_gbp=EXCLUDED.monthly_price_gbp,research_capacity_units=EXCLUDED.research_capacity_units,
  active_market_limit=EXCLUDED.active_market_limit,team_seat_limit=EXCLUDED.team_seat_limit,public_visible=EXCLUDED.public_visible,
  sort_order=EXCLUDED.sort_order,metadata_json=EXCLUDED.metadata_json,updated_at=now();

-- ===== 0053_multi_campaign_plan_governance.sql =====
-- source 0053_multi_campaign_plan_governance.sql:2 INCLUDE_CANONICAL_CONFIGURATION
-- MarketRoute V2 RC: explicit multi-campaign governance + immutable Discovery lineage.
-- Product/commercial orchestration only. No Truth, R4, R5, R6, CIE or opportunity
-- authority semantics are created or modified here.
--
-- Launch active-market allowances:
--   Discovery: 1 original run only (no additional campaign creation)
--   Starter:   1 live campaign
--   Growth:    3 live campaigns
--   Scale:    10 live campaigns
-- Paused campaigns consume a slot; ARCHIVED campaigns do not.

UPDATE public.marketroute_plan_catalog
SET active_market_limit = CASE plan_code
    WHEN 'DISCOVERY' THEN 1
    WHEN 'STARTER' THEN 1
    WHEN 'GROWTH' THEN 3
    WHEN 'SCALE' THEN 10
    WHEN 'LEGACY_FULL' THEN 100
    ELSE active_market_limit
  END,
  metadata_json = metadata_json || jsonb_build_object(
    'activeMarketLabel', CASE plan_code
      WHEN 'DISCOVERY' THEN 'One Discovery market'
      WHEN 'STARTER' THEN '1 active market'
      WHEN 'GROWTH' THEN 'Up to 3 active markets'
      WHEN 'SCALE' THEN 'Up to 10 active markets'
      WHEN 'LEGACY_FULL' THEN 'Legacy full market access'
      ELSE COALESCE(metadata_json->>'activeMarketLabel','Active markets')
    END
  ),
  updated_at = now()
WHERE plan_code IN ('DISCOVERY','STARTER','GROWTH','SCALE','LEGACY_FULL');
