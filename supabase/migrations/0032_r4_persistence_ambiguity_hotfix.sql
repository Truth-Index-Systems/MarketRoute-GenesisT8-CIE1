BEGIN;

-- MarketRoute V2 R4 persistence ambiguity hotfix 0.18.3.12.
-- The existing R4 writer is replaced without changing its authority semantics.
-- Its input-fingerprint deduplication lookup now qualifies every table column,
-- preventing the RETURNS TABLE output variable from shadowing the stored column.

CREATE OR REPLACE FUNCTION public.marketroute_persist_commercial_reality_r4_v1(
  p_organisation_id uuid,
  p_campaign_id uuid,
  p_company_id uuid,
  p_reference_time timestamptz,
  p_seller_context_selection_id uuid,
  p_target_truth_entity_snapshot_id uuid,
  p_constraint_truth_snapshot_map jsonb,
  p_engine_version text,
  p_semantics_version text,
  p_boundary_constitution_version text,
  p_reality_class text,
  p_decision_code text,
  p_boundaries_json jsonb,
  p_next_revalidation_at timestamptz
)
RETURNS TABLE(
  r4_record_id uuid,
  authority_record_id uuid,
  reasoning_run_id uuid,
  reasoning_artifact_id uuid,
  input_fingerprint text,
  authority_fingerprint text,
  valid_until timestamptz,
  deduplicated boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
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

REVOKE ALL ON FUNCTION public.marketroute_persist_commercial_reality_r4_v1(
  uuid,uuid,uuid,timestamptz,uuid,uuid,jsonb,text,text,text,text,text,jsonb,timestamptz
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_persist_commercial_reality_r4_v1(
  uuid,uuid,uuid,timestamptz,uuid,uuid,jsonb,text,text,text,text,text,jsonb,timestamptz
) TO service_role;

INSERT INTO public.marketroute_schema_releases(
  release_key,
  build_number,
  constitution_version,
  metadata_json
)
VALUES(
  'MARKETROUTE_V2_R4_PERSISTENCE_AMBIGUITY_HOTFIX_0_18_3_12',
  18,
  'MRV2-CONSTITUTION-1.0.0',
  jsonb_build_object(
    'migration','0032_r4_persistence_ambiguity_hotfix.sql',
    'new_authority_writer',false,
    'replaced_existing_authority_writer','marketroute.r4.commercial-reality',
    'authority_semantics_unchanged',true,
    'qualified_input_fingerprint_lookup',true,
    'failed_before_provider_cost',true
  )
)
ON CONFLICT(release_key) DO NOTHING;

NOTIFY pgrst,'reload schema';
COMMIT;

