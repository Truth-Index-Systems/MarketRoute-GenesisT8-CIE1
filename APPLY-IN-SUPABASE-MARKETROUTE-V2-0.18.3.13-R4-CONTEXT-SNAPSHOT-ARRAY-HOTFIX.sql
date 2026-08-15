BEGIN;

-- MarketRoute V2 R4 context snapshot-array hotfix 0.18.3.13.
-- R4 context claim collections contain enriched snapshot objects. Normalise
-- those server-generated objects to their snapshot UUIDs before applying the
-- existing authoritative Truth lookup and resolution semantics.

CREATE OR REPLACE FUNCTION public.marketroute_r4_truth_set_v1(p_snapshot_ids jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
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
$$;

REVOKE ALL ON FUNCTION public.marketroute_r4_truth_set_v1(jsonb) FROM PUBLIC, anon, authenticated;

INSERT INTO public.marketroute_schema_releases(
  release_key,
  build_number,
  constitution_version,
  metadata_json
)
VALUES(
  'MARKETROUTE_V2_R4_CONTEXT_SNAPSHOT_ARRAY_HOTFIX_0_18_3_13',
  18,
  'MRV2-CONSTITUTION-1.0.0',
  jsonb_build_object(
    'migration','0033_r4_context_snapshot_array_hotfix.sql',
    'new_authority_writer',false,
    'authority_semantics_unchanged',true,
    'context_snapshot_object_adapter',true,
    'authoritative_snapshot_lookup_preserved',true,
    'root_error','MARKETROUTE_R4_SNAPSHOT_ID_ARRAY_INVALID'
  )
)
ON CONFLICT(release_key) DO NOTHING;

NOTIFY pgrst,'reload schema';
COMMIT;
