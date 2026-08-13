BEGIN;

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

DO $writer_contract$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.authority_writer_registry
    WHERE writer_key='marketroute.r4.commercial-reality'
      AND authority_stage='COMMERCIAL_REALITY'
      AND writer_version='1.0.0'
      AND enabled=true
      AND registered_by_build=6
      AND metadata_json->>'engine_version'='MRV2-R4-1.0.0'
      AND metadata_json->>'semantics_version'='MRV2-R4-SEM-1.0.0'
  ) THEN RAISE EXCEPTION 'MARKETROUTE_R4_WRITER_REGISTRY_COLLISION'; END IF;
END;
$writer_contract$;

CREATE TABLE public.commercial_reality_boundary_constitutions (
  constitution_key text PRIMARY KEY,
  constitution_version text NOT NULL,
  reality_class text NOT NULL,
  mandatory_boundary_keys jsonb NOT NULL CHECK (jsonb_typeof(mandatory_boundary_keys) = 'array'),
  max_authority_hours integer NOT NULL CHECK (max_authority_hours BETWEEN 1 AND 168),
  accepted_truth_states jsonb NOT NULL CHECK (jsonb_typeof(accepted_truth_states) = 'array'),
  active boolean NOT NULL DEFAULT true,
  metadata_json jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata_json) = 'object'),
  registered_at timestamptz NOT NULL DEFAULT now()
);

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

CREATE TABLE public.commercial_reality_r4_records (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organisation_id uuid NOT NULL REFERENCES public.organisations(id) ON DELETE RESTRICT,
  campaign_id uuid NOT NULL,
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  authority_record_id uuid NOT NULL UNIQUE REFERENCES public.authority_records(id) ON DELETE RESTRICT,
  seller_context_selection_id uuid NOT NULL REFERENCES public.campaign_seller_context_selections(id) ON DELETE RESTRICT,
  target_truth_entity_snapshot_id uuid NOT NULL REFERENCES public.truth_entity_snapshots(id) ON DELETE RESTRICT,
  constraint_truth_snapshot_map jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(constraint_truth_snapshot_map) = 'object'),
  boundary_constitution_key text NOT NULL REFERENCES public.commercial_reality_boundary_constitutions(constitution_key) ON DELETE RESTRICT,
  boundary_constitution_version text NOT NULL,
  reality_class text NOT NULL,
  engine_version text NOT NULL,
  semantics_version text NOT NULL,
  decision_code text NOT NULL CHECK (decision_code IN ('COMMERCIAL_CANDIDATE','RESEARCH_REQUIRED','NOT_ADMISSIBLE')),
  boundaries_json jsonb NOT NULL CHECK (jsonb_typeof(boundaries_json) = 'array'),
  input_fingerprint text NOT NULL CHECK (input_fingerprint ~ '^[a-f0-9]{64}$'),
  authority_fingerprint text NOT NULL CHECK (authority_fingerprint ~ '^[a-f0-9]{64}$'),
  reference_time timestamptz NOT NULL,
  next_revalidation_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organisation_id, campaign_id, company_id, input_fingerprint),
  CONSTRAINT commercial_reality_r4_campaign_scope_fk
    FOREIGN KEY (organisation_id, campaign_id)
    REFERENCES public.campaigns(organisation_id, id)
    ON DELETE RESTRICT,
  CHECK (next_revalidation_at > reference_time)
);

CREATE INDEX commercial_reality_r4_scope_idx
ON public.commercial_reality_r4_records(organisation_id, campaign_id, company_id, created_at DESC);

CREATE TRIGGER commercial_reality_r4_records_append_only
BEFORE UPDATE OR DELETE ON public.commercial_reality_r4_records
FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

