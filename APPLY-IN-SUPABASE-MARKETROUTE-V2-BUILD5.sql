BEGIN;

CREATE TABLE public.seller_genome_source_materials (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organisation_id uuid NOT NULL REFERENCES public.organisations(id) ON DELETE RESTRICT,
  seller_business_id uuid NOT NULL,
  material_kind text NOT NULL CHECK (material_kind IN ('USER_DECLARED','WEBSITE_ANALYSIS','IMPORT','COMPOSITE')),
  material_version text NOT NULL DEFAULT 'MRV2-SELLER-SOURCE-1.0.0',
  content_json jsonb NOT NULL CHECK (jsonb_typeof(content_json) IN ('object','array','string')),
  material_fingerprint text NOT NULL UNIQUE CHECK (material_fingerprint ~ '^[a-f0-9]{64}$'),
  created_by_user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT seller_genome_source_materials_scope_fk
    FOREIGN KEY (organisation_id, seller_business_id)
    REFERENCES public.seller_businesses(organisation_id, id)
    ON DELETE RESTRICT
);

CREATE INDEX seller_genome_source_materials_seller_idx
ON public.seller_genome_source_materials(organisation_id, seller_business_id, created_at DESC);

CREATE TABLE public.seller_commercial_genome_snapshots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organisation_id uuid NOT NULL REFERENCES public.organisations(id) ON DELETE RESTRICT,
  seller_business_id uuid NOT NULL,
  source_material_id uuid NOT NULL REFERENCES public.seller_genome_source_materials(id) ON DELETE RESTRICT,
  schema_version text NOT NULL CHECK (schema_version = 'MRV2-SELLER-GENOME-1.0.0'),
  canonicalisation_version text NOT NULL CHECK (canonicalisation_version = 'MRV2-SELLER-CANON-1.0.0'),
  extraction_contract_version text NOT NULL CHECK (extraction_contract_version = 'MRV2-SELLER-EXTRACT-1.0.0'),
  extractor_version text NOT NULL CHECK (length(btrim(extractor_version)) BETWEEN 1 AND 160),
  canonical_genome_json jsonb NOT NULL CHECK (jsonb_typeof(canonical_genome_json) = 'object'),
  content_fingerprint text NOT NULL UNIQUE CHECK (content_fingerprint ~ '^[a-f0-9]{64}$'),
  semantic_fingerprint text NOT NULL CHECK (semantic_fingerprint ~ '^[a-f0-9]{64}$'),
  semantic_completeness text NOT NULL CHECK (semantic_completeness IN ('COMPLETE','PARTIAL')),
  missing_dimensions text[] NOT NULL DEFAULT '{}',
  explicit_unknown_count integer NOT NULL CHECK (explicit_unknown_count >= 0),
  offering_count integer NOT NULL CHECK (offering_count >= 0),
  objective_count integer NOT NULL CHECK (objective_count >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organisation_id, seller_business_id, id),
  CONSTRAINT seller_genome_snapshots_scope_fk
    FOREIGN KEY (organisation_id, seller_business_id)
    REFERENCES public.seller_businesses(organisation_id, id)
    ON DELETE RESTRICT
);

CREATE INDEX seller_commercial_genome_snapshots_semantic_idx
ON public.seller_commercial_genome_snapshots(organisation_id, seller_business_id, semantic_fingerprint, created_at DESC);

