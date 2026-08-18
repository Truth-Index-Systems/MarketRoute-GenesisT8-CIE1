BEGIN;

-- MarketRoute RC: Market Map + Opportunities read performance hotfix.
-- List/overview surfaces consume a bounded materialised projection assembled from
-- indexed campaign scopes, materialised opportunity workflow, the latest persisted
-- R4/R5/R6 records and the latest opportunity sync snapshot. They do not execute
-- the expensive canonical authority-envelope/currentness graph once per row.
-- Exact current authority is still recomputed by COMPANY_INTELLIGENCE / route /
-- engagement detail reads before any customer action can execute.

CREATE OR REPLACE FUNCTION public.marketroute_application_materialised_profile_index_v1(
  p_organisation_id uuid,
  p_campaign_id uuid,
  p_opportunities_only boolean DEFAULT false,
  p_limit integer DEFAULT 100,
  p_offset integer DEFAULT 0,
  p_at timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
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
$fn$;

CREATE OR REPLACE FUNCTION public.marketroute_application_company_index_read_v1(
  p_organisation_id uuid,
  p_campaign_id uuid,
  p_limit integer DEFAULT 100,
  p_offset integer DEFAULT 0,
  p_at timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
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
$fn$;

CREATE OR REPLACE FUNCTION public.marketroute_application_opportunity_index_read_v1(
  p_organisation_id uuid,
  p_campaign_id uuid,
  p_limit integer DEFAULT 100,
  p_offset integer DEFAULT 0,
  p_at timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
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
$fn$;

REVOKE ALL ON FUNCTION public.marketroute_application_materialised_profile_index_v1(uuid,uuid,boolean,integer,integer,timestamptz)
FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.marketroute_application_company_index_read_v1(uuid,uuid,integer,integer,timestamptz)
FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.marketroute_application_opportunity_index_read_v1(uuid,uuid,integer,integer,timestamptz)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_application_materialised_profile_index_v1(uuid,uuid,boolean,integer,integer,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_application_company_index_read_v1(uuid,uuid,integer,integer,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_application_opportunity_index_read_v1(uuid,uuid,integer,integer,timestamptz) TO service_role;

INSERT INTO public.marketroute_schema_releases(
  release_key,build_number,constitution_version,metadata_json
)
VALUES(
  'MARKETROUTE_V2_RC_MARKET_MAP_OPPORTUNITY_READ_PERFORMANCE_HOTFIX',
  58,
  'MRV2-CONSTITUTION-1.0.0',
  jsonb_build_object(
    'migration','0058_market_map_opportunity_read_performance_hotfix.sql',
    'new_authority_writer',false,
    'authority_semantics_unchanged',true,
    'market_map_summary_only',true,
    'opportunity_index_summary_only',true,
    'per_row_authority_envelope_recomputation_removed',true,
    'per_row_opportunity_profile_recomputation_removed',true,
    'materialised_workflow_and_sync_projection_used',true,
    'detail_company_read_unchanged',true,
    'detail_route_read_unchanged',true,
    'engagement_execution_currentness_unchanged',true,
    'autonomous_delivery_enabled',false
  )
)
ON CONFLICT(release_key) DO UPDATE SET metadata_json=EXCLUDED.metadata_json;

NOTIFY pgrst,'reload schema';
COMMIT;
