BEGIN;

ALTER TABLE public.source_records
  ADD COLUMN source_identity_fingerprint text,
  ADD COLUMN stable_locator text,
  ADD COLUMN dependence_family_key text,
  ADD COLUMN normalisation_version text;

UPDATE public.source_records
SET source_identity_fingerprint = encode(extensions.digest('MRV2-BUILD3-SOURCE-BACKFILL:' || id::text, 'sha256'), 'hex'),
    stable_locator = COALESCE(canonical_url, 'prebuild3-source:' || id::text),
    dependence_family_key = 'MRV2-DEPENDENCE-BACKFILL:' || encode(extensions.digest('MRV2-BUILD3-FAMILY-BACKFILL:' || id::text, 'sha256'), 'hex'),
    normalisation_version = 'MRV2-EVIDENCE-NORM-PREBUILD3'
WHERE source_identity_fingerprint IS NULL;

ALTER TABLE public.source_records
  ALTER COLUMN source_identity_fingerprint SET NOT NULL,
  ALTER COLUMN stable_locator SET NOT NULL,
  ALTER COLUMN dependence_family_key SET NOT NULL,
  ALTER COLUMN normalisation_version SET NOT NULL,
  ADD CONSTRAINT source_records_identity_fingerprint_shape CHECK (source_identity_fingerprint ~ '^[a-f0-9]{64}$'),
  ADD CONSTRAINT source_records_dependence_family_nonempty CHECK (length(btrim(dependence_family_key)) > 0),
  ADD CONSTRAINT source_records_normalisation_version_nonempty CHECK (length(btrim(normalisation_version)) > 0);

CREATE UNIQUE INDEX source_records_identity_fingerprint_unique
ON public.source_records(source_identity_fingerprint);

ALTER TABLE public.source_acquisitions
  ADD CONSTRAINT source_acquisitions_observed_content_fingerprint_shape
  CHECK (observed_content_fingerprint IS NULL OR observed_content_fingerprint ~ '^[a-f0-9]{64}$');

ALTER TABLE public.evidence_items
  ADD COLUMN source_identity_fingerprint text,
  ADD COLUMN dependence_family_key text,
  ADD COLUMN fingerprint_version text;

UPDATE public.evidence_items e
SET source_identity_fingerprint = s.source_identity_fingerprint,
    dependence_family_key = s.dependence_family_key,
    fingerprint_version = 'MRV2-EVIDENCE-FP-PREBUILD3'
FROM public.source_acquisitions a
JOIN public.source_records s ON s.id = a.source_id
WHERE a.id = e.acquisition_id
  AND e.source_identity_fingerprint IS NULL;

ALTER TABLE public.evidence_items
  ALTER COLUMN source_identity_fingerprint SET NOT NULL,
  ALTER COLUMN dependence_family_key SET NOT NULL,
  ALTER COLUMN fingerprint_version SET NOT NULL,
  ADD CONSTRAINT evidence_items_source_identity_fingerprint_shape CHECK (source_identity_fingerprint ~ '^[a-f0-9]{64}$'),
  ADD CONSTRAINT evidence_items_dependence_family_nonempty CHECK (length(btrim(dependence_family_key)) > 0),
  ADD CONSTRAINT evidence_items_fingerprint_version_nonempty CHECK (length(btrim(fingerprint_version)) > 0);

ALTER TABLE public.claims
  ADD COLUMN fingerprint_version text;

UPDATE public.claims
SET fingerprint_version = 'MRV2-CLAIM-FP-PREBUILD3'
WHERE fingerprint_version IS NULL;

ALTER TABLE public.claims
  ALTER COLUMN fingerprint_version SET NOT NULL,
  ADD CONSTRAINT claims_fingerprint_version_nonempty CHECK (length(btrim(fingerprint_version)) > 0);

ALTER TABLE public.claim_evidence_links DISABLE TRIGGER claim_evidence_links_append_only;
UPDATE public.claim_evidence_links l
SET dependence_family_key = e.dependence_family_key
FROM public.evidence_items e
WHERE e.id = l.evidence_item_id
  AND l.dependence_family_key IS DISTINCT FROM e.dependence_family_key;