CREATE TABLE public.campaign_seller_context_selections (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organisation_id uuid NOT NULL,
  campaign_id uuid NOT NULL,
  seller_business_id uuid NOT NULL,
  genome_snapshot_id uuid NOT NULL,
  objective_key text NOT NULL CHECK (objective_key ~ '^[a-z0-9][a-z0-9._-]{0,79}$'),
  selection_request_id uuid NOT NULL UNIQUE,
  input_fingerprint text NOT NULL CHECK (input_fingerprint ~ '^[a-f0-9]{64}$'),
  semantic_context_fingerprint text NOT NULL CHECK (semantic_context_fingerprint ~ '^[a-f0-9]{64}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT campaign_seller_context_campaign_scope_fk
    FOREIGN KEY (organisation_id, campaign_id)
    REFERENCES public.campaigns(organisation_id, id)
    ON DELETE RESTRICT,
  CONSTRAINT campaign_seller_context_seller_scope_fk
    FOREIGN KEY (organisation_id, seller_business_id)
    REFERENCES public.seller_businesses(organisation_id, id)
    ON DELETE RESTRICT,
  CONSTRAINT campaign_seller_context_genome_scope_fk
    FOREIGN KEY (organisation_id, seller_business_id, genome_snapshot_id)
    REFERENCES public.seller_commercial_genome_snapshots(organisation_id, seller_business_id, id)
    ON DELETE RESTRICT
);

CREATE INDEX campaign_seller_context_latest_idx
ON public.campaign_seller_context_selections(organisation_id, campaign_id, created_at DESC, id DESC);

CREATE TRIGGER seller_genome_source_materials_append_only
BEFORE UPDATE OR DELETE ON public.seller_genome_source_materials
FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

CREATE TRIGGER seller_commercial_genome_snapshots_append_only
BEFORE UPDATE OR DELETE ON public.seller_commercial_genome_snapshots
FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

CREATE TRIGGER campaign_seller_context_selections_append_only
BEFORE UPDATE OR DELETE ON public.campaign_seller_context_selections
FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

CREATE OR REPLACE FUNCTION public.marketroute_jsonb_text_array_is_set_v1(
  p_value jsonb,
  p_pattern text
)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SECURITY DEFINER
SET search_path = public, pg_temp
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

CREATE OR REPLACE FUNCTION public.marketroute_sort_jsonb_text_array_v1(p_value jsonb)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT COALESCE(jsonb_agg(value ORDER BY value), '[]'::jsonb)
  FROM jsonb_array_elements_text(p_value) value;
$$;

CREATE OR REPLACE FUNCTION public.marketroute_seller_genome_semantic_identity_v1(p_genome jsonb)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
SECURITY DEFINER
SET search_path = public, pg_temp
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

CREATE OR REPLACE FUNCTION public.marketroute_seller_genome_validate_v1(
  p_seller_business_id uuid,
  p_genome jsonb
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp, extensions
AS $$
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

  IF (v_semantic->'offerings' - ARRAY['state','items']) <> '{}'::jsonb OR NOT (v_semantic->'offerings' ?& ARRAY['state','items']) THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_OFFERING_DIMENSION_KEYS_INVALID'; END IF;
  IF (v_semantic->'capabilities' - ARRAY['state','items']) <> '{}'::jsonb OR NOT (v_semantic->'capabilities' ?& ARRAY['state','items']) THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_CAPABILITY_DIMENSION_KEYS_INVALID'; END IF;
  IF (v_semantic->'commercialObjectives' - ARRAY['state','items']) <> '{}'::jsonb OR NOT (v_semantic->'commercialObjectives' ?& ARRAY['state','items']) THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_OBJECTIVE_DIMENSION_KEYS_INVALID'; END IF;
  IF (v_semantic->'constraints' - ARRAY['state','items']) <> '{}'::jsonb OR NOT (v_semantic->'constraints' ?& ARRAY['state','items']) THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_CONSTRAINT_DIMENSION_KEYS_INVALID'; END IF;
  IF (v_semantic->'delivery' - ARRAY['state','modeCodes']) <> '{}'::jsonb OR NOT (v_semantic->'delivery' ?& ARRAY['state','modeCodes']) THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_DELIVERY_KEYS_INVALID'; END IF;
  IF (v_semantic->'serviceGeography' - ARRAY['state','countryCodes','regionCodes']) <> '{}'::jsonb OR NOT (v_semantic->'serviceGeography' ?& ARRAY['state','countryCodes','regionCodes']) THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_GEOGRAPHY_KEYS_INVALID'; END IF;
  IF (v_semantic->'targetCharacteristics' - ARRAY['state','industryCodes','companySizeBands','businessModelCodes']) <> '{}'::jsonb OR NOT (v_semantic->'targetCharacteristics' ?& ARRAY['state','industryCodes','companySizeBands','businessModelCodes']) THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_TARGET_KEYS_INVALID'; END IF;
  IF (v_semantic->'buyerAssumptions' - ARRAY['state','roleCodes','departmentCodes','painCodes']) <> '{}'::jsonb OR NOT (v_semantic->'buyerAssumptions' ?& ARRAY['state','roleCodes','departmentCodes','painCodes']) THEN RAISE EXCEPTION 'MARKETROUTE_SELLER_GENOME_BUYER_KEYS_INVALID'; END IF;

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
$$;

CREATE OR REPLACE FUNCTION public.marketroute_record_seller_genome_source_v1(
  p_organisation_id uuid,
  p_seller_business_id uuid,
  p_material_kind text,
  p_content_json jsonb,
  p_created_by_user_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp, extensions
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

CREATE OR REPLACE FUNCTION public.marketroute_persist_seller_genome_v1(
  p_organisation_id uuid,
  p_seller_business_id uuid,
  p_source_material_id uuid,
  p_schema_version text,
  p_canonicalisation_version text,
  p_extraction_contract_version text,
  p_extractor_version text,
  p_canonical_genome_json jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp, extensions
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

CREATE OR REPLACE FUNCTION public.marketroute_select_campaign_seller_context_v1(
  p_organisation_id uuid,
  p_campaign_id uuid,
  p_genome_snapshot_id uuid,
  p_objective_key text,
  p_request_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp, extensions
AS $$
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
$$;

CREATE OR REPLACE FUNCTION public.marketroute_get_current_campaign_seller_context_v1(
  p_organisation_id uuid,
  p_campaign_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
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

ALTER TABLE public.seller_genome_source_materials ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.seller_commercial_genome_snapshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.campaign_seller_context_selections ENABLE ROW LEVEL SECURITY;

CREATE POLICY seller_genome_source_materials_member_select ON public.seller_genome_source_materials
FOR SELECT TO authenticated USING (public.marketroute_is_org_member(organisation_id));
CREATE POLICY seller_genome_snapshots_member_select ON public.seller_commercial_genome_snapshots
FOR SELECT TO authenticated USING (public.marketroute_is_org_member(organisation_id));
CREATE POLICY campaign_seller_context_member_select ON public.campaign_seller_context_selections
FOR SELECT TO authenticated USING (public.marketroute_is_org_member(organisation_id));

REVOKE ALL ON public.seller_genome_source_materials FROM anon, authenticated, service_role;
REVOKE ALL ON public.seller_commercial_genome_snapshots FROM anon, authenticated, service_role;
REVOKE ALL ON public.campaign_seller_context_selections FROM anon, authenticated, service_role;
GRANT SELECT ON public.seller_genome_source_materials TO authenticated, service_role;
GRANT SELECT ON public.seller_commercial_genome_snapshots TO authenticated, service_role;
GRANT SELECT ON public.campaign_seller_context_selections TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.marketroute_jsonb_text_array_is_set_v1(jsonb,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_sort_jsonb_text_array_v1(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_seller_genome_semantic_identity_v1(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_seller_genome_validate_v1(uuid,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_record_seller_genome_source_v1(uuid,uuid,text,jsonb,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_persist_seller_genome_v1(uuid,uuid,uuid,text,text,text,text,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_select_campaign_seller_context_v1(uuid,uuid,uuid,text,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_get_current_campaign_seller_context_v1(uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.marketroute_record_seller_genome_source_v1(uuid,uuid,text,jsonb,uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_persist_seller_genome_v1(uuid,uuid,uuid,text,text,text,text,jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_select_campaign_seller_context_v1(uuid,uuid,uuid,text,uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_get_current_campaign_seller_context_v1(uuid,uuid) TO service_role;

INSERT INTO public.marketroute_schema_releases(release_key, build_number, constitution_version, metadata_json)
VALUES (
  'MRV2-BUILD5-SELLER-COMMERCIAL-GENOME',
  5,
  'MRV2-CONSTITUTION-1.0.0',
  jsonb_build_object(
    'authority_writers', 0,
    'seller_genome_schema', 'MRV2-SELLER-GENOME-1.0.0',
    'semantic_prose_separation', true,
    'database_recomputed_semantic_fingerprint', true,
    'campaign_objective_binding', true,
    'commercial_authority', false
  )
);

NOTIFY pgrst, 'reload schema';
COMMIT;
