BEGIN;

-- MarketRoute V2 production hotfix 0.18.3.3
-- Fixes PostgreSQL output-column ambiguity in final entity Truth persistence.
-- The RETURNS TABLE output name `input_fingerprint` previously collided with
-- truth_entity_snapshots.input_fingerprint in the idempotency lookup.
-- This patch aliases the table and qualifies every lookup column without
-- changing Truth semantics, evidence, authority, or append-only protections.

CREATE OR REPLACE FUNCTION public.marketroute_persist_entity_truth_v1(
  p_tenant_scope_organisation_id uuid,
  p_subject_type text,
  p_subject_id uuid,
  p_profile_key text,
  p_reference_time timestamptz,
  p_claim_snapshot_map jsonb,
  p_aggregation_version text,
  p_semantics_version text,
  p_entity_state text,
  p_required_claim_count integer,
  p_known_claim_count integer,
  p_supported_claim_count integer,
  p_contradicted_claim_count integer,
  p_stale_claim_count integer,
  p_unresolved_claim_count integer,
  p_coverage numeric,
  p_current_coverage numeric,
  p_evidence_sufficiency numeric,
  p_freshness_coverage numeric,
  p_coherence numeric,
  p_truth_index numeric,
  p_truth_probability numeric,
  p_probability_state text,
  p_next_revalidation_at timestamptz,
  p_payload_json jsonb
)
RETURNS TABLE(
  snapshot_id uuid,
  reasoning_run_id uuid,
  reasoning_artifact_id uuid,
  input_fingerprint text,
  snapshot_fingerprint text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
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

REVOKE ALL ON FUNCTION public.marketroute_persist_entity_truth_v1(uuid,text,uuid,text,timestamptz,jsonb,text,text,text,integer,integer,integer,integer,integer,integer,numeric,numeric,numeric,numeric,numeric,numeric,numeric,text,timestamptz,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_persist_entity_truth_v1(uuid,text,uuid,text,timestamptz,jsonb,text,text,text,integer,integer,integer,integer,integer,integer,numeric,numeric,numeric,numeric,numeric,numeric,numeric,text,timestamptz,jsonb) TO service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
