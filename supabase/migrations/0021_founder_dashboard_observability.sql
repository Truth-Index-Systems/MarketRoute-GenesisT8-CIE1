BEGIN;

-- Production founder observability only. This migration does not create or mutate
-- Truth, R4, R5, R6, opportunity authority, engagement authority, or execution authority.
CREATE TABLE public.production_runtime_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  correlation_id uuid NOT NULL,
  runtime_kind text NOT NULL CHECK (runtime_kind IN ('BOOTSTRAP','RESEARCH','DELIVERY','PREFLIGHT','SMOKE')),
  event_type text NOT NULL CHECK (event_type IN ('STARTED','SUCCEEDED','FAILED','DISABLED')),
  duration_ms integer CHECK (duration_ms IS NULL OR duration_ms >= 0),
  error_code text,
  metadata_json jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata_json)='object'),
  occurred_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX production_runtime_events_kind_time_idx
  ON public.production_runtime_events(runtime_kind,occurred_at DESC,id DESC);
CREATE INDEX production_runtime_events_correlation_idx
  ON public.production_runtime_events(correlation_id,occurred_at,id);
CREATE TRIGGER production_runtime_events_append_only
BEFORE UPDATE OR DELETE ON public.production_runtime_events
FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

ALTER TABLE public.production_runtime_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.production_runtime_events FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT,INSERT ON public.production_runtime_events TO service_role;

CREATE OR REPLACE FUNCTION public.marketroute_record_runtime_event_v1(
  p_correlation_id uuid,
  p_runtime_kind text,
  p_event_type text,
  p_duration_ms integer DEFAULT NULL,
  p_error_code text DEFAULT NULL,
  p_metadata_json jsonb DEFAULT '{}'::jsonb,
  p_at timestamptz DEFAULT now()
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_id uuid;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF p_correlation_id IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_RUNTIME_CORRELATION_REQUIRED'; END IF;
  IF p_runtime_kind NOT IN ('BOOTSTRAP','RESEARCH','DELIVERY','PREFLIGHT','SMOKE') THEN RAISE EXCEPTION 'MARKETROUTE_RUNTIME_KIND_INVALID'; END IF;
  IF p_event_type NOT IN ('STARTED','SUCCEEDED','FAILED','DISABLED') THEN RAISE EXCEPTION 'MARKETROUTE_RUNTIME_EVENT_INVALID'; END IF;
  IF p_duration_ms IS NOT NULL AND p_duration_ms < 0 THEN RAISE EXCEPTION 'MARKETROUTE_RUNTIME_DURATION_INVALID'; END IF;
  IF jsonb_typeof(COALESCE(p_metadata_json,'{}'::jsonb)) <> 'object' THEN RAISE EXCEPTION 'MARKETROUTE_RUNTIME_METADATA_INVALID'; END IF;
  INSERT INTO public.production_runtime_events(correlation_id,runtime_kind,event_type,duration_ms,error_code,metadata_json,occurred_at)
  VALUES(p_correlation_id,p_runtime_kind,p_event_type,p_duration_ms,left(nullif(btrim(COALESCE(p_error_code,'')),''),500),COALESCE(p_metadata_json,'{}'::jsonb),COALESCE(p_at,now()))
  RETURNING id INTO v_id;
  RETURN v_id;
END;$fn$;
REVOKE ALL ON FUNCTION public.marketroute_record_runtime_event_v1(uuid,text,text,integer,text,jsonb,timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_record_runtime_event_v1(uuid,text,text,integer,text,jsonb,timestamptz) TO service_role;

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

INSERT INTO public.marketroute_schema_releases(release_key,build_number,constitution_version,metadata_json)
VALUES('MARKETROUTE_V2_FOUNDER_DASHBOARD_0_18_2',18,'MRV2-CONSTITUTION-1.0.0',jsonb_build_object(
  'migration','0021_founder_dashboard_observability.sql',
  'new_authority_writer',false,
  'founder_dashboard',true,
  'runtime_observability',true
)) ON CONFLICT(release_key) DO NOTHING;

NOTIFY pgrst,'reload schema';
COMMIT;