ALTER TABLE public.claim_evidence_links ENABLE TRIGGER claim_evidence_links_append_only;

CREATE UNIQUE INDEX claim_evidence_links_single_polarity_unique
ON public.claim_evidence_links(claim_id, evidence_item_id);

CREATE OR REPLACE FUNCTION public.marketroute_require_service_role()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_role text := COALESCE(auth.role()::text, current_setting('request.jwt.claim.role', true));
BEGIN
  IF v_role IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'MARKETROUTE_SERVICE_ROLE_REQUIRED';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.marketroute_protect_source_identity()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.source_kind IS DISTINCT FROM OLD.source_kind
     OR NEW.canonical_url IS DISTINCT FROM OLD.canonical_url
     OR NEW.publisher_domain IS DISTINCT FROM OLD.publisher_domain
     OR NEW.source_identity_fingerprint IS DISTINCT FROM OLD.source_identity_fingerprint
     OR NEW.stable_locator IS DISTINCT FROM OLD.stable_locator
     OR NEW.dependence_family_key IS DISTINCT FROM OLD.dependence_family_key
     OR NEW.normalisation_version IS DISTINCT FROM OLD.normalisation_version THEN
    RAISE EXCEPTION 'MARKETROUTE_SOURCE_IDENTITY_IMMUTABLE';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER source_records_identity_immutable
BEFORE UPDATE ON public.source_records
FOR EACH ROW EXECUTE FUNCTION public.marketroute_protect_source_identity();

CREATE OR REPLACE FUNCTION public.marketroute_validate_claim_evidence_scope()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_claim_org uuid;
  v_claim_subject_type text;
  v_claim_subject_id uuid;
  v_evidence_org uuid;
  v_evidence_subject_type text;
  v_evidence_subject_id uuid;
  v_dependence_family_key text;
