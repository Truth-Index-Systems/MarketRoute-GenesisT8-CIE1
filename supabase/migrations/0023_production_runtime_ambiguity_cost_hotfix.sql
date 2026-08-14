BEGIN;

-- MarketRoute V2 production hotfix 0.18.3.2
-- Corrects 0.18.3.1 without weakening the append-only evidence/budget constitution.
-- 1) Fixes claim_id ambiguity in claim/evidence linking.
-- 2) Fixes attempt_count ambiguity in workspace activation claiming.
-- 3) Preserves immutable genesis_growth_budget_events.
-- 4) Recovers historical paid growth cost onto action-run state and computes effective spend without mutating the ledger.
-- 5) Keeps recovery-first research for partially persisted 20% companies.

CREATE OR REPLACE FUNCTION public.marketroute_record_claim_evidence_v1(
  p_tenant_scope_organisation_id uuid,
  p_subject_type text,
  p_subject_id uuid,
  p_claim_key text,
  p_predicate text,
  p_object_json jsonb,
  p_canonical_value_text text,
  p_claim_fingerprint text,
  p_claim_fingerprint_version text,
  p_evidence_item_id uuid,
  p_polarity text,
  p_link_method text,
  p_link_version text
)
RETURNS TABLE(
  claim_id uuid,
  claim_evidence_link_id uuid,
  claim_created boolean,
  link_created boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
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
$fn$;

REVOKE ALL ON FUNCTION public.marketroute_record_claim_evidence_v1(uuid,text,uuid,text,text,jsonb,text,text,text,uuid,text,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_record_claim_evidence_v1(uuid,text,uuid,text,text,jsonb,text,text,text,uuid,text,text,text) TO service_role;

CREATE OR REPLACE FUNCTION public.marketroute_claim_workspace_activation_v1(
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
$fn$;

REVOKE ALL ON FUNCTION public.marketroute_claim_workspace_activation_v1(text,timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_claim_workspace_activation_v1(text,timestamptz) TO service_role;

-- Append-only compliant effective spend resolver.
-- Historical zero-value budget events are never mutated. Where a paid call was
-- already captured on the mutable action-run record, effective spend uses the
-- larger of the immutable ledger amount and the action-run amount. Future runs
-- continue writing one immutable budget event with the actual cost.
CREATE OR REPLACE FUNCTION public.marketroute_growth_effective_spend_v1(
  p_from timestamptz DEFAULT NULL,
  p_to timestamptz DEFAULT NULL
) RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
  SELECT COALESCE(sum(GREATEST(COALESCE(ar.actual_cost_usd,0),COALESCE(b.amount_usd,0))),0)::numeric
  FROM public.genesis_growth_action_runs AS ar
  LEFT JOIN public.genesis_growth_budget_events AS b ON b.action_run_id=ar.id
  WHERE (p_from IS NULL OR ar.started_at>=p_from)
    AND (p_to IS NULL OR ar.started_at<p_to);
$fn$;

REVOKE ALL ON FUNCTION public.marketroute_growth_effective_spend_v1(timestamptz,timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_growth_effective_spend_v1(timestamptz,timestamptz) TO service_role;

CREATE OR REPLACE FUNCTION public.marketroute_growth_next_action_v1(
  p_scheduler_run_id uuid,
  p_at timestamptz DEFAULT now()
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
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

  -- Recovery-first invariant: a company already admitted to the shared bank must not remain
  -- a 20% shell after a paid discovery call partially persisted. Repair CORE before acquiring
  -- additional breadth. Normal successful discovery has core_complete_at set and skips this path.
  SELECT p.company_id,m.industry_key
  INTO v_company,v_industry
  FROM public.genesis_growth_company_progress AS p
  JOIN public.genesis_growth_company_memberships AS m ON m.company_id=p.company_id
  WHERE p.core_complete_at IS NULL
    AND (p.retry_after IS NULL OR p.retry_after<=p_at)
  ORDER BY COALESCE(p.last_researched_at,'epoch'::timestamptz),p.created_at,m.industry_key,p.company_id
  LIMIT 1;

  IF v_company IS NOT NULL THEN
    v_phase:=CASE WHEN v_seed_remaining>0 THEN 'SEED' WHEN v_launch_remaining>0 THEN 'BREADTH' ELSE 'DEPTH' END;
    v_action:='RESEARCH_CORE_PROFILE';
  ELSIF v_seed_remaining>0 THEN
    v_phase:='SEED';
    SELECT i.industry_key INTO v_industry
    FROM public.genesis_growth_industries AS i
    WHERE i.enabled
      AND (SELECT count(*) FROM public.genesis_growth_company_memberships AS m WHERE m.industry_key=i.industry_key)<i.seed_target_company_count
    ORDER BY ((SELECT count(*) FROM public.genesis_growth_company_memberships AS m WHERE m.industry_key=i.industry_key)::numeric/greatest(1,i.seed_target_company_count)),i.priority DESC,i.industry_key
    LIMIT 1;
    v_action:='DISCOVER_COMPANIES';
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
              +(CASE WHEN p.contacts_complete_at IS NOT NULL THEN 1 ELSE 0 END)),
               COALESCE(p.last_researched_at,'epoch'::timestamptz),p.company_id
      LIMIT 1;
      SELECT m.industry_key INTO v_industry
      FROM public.genesis_growth_company_memberships AS m
      WHERE m.company_id=v_company
      ORDER BY m.industry_key LIMIT 1;
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
$fn$;

REVOKE ALL ON FUNCTION public.marketroute_growth_next_action_v1(uuid,timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_growth_next_action_v1(uuid,timestamptz) TO service_role;

-- Recover the cost on mutable action-run state for already-failed paid discovery calls.
-- IMPORTANT: genesis_growth_budget_events is append-only and is intentionally NOT updated.
WITH matched AS (
  SELECT ar.id AS action_run_id,
         ai.cost_usd
  FROM public.genesis_growth_action_runs AS ar
  JOIN LATERAL (
    SELECT e.cost_usd
    FROM public.ai_usage_events AS e
    WHERE e.request_kind = 'GENESIS_GROWTH_DISCOVERY'
      AND e.created_at >= ar.started_at - interval '2 seconds'
      AND e.created_at <= COALESCE(ar.completed_at, now()) + interval '30 seconds'
      AND COALESCE(e.cost_usd,0) > 0
    ORDER BY abs(extract(epoch FROM (e.created_at - ar.started_at))) ASC
    LIMIT 1
  ) AS ai ON true
  WHERE ar.action_kind = 'DISCOVER_COMPANIES'
    AND ar.status = 'FAILED'
    AND COALESCE(ar.actual_cost_usd,0) = 0
)
UPDATE public.genesis_growth_action_runs AS ar
SET actual_cost_usd = matched.cost_usd
FROM matched
WHERE ar.id = matched.action_run_id;

CREATE OR REPLACE FUNCTION public.marketroute_founder_dashboard_snapshot_v1(p_at timestamptz DEFAULT now())
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
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
      'migrationBatches',(SELECT count(*) FROM public.marketroute_v1_migration_batches),
      'migratedRecords',(SELECT count(*) FROM public.marketroute_v1_migration_id_map),
      'migrationRejections',(SELECT count(*) FROM public.marketroute_v1_migration_rejections)
    ),
    'growth',jsonb_build_object(
      'enabled',(SELECT enabled FROM public.genesis_growth_settings WHERE singleton=true),
      'phase',(CASE WHEN EXISTS(SELECT 1 FROM public.genesis_growth_industries i WHERE i.enabled AND (SELECT count(*) FROM public.genesis_growth_company_memberships m WHERE m.industry_key=i.industry_key)<i.seed_target_company_count) THEN 'SEED' WHEN EXISTS(SELECT 1 FROM public.genesis_growth_industries i WHERE i.enabled AND (SELECT count(*) FROM public.genesis_growth_company_memberships m WHERE m.industry_key=i.industry_key)<i.launch_target_company_count) THEN 'BREADTH' WHEN EXISTS(SELECT 1 FROM public.genesis_growth_company_progress p WHERE p.core_complete_at IS NULL OR p.profile_complete_at IS NULL OR p.routes_complete_at IS NULL OR p.contacts_complete_at IS NULL) THEN 'DEPTH' ELSE 'REFRESH' END),
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
      'nextPriorityIndustry',(SELECT i.display_name FROM public.genesis_growth_industries i WHERE i.enabled ORDER BY ((SELECT count(*) FROM public.genesis_growth_company_memberships m WHERE m.industry_key=i.industry_key)::numeric/greatest(1,i.launch_target_company_count)),i.priority DESC,i.industry_key LIMIT 1),
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
END;$fn$;
REVOKE ALL ON FUNCTION public.marketroute_founder_dashboard_snapshot_v1(timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_founder_dashboard_snapshot_v1(timestamptz) TO service_role;

NOTIFY pgrst, 'reload schema';
COMMIT;
