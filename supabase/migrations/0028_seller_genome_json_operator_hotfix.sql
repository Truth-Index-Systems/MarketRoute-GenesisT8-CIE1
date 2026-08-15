BEGIN;

-- MarketRoute V2 seller-genome JSON operator hotfix 0.18.3.8.
--
-- PostgreSQL gives the subtraction operator higher binding precedence than the
-- JSON extraction expression in "jsonb->key - text[]". Without parentheses it
-- attempts to coerce the key name (for example "offerings") to jsonb and raises
-- SQLSTATE 22P02: invalid input syntax for type json.
--
-- Replacing the existing validator is safe for already-migrated databases:
-- its signature, security model and validation policy are unchanged. Only the
-- eight dimension-level exact-key expressions are disambiguated.

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
$$;

REVOKE ALL ON FUNCTION public.marketroute_seller_genome_validate_v1(uuid,jsonb)
FROM PUBLIC, anon, authenticated, service_role;

INSERT INTO public.marketroute_schema_releases(
  release_key,
  build_number,
  constitution_version,
  metadata_json
)
VALUES(
  'MARKETROUTE_V2_SELLER_GENOME_JSON_OPERATOR_HOTFIX_0_18_3_8',
  18,
  'MRV2-CONSTITUTION-1.0.0',
  jsonb_build_object(
    'migration','0028_seller_genome_json_operator_hotfix.sql',
    'new_authority_writer',false,
    'seller_genome_validator_operator_fix',true,
    'sqlstate_fixed','22P02'
  )
)
ON CONFLICT(release_key) DO NOTHING;

NOTIFY pgrst,'reload schema';
COMMIT;