BEGIN
  SELECT tenant_scope_organisation_id, subject_type, subject_id
  INTO v_claim_org, v_claim_subject_type, v_claim_subject_id
  FROM public.claims WHERE id = NEW.claim_id;

  SELECT tenant_scope_organisation_id, subject_type, subject_id, dependence_family_key
  INTO v_evidence_org, v_evidence_subject_type, v_evidence_subject_id, v_dependence_family_key
  FROM public.evidence_items
  WHERE id = NEW.evidence_item_id;

  IF v_claim_subject_type IS DISTINCT FROM v_evidence_subject_type
     OR v_claim_subject_id IS DISTINCT FROM v_evidence_subject_id THEN
    RAISE EXCEPTION 'MARKETROUTE_CLAIM_EVIDENCE_SUBJECT_MISMATCH';
  END IF;
  IF v_claim_org IS NULL AND v_evidence_org IS NOT NULL THEN
    RAISE EXCEPTION 'MARKETROUTE_GLOBAL_CLAIM_CANNOT_USE_PRIVATE_EVIDENCE';
  END IF;
  IF v_claim_org IS NOT NULL AND v_evidence_org IS NOT NULL AND v_claim_org <> v_evidence_org THEN
    RAISE EXCEPTION 'MARKETROUTE_CLAIM_EVIDENCE_TENANT_MISMATCH';
  END IF;
  IF NEW.dependence_family_key IS DISTINCT FROM v_dependence_family_key THEN
    RAISE EXCEPTION 'MARKETROUTE_DEPENDENCE_FAMILY_MUST_INHERIT_EVIDENCE';
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.marketroute_ingest_evidence_v1(
  p_source_kind text,
  p_canonical_url text,
  p_publisher_domain text,
  p_title text,
  p_source_published_at timestamptz,
  p_stable_locator text,
  p_source_identity_fingerprint text,
  p_dependence_family_key text,
  p_normalisation_version text,
  p_source_metadata_json jsonb,
  p_acquired_at timestamptz,
  p_acquisition_method text,
  p_observed_content_fingerprint text,
  p_http_status integer,
  p_raw_locator text,
  p_parser_version text,
  p_request_id text,
  p_acquisition_metadata_json jsonb,
  p_tenant_scope_organisation_id uuid,
  p_subject_type text,
  p_subject_id uuid,
  p_evidence_kind text,
  p_excerpt_text text,
  p_structured_value_json jsonb,
  p_observed_at timestamptz,
  p_origin_published_at timestamptz,
  p_extraction_method text,
  p_extraction_version text,
  p_evidence_fingerprint text,
  p_fingerprint_version text
)
RETURNS TABLE(
  source_id uuid,
  acquisition_id uuid,
  evidence_item_id uuid,
  source_created boolean,
  evidence_created boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_source_id uuid;
  v_acquisition_id uuid;
  v_evidence_id uuid;
  v_source_created boolean := false;
  v_evidence_created boolean := false;
  v_existing public.source_records%ROWTYPE;
  v_evidence public.evidence_items%ROWTYPE;
BEGIN
  PERFORM public.marketroute_require_service_role();

  IF p_source_identity_fingerprint !~ '^[a-f0-9]{64}$' THEN RAISE EXCEPTION 'MARKETROUTE_INVALID_SOURCE_IDENTITY_FINGERPRINT'; END IF;
  IF p_evidence_fingerprint !~ '^[a-f0-9]{64}$' THEN RAISE EXCEPTION 'MARKETROUTE_INVALID_EVIDENCE_FINGERPRINT'; END IF;
  IF p_observed_content_fingerprint IS NOT NULL AND p_observed_content_fingerprint !~ '^[a-f0-9]{64}$' THEN RAISE EXCEPTION 'MARKETROUTE_INVALID_CONTENT_FINGERPRINT'; END IF;
  IF length(btrim(COALESCE(p_dependence_family_key, ''))) = 0 THEN RAISE EXCEPTION 'MARKETROUTE_DEPENDENCE_FAMILY_REQUIRED'; END IF;
  IF length(btrim(COALESCE(p_stable_locator, ''))) = 0 THEN RAISE EXCEPTION 'MARKETROUTE_STABLE_LOCATOR_REQUIRED'; END IF;
  IF length(btrim(COALESCE(p_normalisation_version, ''))) = 0 OR length(btrim(COALESCE(p_fingerprint_version, ''))) = 0 THEN
    RAISE EXCEPTION 'MARKETROUTE_EVIDENCE_VERSION_REQUIRED';
  END IF;
  IF p_excerpt_text IS NULL AND p_structured_value_json IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_EVIDENCE_CONTENT_REQUIRED'; END IF;

  INSERT INTO public.source_records(
    source_kind, canonical_url, publisher_domain, title, published_at,
    first_observed_at, last_observed_at, metadata_json,
    source_identity_fingerprint, stable_locator, dependence_family_key, normalisation_version
  ) VALUES (
    p_source_kind, p_canonical_url, p_publisher_domain, p_title, p_source_published_at,
    COALESCE(p_acquired_at, now()), COALESCE(p_acquired_at, now()), COALESCE(p_source_metadata_json, '{}'::jsonb),
    p_source_identity_fingerprint, p_stable_locator, p_dependence_family_key, p_normalisation_version
  )
  ON CONFLICT (source_identity_fingerprint) DO NOTHING
  RETURNING id INTO v_source_id;

  IF v_source_id IS NOT NULL THEN
    v_source_created := true;
  ELSE
    SELECT * INTO v_existing
    FROM public.source_records
    WHERE source_identity_fingerprint = p_source_identity_fingerprint
    FOR UPDATE;
    v_source_id := v_existing.id;

    IF v_existing.source_kind IS DISTINCT FROM p_source_kind
       OR v_existing.canonical_url IS DISTINCT FROM p_canonical_url
       OR v_existing.publisher_domain IS DISTINCT FROM p_publisher_domain
       OR v_existing.stable_locator IS DISTINCT FROM p_stable_locator
       OR v_existing.dependence_family_key IS DISTINCT FROM p_dependence_family_key
       OR v_existing.normalisation_version IS DISTINCT FROM p_normalisation_version THEN
      RAISE EXCEPTION 'MARKETROUTE_SOURCE_FINGERPRINT_COLLISION';
    END IF;

    UPDATE public.source_records
    SET last_observed_at = GREATEST(last_observed_at, COALESCE(p_acquired_at, now())),
        title = COALESCE(title, p_title),
        published_at = COALESCE(published_at, p_source_published_at),
        metadata_json = metadata_json || COALESCE(p_source_metadata_json, '{}'::jsonb)
    WHERE id = v_source_id;
  END IF;

  INSERT INTO public.source_acquisitions(
    source_id, acquired_at, acquisition_method, observed_content_fingerprint,
    http_status, raw_locator, parser_version, request_id, metadata_json
  ) VALUES (
    v_source_id, COALESCE(p_acquired_at, now()), p_acquisition_method, p_observed_content_fingerprint,
    p_http_status, p_raw_locator, p_parser_version, p_request_id, COALESCE(p_acquisition_metadata_json, '{}'::jsonb)
  ) RETURNING id INTO v_acquisition_id;

  INSERT INTO public.evidence_items(
    acquisition_id, tenant_scope_organisation_id, subject_type, subject_id,
    evidence_kind, excerpt_text, structured_value_json, observed_at, origin_published_at,
    extraction_method, extraction_version, evidence_fingerprint,
    source_identity_fingerprint, dependence_family_key, fingerprint_version
  ) VALUES (
    v_acquisition_id, p_tenant_scope_organisation_id, p_subject_type, p_subject_id,
    p_evidence_kind, p_excerpt_text, p_structured_value_json, COALESCE(p_observed_at, now()), p_origin_published_at,
    p_extraction_method, p_extraction_version, p_evidence_fingerprint,
    p_source_identity_fingerprint, p_dependence_family_key, p_fingerprint_version
  )
  ON CONFLICT (evidence_fingerprint) DO NOTHING
  RETURNING id INTO v_evidence_id;

  IF v_evidence_id IS NOT NULL THEN
    v_evidence_created := true;
  ELSE
    SELECT * INTO v_evidence
    FROM public.evidence_items
    WHERE evidence_fingerprint = p_evidence_fingerprint;
    v_evidence_id := v_evidence.id;

    IF v_evidence.source_identity_fingerprint IS DISTINCT FROM p_source_identity_fingerprint
       OR v_evidence.dependence_family_key IS DISTINCT FROM p_dependence_family_key
       OR v_evidence.tenant_scope_organisation_id IS DISTINCT FROM p_tenant_scope_organisation_id
       OR v_evidence.subject_type IS DISTINCT FROM p_subject_type
       OR v_evidence.subject_id IS DISTINCT FROM p_subject_id
       OR v_evidence.evidence_kind IS DISTINCT FROM p_evidence_kind
       OR v_evidence.excerpt_text IS DISTINCT FROM p_excerpt_text
       OR v_evidence.structured_value_json IS DISTINCT FROM p_structured_value_json
       OR v_evidence.origin_published_at IS DISTINCT FROM p_origin_published_at
       OR v_evidence.extraction_method IS DISTINCT FROM p_extraction_method
       OR v_evidence.extraction_version IS DISTINCT FROM p_extraction_version
       OR v_evidence.fingerprint_version IS DISTINCT FROM p_fingerprint_version THEN
      RAISE EXCEPTION 'MARKETROUTE_EVIDENCE_FINGERPRINT_COLLISION';
    END IF;
  END IF;

  RETURN QUERY SELECT v_source_id, v_acquisition_id, v_evidence_id, v_source_created, v_evidence_created;
END;
$$;

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
AS $$
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

  SELECT dependence_family_key INTO v_family
  FROM public.evidence_items
  WHERE id = p_evidence_item_id;
  IF v_family IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_EVIDENCE_NOT_FOUND'; END IF;

  INSERT INTO public.claims(
    tenant_scope_organisation_id, subject_type, subject_id, claim_key, predicate,
    object_json, canonical_value_text, claim_fingerprint, fingerprint_version
  ) VALUES (
    p_tenant_scope_organisation_id, p_subject_type, p_subject_id, p_claim_key, p_predicate,
    p_object_json, p_canonical_value_text, p_claim_fingerprint, p_claim_fingerprint_version
  )
  ON CONFLICT (claim_fingerprint) DO NOTHING
  RETURNING id INTO v_claim_id;

  IF v_claim_id IS NOT NULL THEN
    v_claim_created := true;
  ELSE
    SELECT * INTO v_claim FROM public.claims WHERE claim_fingerprint = p_claim_fingerprint;
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

  INSERT INTO public.claim_evidence_links(
    claim_id, evidence_item_id, polarity, dependence_family_key, link_method, link_version
  ) VALUES (
    v_claim_id, p_evidence_item_id, p_polarity, v_family, p_link_method, p_link_version
  )
  ON CONFLICT (claim_id, evidence_item_id, polarity) DO NOTHING
  RETURNING id INTO v_link_id;

  IF v_link_id IS NOT NULL THEN
    v_link_created := true;
  ELSE
    SELECT id INTO v_link_id
    FROM public.claim_evidence_links
    WHERE claim_id = v_claim_id AND evidence_item_id = p_evidence_item_id AND polarity = p_polarity;
  END IF;

  RETURN QUERY SELECT v_claim_id, v_link_id, v_claim_created, v_link_created;
END;
$$;

CREATE OR REPLACE FUNCTION public.marketroute_supersede_claim_v1(
  p_prior_claim_id uuid,
  p_replacement_claim_id uuid,
  p_reason_code text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id uuid;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF length(btrim(COALESCE(p_reason_code, ''))) = 0 THEN RAISE EXCEPTION 'MARKETROUTE_SUPERSESSION_REASON_REQUIRED'; END IF;
  INSERT INTO public.claim_supersessions(prior_claim_id, replacement_claim_id, reason_code)
  VALUES (p_prior_claim_id, p_replacement_claim_id, p_reason_code)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

-- Evidence/claim writes are now RPC-only. The backend retains read access for reasoning builds.
REVOKE ALL ON public.source_records FROM anon, authenticated, service_role;
REVOKE ALL ON public.source_acquisitions FROM anon, authenticated, service_role;
REVOKE ALL ON public.evidence_items FROM anon, authenticated, service_role;
REVOKE ALL ON public.claims FROM anon, authenticated, service_role;
REVOKE ALL ON public.claim_supersessions FROM anon, authenticated, service_role;
REVOKE ALL ON public.claim_evidence_links FROM anon, authenticated, service_role;

GRANT SELECT ON public.source_records TO service_role;
GRANT SELECT ON public.source_acquisitions TO service_role;
GRANT SELECT ON public.evidence_items TO service_role;
GRANT SELECT ON public.claims TO service_role;
GRANT SELECT ON public.claim_supersessions TO service_role;
GRANT SELECT ON public.claim_evidence_links TO service_role;

REVOKE ALL ON FUNCTION public.marketroute_require_service_role() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_protect_source_identity() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_ingest_evidence_v1(text,text,text,text,timestamptz,text,text,text,text,jsonb,timestamptz,text,text,integer,text,text,text,jsonb,uuid,text,uuid,text,text,jsonb,timestamptz,timestamptz,text,text,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_record_claim_evidence_v1(uuid,text,uuid,text,text,jsonb,text,text,text,uuid,text,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_supersede_claim_v1(uuid,uuid,text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.marketroute_ingest_evidence_v1(text,text,text,text,timestamptz,text,text,text,text,jsonb,timestamptz,text,text,integer,text,text,text,jsonb,uuid,text,uuid,text,text,jsonb,timestamptz,timestamptz,text,text,text,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_record_claim_evidence_v1(uuid,text,uuid,text,text,jsonb,text,text,text,uuid,text,text,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_supersede_claim_v1(uuid,uuid,text) TO service_role;

INSERT INTO public.marketroute_schema_releases(
  release_key,
  build_number,
  constitution_version,
  metadata_json
) VALUES (
  'MRV2-BUILD3-EVIDENCE-PROVENANCE',
  3,
  'MRV2-CONSTITUTION-1.0.0',
  jsonb_build_object(
    'authority_writers', 0,
    'evidence_runtime', 'RPC_ONLY',
    'dependence_family_owned_by_evidence', true,
    'truth_calculation', false,
    'commercial_authority', false
  )
);

NOTIFY pgrst, 'reload schema';

COMMIT;
