BEGIN;

-- MarketRoute V2 Build 15: Core Application UI read indexes.
-- Read-only extensions to the canonical Build-13 application contract.
-- No authority, workflow, research or engagement mutation is introduced here.

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
SET search_path=public,pg_temp
AS $fn$
DECLARE
  v_limit integer:=greatest(1,least(COALESCE(p_limit,100),250));
  v_offset integer:=greatest(0,COALESCE(p_offset,0));
  v_total integer:=0;
  v_rows jsonb:='[]'::jsonb;
BEGIN
  PERFORM public.marketroute_require_service_role();
  PERFORM public.marketroute_application_require_current_read_time_v1(p_at);
  IF NOT EXISTS(SELECT 1 FROM public.campaigns c WHERE c.id=p_campaign_id AND c.organisation_id=p_organisation_id) THEN
    RAISE EXCEPTION 'MARKETROUTE_APPLICATION_COMPANY_INDEX_CAMPAIGN_NOT_FOUND';
  END IF;

  SELECT count(*)::int INTO v_total
  FROM public.organisation_company_scopes s
  WHERE s.organisation_id=p_organisation_id AND s.campaign_id=p_campaign_id AND s.scope_kind='CAMPAIGN';

  SELECT COALESCE(jsonb_agg(q.profile ORDER BY q.canonical_name,q.company_id),'[]'::jsonb) INTO v_rows
  FROM (
    SELECT c.canonical_name,c.id AS company_id,
      public.marketroute_opportunity_profile_v1(s.organisation_id,s.campaign_id,s.company_id,p_at) AS profile
    FROM public.organisation_company_scopes s
    JOIN public.companies c ON c.id=s.company_id
    WHERE s.organisation_id=p_organisation_id AND s.campaign_id=p_campaign_id AND s.scope_kind='CAMPAIGN'
    ORDER BY c.canonical_name,c.id
    LIMIT v_limit OFFSET v_offset
  ) q;

  RETURN jsonb_build_object(
    'contractVersion','MRV2-APPLICATION-READ-1.0.0',
    'resourceType','COMPANY_INDEX',
    'evaluatedAt',to_jsonb(p_at),
    'organisationId',p_organisation_id,
    'campaignId',p_campaign_id,
    'totalCount',v_total,
    'offset',v_offset,
    'limit',v_limit,
    'returnedCount',jsonb_array_length(v_rows),
    'companies',v_rows
  );
END $fn$;