CREATE OR REPLACE FUNCTION public.marketroute_r4_iso_v1(p_value timestamptz)
RETURNS text
LANGUAGE sql
IMMUTABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT CASE WHEN p_value IS NULL THEN NULL ELSE to_char(p_value AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"') END;
$$;

CREATE OR REPLACE FUNCTION public.marketroute_r4_scalar_value_v1(
  p_canonical_value_text text,
  p_object_json jsonb
)
RETURNS text
LANGUAGE sql
IMMUTABLE
SECURITY DEFINER
SET search_path = public, pg_temp
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

CREATE OR REPLACE FUNCTION public.marketroute_r4_hard_constraint_claim_key_v1(p_constraint_type text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SECURITY DEFINER
SET search_path = public, pg_temp
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

CREATE OR REPLACE FUNCTION public.marketroute_get_r4_target_claim_ids_v1(
  p_organisation_id uuid,
  p_company_id uuid,
  p_claim_keys jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
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

CREATE OR REPLACE FUNCTION public.marketroute_get_r4_context_v1(
  p_organisation_id uuid,
  p_campaign_id uuid,
  p_company_id uuid,
  p_reference_time timestamptz,
  p_seller_context_selection_id uuid,
  p_target_truth_entity_snapshot_id uuid,
  p_constraint_truth_snapshot_map jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
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

CREATE OR REPLACE FUNCTION public.marketroute_r4_expected_v1(p_context jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
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

  SELECT * INTO v_existing FROM public.commercial_reality_r4_records
  WHERE organisation_id=p_organisation_id AND campaign_id=p_campaign_id AND company_id=p_company_id AND input_fingerprint=v_input_fingerprint;
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

CREATE OR REPLACE FUNCTION public.marketroute_r4_authority_current_v1(
  p_authority_record_id uuid,
  p_at timestamptz DEFAULT now()
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
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

CREATE OR REPLACE VIEW public.current_commercial_reality_r4 AS
SELECT r.*, a.valid_from, a.valid_until, a.payload_json AS authority_payload_json
FROM public.commercial_reality_r4_records r
JOIN public.authority_records a ON a.id=r.authority_record_id
WHERE public.marketroute_r4_authority_current_v1(a.id, now());

ALTER TABLE public.commercial_reality_boundary_constitutions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.commercial_reality_r4_records ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.commercial_reality_boundary_constitutions FROM anon,authenticated,service_role;
REVOKE ALL ON public.commercial_reality_r4_records FROM anon,authenticated,service_role;
REVOKE ALL ON public.current_commercial_reality_r4 FROM anon,authenticated,service_role;
GRANT SELECT ON public.commercial_reality_boundary_constitutions TO service_role;
GRANT SELECT ON public.commercial_reality_r4_records TO service_role;
GRANT SELECT ON public.current_commercial_reality_r4 TO service_role;

REVOKE ALL ON FUNCTION public.marketroute_r4_iso_v1(timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_r4_scalar_value_v1(text,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_r4_truth_set_v1(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_r4_hard_constraint_claim_key_v1(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_get_r4_target_claim_ids_v1(uuid,uuid,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_get_r4_context_v1(uuid,uuid,uuid,timestamptz,uuid,uuid,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_r4_expected_v1(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_persist_commercial_reality_r4_v1(uuid,uuid,uuid,timestamptz,uuid,uuid,jsonb,text,text,text,text,text,jsonb,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_r4_authority_current_v1(uuid,timestamptz) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.marketroute_get_r4_target_claim_ids_v1(uuid,uuid,jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_get_r4_context_v1(uuid,uuid,uuid,timestamptz,uuid,uuid,jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_persist_commercial_reality_r4_v1(uuid,uuid,uuid,timestamptz,uuid,uuid,jsonb,text,text,text,text,text,jsonb,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_r4_authority_current_v1(uuid,timestamptz) TO service_role;

INSERT INTO public.marketroute_schema_releases(release_key,build_number,constitution_version,metadata_json)
VALUES('MARKETROUTE_V2_BUILD6_R4',6,'MRV2-CONSTITUTION-1.0.0',jsonb_build_object(
  'migration','0009_commercial_reality_r4.sql',
  'authority_writers',1,
  'authority_writer','marketroute.r4.commercial-reality',
  'continuous_commercial_thresholds',false,
  'database_recomputes_authority_fingerprint',true
))
ON CONFLICT (release_key) DO NOTHING;

NOTIFY pgrst, 'reload schema';
COMMIT;