CREATE OR REPLACE FUNCTION public.marketroute_application_research_activity_read_v1(
  p_organisation_id uuid,
  p_campaign_id uuid,
  p_at timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
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
END $fn$;

CREATE OR REPLACE FUNCTION public.marketroute_application_engagement_index_read_v1(
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
SET search_path=public,pg_temp
AS $fn$
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
END $fn$;

CREATE OR REPLACE FUNCTION public.marketroute_application_provenance_claim_index_v1(
  p_organisation_id uuid,
  p_campaign_id uuid,
  p_company_id uuid,
  p_at timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
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
END $fn$;


CREATE OR REPLACE FUNCTION public.marketroute_application_route_display_read_v1(
  p_organisation_id uuid,
  p_campaign_id uuid,
  p_company_id uuid,
  p_at timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
DECLARE
  v_env jsonb;
  v_r5 public.route_authority_r5_records%ROWTYPE;
  v_r6 public.contact_authority_r6_records%ROWTYPE;
  v_paths jsonb:='[]'::jsonb;
BEGIN
  PERFORM public.marketroute_require_service_role();
  PERFORM public.marketroute_application_require_current_read_time_v1(p_at);
  v_env:=public.marketroute_authority_envelope_v1(p_organisation_id,p_campaign_id,p_company_id,p_at);
  IF NULLIF(v_env->'r5'->>'authorityRecordId','') IS NOT NULL THEN
    SELECT * INTO v_r5 FROM public.route_authority_r5_records WHERE authority_record_id=(v_env->'r5'->>'authorityRecordId')::uuid;
  END IF;
  IF NULLIF(v_env->'r6'->>'authorityRecordId','') IS NOT NULL THEN
    SELECT * INTO v_r6 FROM public.contact_authority_r6_records WHERE authority_record_id=(v_env->'r6'->>'authorityRecordId')::uuid;
  END IF;
  IF v_r5.id IS NOT NULL THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'pathFingerprint',p.path->>'pathFingerprint','pathState',p.path->>'pathState','knowledgeState',p.path->>'knowledgeState',
      'terminalAccessPointId',p.path->>'terminalAccessPointId',
      'authorised',COALESCE(v_r6.authorised_path_fingerprints,'[]'::jsonb) ? (p.path->>'pathFingerprint'),
      'nodes',COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'nodeId',n.id,'kind',n.node_kind,
        'label',COALESCE(n.label,co.canonical_name,pe.display_name,n.canonical_value,n.stable_key),
        'meta',CASE n.node_kind WHEN 'COMPANY' THEN co.canonical_domain WHEN 'PERSON' THEN pe.canonical_name WHEN 'ACCESS_POINT' THEN n.access_point_kind ELSE n.node_kind END,
        'canonicalValue',n.canonical_value,'accessPointKind',n.access_point_kind
      ) ORDER BY ids.ordinality)
      FROM jsonb_array_elements_text(p.path->'nodeIds') WITH ORDINALITY ids(node_id,ordinality)
      JOIN public.commercial_graph_nodes n ON n.id=ids.node_id::uuid
      LEFT JOIN public.companies co ON co.id=n.company_id
      LEFT JOIN public.people pe ON pe.id=n.person_id),'[]'::jsonb)
    ) ORDER BY p.ordinality),'[]'::jsonb) INTO v_paths
    FROM jsonb_array_elements(v_r5.paths_json) WITH ORDINALITY p(path,ordinality);
  END IF;
  RETURN jsonb_build_object(
    'contractVersion','MRV2-APPLICATION-READ-1.0.0','resourceType','ROUTE_DISPLAY','evaluatedAt',to_jsonb(p_at),
    'organisationId',p_organisation_id,'campaignId',p_campaign_id,'companyId',p_company_id,
    'r5Decision',COALESCE(v_r5.decision_code,'NO_CURRENT_R5'),'r6Decision',COALESCE(v_r6.decision_code,'NO_CURRENT_R6'),'paths',v_paths
  );
END $fn$;

REVOKE ALL ON FUNCTION public.marketroute_application_company_index_read_v1(uuid,uuid,integer,integer,timestamptz) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_application_research_activity_read_v1(uuid,uuid,timestamptz) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_application_engagement_index_read_v1(uuid,uuid,integer,integer,timestamptz) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_application_provenance_claim_index_v1(uuid,uuid,uuid,timestamptz) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_application_route_display_read_v1(uuid,uuid,uuid,timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_application_company_index_read_v1(uuid,uuid,integer,integer,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_application_research_activity_read_v1(uuid,uuid,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_application_engagement_index_read_v1(uuid,uuid,integer,integer,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_application_provenance_claim_index_v1(uuid,uuid,uuid,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_application_route_display_read_v1(uuid,uuid,uuid,timestamptz) TO service_role;

INSERT INTO public.marketroute_schema_releases(release_key,build_number,constitution_version,metadata_json)
VALUES('MARKETROUTE_V2_BUILD15_CORE_APPLICATION_UI',15,'MRV2-CONSTITUTION-1.0.0',jsonb_build_object(
  'migration','0017_core_application_ui_read_indexes.sql','new_authority_writer',false,'read_only_extensions',true,
  'browser_direct_database_forbidden',true,'ui_derives_authority',false,'application_ui_live',true,'provenance_drawer_supported',true
)) ON CONFLICT(release_key) DO NOTHING;

NOTIFY pgrst,'reload schema';
COMMIT;
