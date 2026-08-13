BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

CREATE TABLE public.marketroute_schema_releases (
  release_key text PRIMARY KEY,
  build_number integer NOT NULL CHECK (build_number > 0),
  constitution_version text NOT NULL,
  applied_at timestamptz NOT NULL DEFAULT now(),
  metadata_json jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata_json) = 'object')
);

REVOKE ALL ON public.marketroute_schema_releases FROM anon, authenticated, service_role;
GRANT SELECT ON public.marketroute_schema_releases TO service_role;

CREATE TABLE public.organisations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 160),
  slug text NOT NULL UNIQUE CHECK (slug = lower(slug) AND slug ~ '^[a-z0-9][a-z0-9-]{1,62}$'),
  status text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','SUSPENDED','CLOSED')),
  created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX organisations_created_by_idx ON public.organisations(created_by);

CREATE TABLE public.organisation_memberships (
  organisation_id uuid NOT NULL REFERENCES public.organisations(id) ON DELETE RESTRICT,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role text NOT NULL CHECK (role IN ('OWNER','ADMIN','MEMBER','VIEWER')),
  status text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','INVITED','DISABLED')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (organisation_id, user_id)
);

CREATE INDEX organisation_memberships_user_idx ON public.organisation_memberships(user_id, status);

CREATE TABLE public.seller_businesses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organisation_id uuid NOT NULL REFERENCES public.organisations(id) ON DELETE RESTRICT,
  name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 200),
  canonical_domain text,
  website_url text,
  lifecycle_state text NOT NULL DEFAULT 'ACTIVE' CHECK (lifecycle_state IN ('ACTIVE','ARCHIVED')),
  created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organisation_id, id),
  CHECK (canonical_domain IS NULL OR canonical_domain = lower(canonical_domain))
);

CREATE INDEX seller_businesses_org_idx ON public.seller_businesses(organisation_id, lifecycle_state);

CREATE TABLE public.campaigns (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organisation_id uuid NOT NULL REFERENCES public.organisations(id) ON DELETE RESTRICT,
  seller_business_id uuid NOT NULL,
  name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 200),
  workflow_state text NOT NULL DEFAULT 'DRAFT' CHECK (workflow_state IN ('DRAFT','ACTIVE','PAUSED','ARCHIVED')),
  objective_text text,
  created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organisation_id, id),
  CONSTRAINT campaigns_seller_business_scope_fk
    FOREIGN KEY (organisation_id, seller_business_id)
    REFERENCES public.seller_businesses(organisation_id, id)
    ON DELETE RESTRICT
);

CREATE INDEX campaigns_org_state_idx ON public.campaigns(organisation_id, workflow_state);

CREATE OR REPLACE FUNCTION public.marketroute_touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER organisations_touch_updated_at
BEFORE UPDATE ON public.organisations
FOR EACH ROW EXECUTE FUNCTION public.marketroute_touch_updated_at();

CREATE TRIGGER organisation_memberships_touch_updated_at
BEFORE UPDATE ON public.organisation_memberships
FOR EACH ROW EXECUTE FUNCTION public.marketroute_touch_updated_at();

CREATE TRIGGER seller_businesses_touch_updated_at
BEFORE UPDATE ON public.seller_businesses
FOR EACH ROW EXECUTE FUNCTION public.marketroute_touch_updated_at();

CREATE TRIGGER campaigns_touch_updated_at
BEFORE UPDATE ON public.campaigns
FOR EACH ROW EXECUTE FUNCTION public.marketroute_touch_updated_at();

CREATE OR REPLACE FUNCTION public.marketroute_is_org_member(p_organisation_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.organisation_memberships m
    WHERE m.organisation_id = p_organisation_id
      AND m.user_id = auth.uid()
      AND m.status = 'ACTIVE'
  );
$$;

CREATE OR REPLACE FUNCTION public.marketroute_is_org_admin(p_organisation_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.organisation_memberships m
    WHERE m.organisation_id = p_organisation_id
      AND m.user_id = auth.uid()
      AND m.status = 'ACTIVE'
      AND m.role IN ('OWNER','ADMIN')
  );
$$;

CREATE OR REPLACE FUNCTION public.marketroute_create_organisation(p_name text, p_slug text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_organisation_id uuid;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'MARKETROUTE_AUTH_REQUIRED';
  END IF;

  INSERT INTO public.organisations(name, slug, created_by)
  VALUES (btrim(p_name), lower(btrim(p_slug)), v_user_id)
  RETURNING id INTO v_organisation_id;

  INSERT INTO public.organisation_memberships(organisation_id, user_id, role, status)
  VALUES (v_organisation_id, v_user_id, 'OWNER', 'ACTIVE');

  RETURN v_organisation_id;
END;
$$;

ALTER TABLE public.organisations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.organisation_memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.seller_businesses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.campaigns ENABLE ROW LEVEL SECURITY;

CREATE POLICY organisations_select_member ON public.organisations
FOR SELECT TO authenticated
USING (public.marketroute_is_org_member(id));

CREATE POLICY memberships_select_member ON public.organisation_memberships
FOR SELECT TO authenticated
USING (public.marketroute_is_org_member(organisation_id));

CREATE POLICY seller_businesses_member_select ON public.seller_businesses
FOR SELECT TO authenticated
USING (public.marketroute_is_org_member(organisation_id));

CREATE POLICY campaigns_member_select ON public.campaigns
FOR SELECT TO authenticated
USING (public.marketroute_is_org_member(organisation_id));

REVOKE ALL ON public.organisations FROM anon, authenticated, service_role;
REVOKE ALL ON public.organisation_memberships FROM anon, authenticated, service_role;
GRANT SELECT ON public.organisations TO authenticated;
GRANT SELECT ON public.organisation_memberships TO authenticated;
GRANT SELECT ON public.seller_businesses TO authenticated;
GRANT SELECT ON public.campaigns TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.organisations TO service_role;
GRANT SELECT, INSERT, UPDATE ON public.organisation_memberships TO service_role;
GRANT SELECT, INSERT, UPDATE ON public.seller_businesses TO service_role;
GRANT SELECT, INSERT, UPDATE ON public.campaigns TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_is_org_member(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_is_org_admin(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_create_organisation(text, text) TO authenticated;

REVOKE ALL ON FUNCTION public.marketroute_touch_updated_at() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_is_org_member(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_is_org_admin(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_create_organisation(text, text) FROM PUBLIC;

COMMIT;

BEGIN;

CREATE TABLE public.companies (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  canonical_name text NOT NULL CHECK (length(btrim(canonical_name)) BETWEEN 1 AND 240),
  canonical_domain text UNIQUE,
  website_url text,
  country_code text CHECK (country_code IS NULL OR country_code ~ '^[A-Z]{2}$'),
  lifecycle_state text NOT NULL DEFAULT 'ACTIVE' CHECK (lifecycle_state IN ('ACTIVE','MERGED','DISSOLVED','ARCHIVED')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (canonical_domain IS NULL OR canonical_domain = lower(canonical_domain))
);

CREATE TABLE public.people (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  display_name text NOT NULL CHECK (length(btrim(display_name)) BETWEEN 1 AND 240),
  canonical_name text,
  lifecycle_state text NOT NULL DEFAULT 'ACTIVE' CHECK (lifecycle_state IN ('ACTIVE','MERGED','ARCHIVED')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.organisation_company_scopes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organisation_id uuid NOT NULL REFERENCES public.organisations(id) ON DELETE CASCADE,
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  campaign_id uuid,
  scope_kind text NOT NULL DEFAULT 'RESEARCH' CHECK (scope_kind IN ('RESEARCH','CAMPAIGN','MIGRATION','MANUAL')),
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (scope_kind <> 'CAMPAIGN' OR campaign_id IS NOT NULL),
  CONSTRAINT organisation_company_scopes_campaign_scope_fk
    FOREIGN KEY (organisation_id, campaign_id)
    REFERENCES public.campaigns(organisation_id, id)
    ON DELETE CASCADE
);

CREATE UNIQUE INDEX organisation_company_scopes_identity_unique
ON public.organisation_company_scopes(organisation_id, company_id, scope_kind, campaign_id) NULLS NOT DISTINCT;

CREATE INDEX organisation_company_scopes_org_idx ON public.organisation_company_scopes(organisation_id, campaign_id);
CREATE INDEX organisation_company_scopes_company_idx ON public.organisation_company_scopes(company_id);

CREATE TABLE public.source_records (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_kind text NOT NULL CHECK (source_kind IN ('WEB','DOCUMENT','API','REGISTRY','USER_PROVIDED','INTERNAL','OTHER')),
  canonical_url text,
  publisher_domain text,
  title text,
  published_at timestamptz,
  first_observed_at timestamptz NOT NULL DEFAULT now(),
  last_observed_at timestamptz NOT NULL DEFAULT now(),
  content_fingerprint text,
  metadata_json jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata_json) = 'object'),
  CHECK (publisher_domain IS NULL OR publisher_domain = lower(publisher_domain)),
  CHECK (last_observed_at >= first_observed_at)
);

CREATE UNIQUE INDEX source_records_canonical_url_unique
ON public.source_records(canonical_url)
WHERE canonical_url IS NOT NULL;

CREATE INDEX source_records_domain_idx ON public.source_records(publisher_domain);

CREATE TABLE public.source_acquisitions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id uuid NOT NULL REFERENCES public.source_records(id) ON DELETE RESTRICT,
  acquired_at timestamptz NOT NULL DEFAULT now(),
  acquisition_method text NOT NULL CHECK (acquisition_method IN ('WEB_FETCH','SEARCH_RESULT','API','IMPORT','USER_UPLOAD','MANUAL')),
  observed_content_fingerprint text,
  http_status integer CHECK (http_status IS NULL OR http_status BETWEEN 100 AND 599),
  raw_locator text,
  parser_version text,
  request_id text,
  metadata_json jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata_json) = 'object')
);

CREATE INDEX source_acquisitions_source_time_idx ON public.source_acquisitions(source_id, acquired_at DESC);

CREATE TABLE public.evidence_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  acquisition_id uuid NOT NULL REFERENCES public.source_acquisitions(id) ON DELETE RESTRICT,
  tenant_scope_organisation_id uuid REFERENCES public.organisations(id) ON DELETE RESTRICT,
  subject_type text NOT NULL CHECK (subject_type IN ('COMPANY','PERSON','SELLER_BUSINESS','CAMPAIGN','RELATIONSHIP','CHANNEL','OTHER')),
  subject_id uuid NOT NULL,
  evidence_kind text NOT NULL CHECK (evidence_kind IN ('QUOTE','STRUCTURED_FIELD','OBSERVATION','DOCUMENT_SECTION','REGISTRY_RECORD','USER_ASSERTION','OTHER')),
  excerpt_text text,
  structured_value_json jsonb,
  observed_at timestamptz NOT NULL DEFAULT now(),
  origin_published_at timestamptz,
  extraction_method text NOT NULL CHECK (extraction_method IN ('DETERMINISTIC','AI_EXTRACTED','USER_PROVIDED','MIGRATED')),
  extraction_version text,
  evidence_fingerprint text NOT NULL CHECK (evidence_fingerprint ~ '^[a-f0-9]{64}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (excerpt_text IS NOT NULL OR structured_value_json IS NOT NULL)
);

CREATE UNIQUE INDEX evidence_items_fingerprint_unique
ON public.evidence_items(evidence_fingerprint);

CREATE INDEX evidence_items_subject_idx ON public.evidence_items(subject_type, subject_id, observed_at DESC);
CREATE INDEX evidence_items_tenant_idx ON public.evidence_items(tenant_scope_organisation_id, created_at DESC);

CREATE TABLE public.claims (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_scope_organisation_id uuid REFERENCES public.organisations(id) ON DELETE RESTRICT,
  subject_type text NOT NULL CHECK (subject_type IN ('COMPANY','PERSON','SELLER_BUSINESS','CAMPAIGN','RELATIONSHIP','CHANNEL','OTHER')),
  subject_id uuid NOT NULL,
  claim_key text NOT NULL,
  predicate text NOT NULL,
  object_json jsonb NOT NULL,
  canonical_value_text text,
  claim_fingerprint text NOT NULL CHECK (claim_fingerprint ~ '^[a-f0-9]{64}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (claim_fingerprint)
);


CREATE INDEX claims_subject_key_idx ON public.claims(subject_type, subject_id, claim_key, created_at DESC);
CREATE INDEX claims_tenant_idx ON public.claims(tenant_scope_organisation_id, created_at DESC);

CREATE TABLE public.claim_supersessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  prior_claim_id uuid NOT NULL REFERENCES public.claims(id) ON DELETE RESTRICT,
  replacement_claim_id uuid REFERENCES public.claims(id) ON DELETE RESTRICT,
  reason_code text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (prior_claim_id),
  CHECK (replacement_claim_id IS NULL OR replacement_claim_id <> prior_claim_id)
);

CREATE INDEX claim_supersessions_replacement_idx ON public.claim_supersessions(replacement_claim_id) WHERE replacement_claim_id IS NOT NULL;

CREATE TABLE public.claim_evidence_links (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  claim_id uuid NOT NULL REFERENCES public.claims(id) ON DELETE RESTRICT,
  evidence_item_id uuid NOT NULL REFERENCES public.evidence_items(id) ON DELETE RESTRICT,
  polarity text NOT NULL CHECK (polarity IN ('SUPPORTS','CONTRADICTS')),
  dependence_family_key text NOT NULL CHECK (length(btrim(dependence_family_key)) > 0),
  link_method text NOT NULL CHECK (link_method IN ('DETERMINISTIC','AI_EXTRACTED','USER_PROVIDED','MIGRATED')),
  link_version text,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (claim_id, evidence_item_id, polarity)
);

CREATE INDEX claim_evidence_links_claim_idx ON public.claim_evidence_links(claim_id, created_at);
CREATE INDEX claim_evidence_links_evidence_idx ON public.claim_evidence_links(evidence_item_id, created_at);

CREATE OR REPLACE FUNCTION public.marketroute_validate_claim_evidence_scope()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_claim_org uuid;
  v_evidence_org uuid;
BEGIN
  SELECT tenant_scope_organisation_id INTO v_claim_org FROM public.claims WHERE id = NEW.claim_id;
  SELECT tenant_scope_organisation_id INTO v_evidence_org FROM public.evidence_items WHERE id = NEW.evidence_item_id;

  IF v_claim_org IS NULL AND v_evidence_org IS NOT NULL THEN
    RAISE EXCEPTION 'MARKETROUTE_GLOBAL_CLAIM_CANNOT_USE_PRIVATE_EVIDENCE';
  END IF;
  IF v_claim_org IS NOT NULL AND v_evidence_org IS NOT NULL AND v_claim_org <> v_evidence_org THEN
    RAISE EXCEPTION 'MARKETROUTE_CLAIM_EVIDENCE_TENANT_MISMATCH';
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.marketroute_validate_claim_supersession_scope()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_prior_org uuid;
  v_prior_subject_type text;
  v_prior_subject_id uuid;
  v_prior_claim_key text;
  v_replacement_org uuid;
  v_replacement_subject_type text;
  v_replacement_subject_id uuid;
  v_replacement_claim_key text;
BEGIN
  SELECT tenant_scope_organisation_id, subject_type, subject_id, claim_key
  INTO v_prior_org, v_prior_subject_type, v_prior_subject_id, v_prior_claim_key
  FROM public.claims
  WHERE id = NEW.prior_claim_id;

  IF NEW.replacement_claim_id IS NOT NULL THEN
    SELECT tenant_scope_organisation_id, subject_type, subject_id, claim_key
    INTO v_replacement_org, v_replacement_subject_type, v_replacement_subject_id, v_replacement_claim_key
    FROM public.claims
    WHERE id = NEW.replacement_claim_id;

    IF v_prior_org IS DISTINCT FROM v_replacement_org
       OR v_prior_subject_type IS DISTINCT FROM v_replacement_subject_type
       OR v_prior_subject_id IS DISTINCT FROM v_replacement_subject_id
       OR v_prior_claim_key IS DISTINCT FROM v_replacement_claim_key THEN
      RAISE EXCEPTION 'MARKETROUTE_CLAIM_SUPERSESSION_SCOPE_MISMATCH';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER claim_evidence_scope_gate
BEFORE INSERT ON public.claim_evidence_links
FOR EACH ROW EXECUTE FUNCTION public.marketroute_validate_claim_evidence_scope();

CREATE TRIGGER claim_supersession_scope_gate
BEFORE INSERT ON public.claim_supersessions
FOR EACH ROW EXECUTE FUNCTION public.marketroute_validate_claim_supersession_scope();

CREATE TRIGGER companies_touch_updated_at
BEFORE UPDATE ON public.companies
FOR EACH ROW EXECUTE FUNCTION public.marketroute_touch_updated_at();

CREATE TRIGGER people_touch_updated_at
BEFORE UPDATE ON public.people
FOR EACH ROW EXECUTE FUNCTION public.marketroute_touch_updated_at();

ALTER TABLE public.companies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.people ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.organisation_company_scopes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.source_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.source_acquisitions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.evidence_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.claims ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.claim_supersessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.claim_evidence_links ENABLE ROW LEVEL SECURITY;

-- Canonical research tables are backend-owned. Authenticated clients receive no direct grants.
REVOKE ALL ON public.companies FROM anon, authenticated, service_role;
REVOKE ALL ON public.people FROM anon, authenticated, service_role;
REVOKE ALL ON public.organisation_company_scopes FROM anon, authenticated, service_role;
REVOKE ALL ON public.source_records FROM anon, authenticated, service_role;
REVOKE ALL ON public.source_acquisitions FROM anon, authenticated, service_role;
REVOKE ALL ON public.evidence_items FROM anon, authenticated, service_role;
REVOKE ALL ON public.claims FROM anon, authenticated, service_role;
REVOKE ALL ON public.claim_supersessions FROM anon, authenticated, service_role;
REVOKE ALL ON public.claim_evidence_links FROM anon, authenticated, service_role;

GRANT SELECT, INSERT, UPDATE ON public.companies TO service_role;
GRANT SELECT, INSERT, UPDATE ON public.people TO service_role;
GRANT SELECT, INSERT, DELETE ON public.organisation_company_scopes TO service_role;
GRANT SELECT, INSERT, UPDATE ON public.source_records TO service_role;
GRANT SELECT, INSERT ON public.source_acquisitions TO service_role;
GRANT SELECT, INSERT ON public.evidence_items TO service_role;
GRANT SELECT, INSERT ON public.claims TO service_role;
GRANT SELECT, INSERT ON public.claim_supersessions TO service_role;
GRANT SELECT, INSERT ON public.claim_evidence_links TO service_role;

REVOKE ALL ON FUNCTION public.marketroute_validate_claim_evidence_scope() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_validate_claim_supersession_scope() FROM PUBLIC;

COMMIT;

BEGIN;

CREATE TABLE public.reasoning_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organisation_id uuid REFERENCES public.organisations(id) ON DELETE RESTRICT,
  campaign_id uuid,
  reasoning_kind text NOT NULL CHECK (reasoning_kind IN ('TRUTH','SELLER_GENOME','COMMERCIAL_REALITY','RELATIONSHIP_GRAPH','CONTACT_TRUTH','RESEARCH_PLAN','ENGAGEMENT_REVIEW','OTHER')),
  engine_version text NOT NULL,
  input_fingerprint text NOT NULL CHECK (input_fingerprint ~ '^[a-f0-9]{64}$'),
  status text NOT NULL DEFAULT 'RUNNING' CHECK (status IN ('RUNNING','SUCCEEDED','FAILED','CANCELLED')),
  started_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  error_code text,
  metadata_json jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata_json) = 'object'),
  CHECK ((status = 'RUNNING' AND completed_at IS NULL) OR (status <> 'RUNNING' AND completed_at IS NOT NULL)),
  CHECK (campaign_id IS NULL OR organisation_id IS NOT NULL),
  CONSTRAINT reasoning_runs_campaign_scope_fk
    FOREIGN KEY (organisation_id, campaign_id)
    REFERENCES public.campaigns(organisation_id, id)
    ON DELETE RESTRICT
);

CREATE INDEX reasoning_runs_scope_state_idx ON public.reasoning_runs(organisation_id, campaign_id, reasoning_kind, status);
CREATE INDEX reasoning_runs_input_idx ON public.reasoning_runs(input_fingerprint);

CREATE TABLE public.reasoning_artifacts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reasoning_run_id uuid NOT NULL REFERENCES public.reasoning_runs(id) ON DELETE RESTRICT,
  artifact_kind text NOT NULL,
  subject_type text NOT NULL,
  subject_id uuid NOT NULL,
  artifact_fingerprint text NOT NULL CHECK (artifact_fingerprint ~ '^[a-f0-9]{64}$'),
  payload_json jsonb NOT NULL CHECK (jsonb_typeof(payload_json) = 'object'),
  evaluated_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (reasoning_run_id, artifact_fingerprint),
  UNIQUE (id, reasoning_run_id)
);

CREATE INDEX reasoning_artifacts_subject_idx ON public.reasoning_artifacts(subject_type, subject_id, evaluated_at DESC);

CREATE TABLE public.authority_writer_registry (
  writer_key text PRIMARY KEY,
  authority_stage text NOT NULL CHECK (authority_stage IN ('COMMERCIAL_REALITY','ROUTE_AUTHORITY','CONTACT_AUTHORITY','EXECUTION_PERMISSION')),
  writer_version text NOT NULL,
  enabled boolean NOT NULL DEFAULT true,
  registered_by_build integer NOT NULL CHECK (registered_by_build >= 3),
  metadata_json jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata_json) = 'object'),
  registered_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.authority_records (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organisation_id uuid NOT NULL REFERENCES public.organisations(id) ON DELETE RESTRICT,
  campaign_id uuid,
  reasoning_run_id uuid NOT NULL,
  reasoning_artifact_id uuid NOT NULL,
  authority_stage text NOT NULL CHECK (authority_stage IN ('COMMERCIAL_REALITY','ROUTE_AUTHORITY','CONTACT_AUTHORITY','EXECUTION_PERMISSION')),
  subject_type text NOT NULL,
  subject_id uuid NOT NULL,
  decision_code text NOT NULL,
  writer_key text NOT NULL REFERENCES public.authority_writer_registry(writer_key) ON DELETE RESTRICT,
  writer_version text NOT NULL,
  input_fingerprint text NOT NULL CHECK (input_fingerprint ~ '^[a-f0-9]{64}$'),
  authority_fingerprint text NOT NULL CHECK (authority_fingerprint ~ '^[a-f0-9]{64}$'),
  parent_authority_fingerprints jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(parent_authority_fingerprints) = 'array'),
  payload_json jsonb NOT NULL CHECK (jsonb_typeof(payload_json) = 'object'),
  valid_from timestamptz NOT NULL,
  valid_until timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (valid_until > valid_from),
  UNIQUE (authority_stage, subject_type, subject_id, authority_fingerprint),
  CHECK (campaign_id IS NULL OR organisation_id IS NOT NULL),
  CONSTRAINT authority_records_campaign_scope_fk
    FOREIGN KEY (organisation_id, campaign_id)
    REFERENCES public.campaigns(organisation_id, id)
    ON DELETE RESTRICT,
  CONSTRAINT authority_records_reasoning_artifact_fk
    FOREIGN KEY (reasoning_artifact_id, reasoning_run_id)
    REFERENCES public.reasoning_artifacts(id, reasoning_run_id)
    ON DELETE RESTRICT
);

CREATE INDEX authority_records_subject_idx ON public.authority_records(organisation_id, authority_stage, subject_type, subject_id, valid_until DESC);
CREATE INDEX authority_records_fingerprint_idx ON public.authority_records(authority_fingerprint);

CREATE TABLE public.authority_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  authority_record_id uuid NOT NULL REFERENCES public.authority_records(id) ON DELETE RESTRICT,
  event_type text NOT NULL CHECK (event_type IN ('GRANTED','REVALIDATED','SUPERSEDED','INVALIDATED','REVOKED','EXPIRED')),
  writer_key text NOT NULL REFERENCES public.authority_writer_registry(writer_key) ON DELETE RESTRICT,
  reason_code text,
  metadata_json jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata_json) = 'object'),
  occurred_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX authority_events_record_time_idx ON public.authority_events(authority_record_id, occurred_at DESC);

CREATE TABLE public.opportunities (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organisation_id uuid NOT NULL REFERENCES public.organisations(id) ON DELETE RESTRICT,
  campaign_id uuid NOT NULL,
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  workflow_state text NOT NULL DEFAULT 'RESEARCHING' CHECK (workflow_state IN ('RESEARCHING','REVIEWABLE','APPROVED','REJECTED','ENGAGED','ARCHIVED')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (campaign_id, company_id),
  UNIQUE (id, organisation_id),
  CONSTRAINT opportunities_campaign_scope_fk
    FOREIGN KEY (organisation_id, campaign_id)
    REFERENCES public.campaigns(organisation_id, id)
    ON DELETE RESTRICT
);

CREATE INDEX opportunities_scope_state_idx ON public.opportunities(organisation_id, campaign_id, workflow_state);
CREATE INDEX opportunities_company_idx ON public.opportunities(company_id);

CREATE TABLE public.opportunity_human_reviews (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  opportunity_id uuid NOT NULL,
  organisation_id uuid NOT NULL REFERENCES public.organisations(id) ON DELETE RESTRICT,
  reviewer_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  decision text NOT NULL CHECK (decision IN ('APPROVE','REJECT','RETURN_TO_RESEARCH')),
  note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT opportunity_human_reviews_scope_fk
    FOREIGN KEY (opportunity_id, organisation_id)
    REFERENCES public.opportunities(id, organisation_id)
    ON DELETE RESTRICT
);

CREATE INDEX opportunity_human_reviews_opp_time_idx ON public.opportunity_human_reviews(opportunity_id, created_at DESC);

CREATE TRIGGER opportunities_touch_updated_at
BEFORE UPDATE ON public.opportunities
FOR EACH ROW EXECUTE FUNCTION public.marketroute_touch_updated_at();

CREATE OR REPLACE FUNCTION public.marketroute_enforce_declared_authority_writer()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_writer_key text := current_setting('marketroute.authority_writer', true);
  v_expected_writer text;
  v_run_org uuid;
  v_run_campaign uuid;
  v_run_input_fingerprint text;
BEGIN
  IF v_writer_key IS NULL OR btrim(v_writer_key) = '' THEN
    RAISE EXCEPTION 'MARKETROUTE_UNDECLARED_AUTHORITY_WRITE';
  END IF;

  IF TG_TABLE_NAME = 'authority_records' THEN
    v_expected_writer := NEW.writer_key;
  ELSE
    v_expected_writer := NEW.writer_key;
  END IF;

  IF v_expected_writer IS DISTINCT FROM v_writer_key THEN
    RAISE EXCEPTION 'MARKETROUTE_AUTHORITY_WRITER_CONTEXT_MISMATCH';
  END IF;

  IF TG_TABLE_NAME = 'authority_records' THEN
    IF NOT EXISTS (
      SELECT 1
      FROM public.authority_writer_registry r
      WHERE r.writer_key = v_writer_key
        AND r.enabled = true
        AND r.authority_stage = NEW.authority_stage
        AND r.writer_version = NEW.writer_version
    ) THEN
      RAISE EXCEPTION 'MARKETROUTE_AUTHORITY_WRITER_CONTRACT_MISMATCH';
    END IF;

    SELECT organisation_id, campaign_id, input_fingerprint
    INTO v_run_org, v_run_campaign, v_run_input_fingerprint
    FROM public.reasoning_runs
    WHERE id = NEW.reasoning_run_id;

    IF v_run_org IS DISTINCT FROM NEW.organisation_id
       OR v_run_campaign IS DISTINCT FROM NEW.campaign_id
       OR v_run_input_fingerprint IS DISTINCT FROM NEW.input_fingerprint THEN
      RAISE EXCEPTION 'MARKETROUTE_AUTHORITY_REASONING_LINEAGE_MISMATCH';
    END IF;
  ELSE
    IF NOT EXISTS (
      SELECT 1
      FROM public.authority_writer_registry r
      JOIN public.authority_records a ON a.id = NEW.authority_record_id
      WHERE r.writer_key = v_writer_key
        AND r.enabled = true
        AND r.authority_stage = a.authority_stage
    ) THEN
      RAISE EXCEPTION 'MARKETROUTE_AUTHORITY_EVENT_WRITER_CONTRACT_MISMATCH';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER authority_records_declared_writer_gate
BEFORE INSERT ON public.authority_records
FOR EACH ROW EXECUTE FUNCTION public.marketroute_enforce_declared_authority_writer();

CREATE TRIGGER authority_events_declared_writer_gate
BEFORE INSERT ON public.authority_events
FOR EACH ROW EXECUTE FUNCTION public.marketroute_enforce_declared_authority_writer();

ALTER TABLE public.reasoning_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reasoning_artifacts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.authority_writer_registry ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.authority_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.authority_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.opportunities ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.opportunity_human_reviews ENABLE ROW LEVEL SECURITY;

CREATE POLICY opportunities_member_select ON public.opportunities
FOR SELECT TO authenticated
USING (public.marketroute_is_org_member(organisation_id));

CREATE POLICY opportunity_reviews_member_select ON public.opportunity_human_reviews
FOR SELECT TO authenticated
USING (public.marketroute_is_org_member(organisation_id));

-- Reasoning is backend-owned. Authority is RPC-write-only and currently has no registered writers.
REVOKE ALL ON public.reasoning_runs FROM anon, authenticated, service_role;
REVOKE ALL ON public.reasoning_artifacts FROM anon, authenticated, service_role;
REVOKE ALL ON public.authority_writer_registry FROM anon, authenticated, service_role;
REVOKE ALL ON public.authority_records FROM anon, authenticated, service_role;
REVOKE ALL ON public.authority_events FROM anon, authenticated, service_role;
REVOKE ALL ON public.opportunities FROM anon, authenticated, service_role;
REVOKE ALL ON public.opportunity_human_reviews FROM anon, authenticated, service_role;

GRANT SELECT, INSERT, UPDATE ON public.reasoning_runs TO service_role;
GRANT SELECT, INSERT ON public.reasoning_artifacts TO service_role;
GRANT SELECT ON public.authority_writer_registry TO service_role;
GRANT SELECT ON public.authority_records TO service_role;
GRANT SELECT ON public.authority_events TO service_role;
GRANT SELECT ON public.opportunities TO authenticated;
GRANT SELECT ON public.opportunity_human_reviews TO authenticated;
GRANT SELECT ON public.opportunities TO service_role;
GRANT SELECT ON public.opportunity_human_reviews TO service_role;

REVOKE ALL ON FUNCTION public.marketroute_enforce_declared_authority_writer() FROM PUBLIC;

COMMIT;

BEGIN;

CREATE TABLE public.scheduler_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  runner_key text NOT NULL,
  status text NOT NULL DEFAULT 'RUNNING' CHECK (status IN ('RUNNING','SUCCEEDED','PARTIAL','FAILED','CANCELLED')),
  started_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  metadata_json jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata_json) = 'object')
);

CREATE TABLE public.scheduler_leases (
  lease_key text PRIMARY KEY,
  owner_run_id uuid NOT NULL REFERENCES public.scheduler_runs(id) ON DELETE CASCADE,
  acquired_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  heartbeat_at timestamptz NOT NULL DEFAULT now(),
  CHECK (expires_at > acquired_at)
);

CREATE TABLE public.background_jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organisation_id uuid REFERENCES public.organisations(id) ON DELETE CASCADE,
  campaign_id uuid,
  job_type text NOT NULL,
  dedupe_key text NOT NULL,
  status text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','RESERVED','RUNNING','SUCCEEDED','FAILED','CANCELLED','DEFERRED')),
  priority integer NOT NULL DEFAULT 100,
  payload_json jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(payload_json) = 'object'),
  available_at timestamptz NOT NULL DEFAULT now(),
  reserved_by_run_id uuid REFERENCES public.scheduler_runs(id) ON DELETE SET NULL,
  reserved_at timestamptz,
  attempt_count integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  max_attempts integer NOT NULL DEFAULT 5 CHECK (max_attempts BETWEEN 1 AND 50),
  last_error_code text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (job_type, dedupe_key),
  CHECK (campaign_id IS NULL OR organisation_id IS NOT NULL),
  CONSTRAINT background_jobs_campaign_scope_fk
    FOREIGN KEY (organisation_id, campaign_id)
    REFERENCES public.campaigns(organisation_id, id)
    ON DELETE CASCADE
);

CREATE INDEX background_jobs_claim_idx ON public.background_jobs(status, available_at, priority, created_at);
CREATE INDEX background_jobs_scope_idx ON public.background_jobs(organisation_id, campaign_id, status);

CREATE TABLE public.background_job_attempts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id uuid NOT NULL REFERENCES public.background_jobs(id) ON DELETE CASCADE,
  scheduler_run_id uuid REFERENCES public.scheduler_runs(id) ON DELETE SET NULL,
  attempt_number integer NOT NULL CHECK (attempt_number > 0),
  status text NOT NULL CHECK (status IN ('RUNNING','SUCCEEDED','FAILED','TIMED_OUT','ABORTED')),
  started_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  error_code text,
  telemetry_json jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(telemetry_json) = 'object'),
  UNIQUE (job_id, attempt_number)
);

CREATE INDEX background_job_attempts_job_idx ON public.background_job_attempts(job_id, attempt_number DESC);

CREATE TABLE public.ai_usage_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organisation_id uuid REFERENCES public.organisations(id) ON DELETE SET NULL,
  campaign_id uuid,
  reasoning_run_id uuid REFERENCES public.reasoning_runs(id) ON DELETE SET NULL,
  provider text NOT NULL,
  model text NOT NULL,
  request_kind text NOT NULL,
  input_tokens bigint CHECK (input_tokens IS NULL OR input_tokens >= 0),
  output_tokens bigint CHECK (output_tokens IS NULL OR output_tokens >= 0),
  cost_usd numeric(18,8) CHECK (cost_usd IS NULL OR cost_usd >= 0),
  latency_ms integer CHECK (latency_ms IS NULL OR latency_ms >= 0),
  status text NOT NULL CHECK (status IN ('SUCCEEDED','FAILED','TIMED_OUT','CANCELLED')),
  created_at timestamptz NOT NULL DEFAULT now(),
  metadata_json jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata_json) = 'object'),
  CHECK (campaign_id IS NULL OR organisation_id IS NOT NULL),
  CONSTRAINT ai_usage_events_campaign_scope_fk
    FOREIGN KEY (organisation_id, campaign_id)
    REFERENCES public.campaigns(organisation_id, id)
    ON DELETE SET NULL
);

CREATE TABLE public.audit_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organisation_id uuid REFERENCES public.organisations(id) ON DELETE SET NULL,
  actor_type text NOT NULL CHECK (actor_type IN ('USER','SYSTEM','SCHEDULER','MIGRATION')),
  actor_id text,
  event_type text NOT NULL,
  subject_type text,
  subject_id uuid,
  details_json jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(details_json) = 'object'),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER background_jobs_touch_updated_at
BEFORE UPDATE ON public.background_jobs
FOR EACH ROW EXECUTE FUNCTION public.marketroute_touch_updated_at();

ALTER TABLE public.scheduler_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.scheduler_leases ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.background_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.background_job_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_usage_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_events ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.scheduler_runs FROM anon, authenticated, service_role;
REVOKE ALL ON public.scheduler_leases FROM anon, authenticated, service_role;
REVOKE ALL ON public.background_jobs FROM anon, authenticated, service_role;
REVOKE ALL ON public.background_job_attempts FROM anon, authenticated, service_role;
REVOKE ALL ON public.ai_usage_events FROM anon, authenticated, service_role;
REVOKE ALL ON public.audit_events FROM anon, authenticated, service_role;

GRANT SELECT, INSERT, UPDATE ON public.scheduler_runs TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.scheduler_leases TO service_role;
GRANT SELECT, INSERT, UPDATE ON public.background_jobs TO service_role;
GRANT SELECT, INSERT, UPDATE ON public.background_job_attempts TO service_role;
GRANT SELECT, INSERT ON public.ai_usage_events TO service_role;
GRANT SELECT, INSERT ON public.audit_events TO service_role;

COMMIT;

BEGIN;

CREATE OR REPLACE FUNCTION public.marketroute_reject_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'MARKETROUTE_APPEND_ONLY_RELATION:%', TG_TABLE_NAME;
END;
$$;

CREATE TRIGGER source_acquisitions_append_only
BEFORE UPDATE OR DELETE ON public.source_acquisitions
FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

CREATE TRIGGER evidence_items_append_only
BEFORE UPDATE OR DELETE ON public.evidence_items
FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

CREATE TRIGGER claims_append_only
BEFORE UPDATE OR DELETE ON public.claims
FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

CREATE TRIGGER claim_supersessions_append_only
BEFORE UPDATE OR DELETE ON public.claim_supersessions
FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

CREATE TRIGGER claim_evidence_links_append_only
BEFORE UPDATE OR DELETE ON public.claim_evidence_links
FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

CREATE TRIGGER reasoning_artifacts_append_only
BEFORE UPDATE OR DELETE ON public.reasoning_artifacts
FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

CREATE TRIGGER authority_records_append_only
BEFORE UPDATE OR DELETE ON public.authority_records
FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

CREATE TRIGGER authority_events_append_only
BEFORE UPDATE OR DELETE ON public.authority_events
FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

CREATE TRIGGER opportunity_human_reviews_append_only
BEFORE UPDATE OR DELETE ON public.opportunity_human_reviews
FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

CREATE TRIGGER ai_usage_events_append_only
BEFORE UPDATE OR DELETE ON public.ai_usage_events
FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

CREATE TRIGGER audit_events_append_only
BEFORE UPDATE OR DELETE ON public.audit_events
FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

REVOKE ALL ON FUNCTION public.marketroute_reject_mutation() FROM PUBLIC;

INSERT INTO public.marketroute_schema_releases(
  release_key,
  build_number,
  constitution_version,
  metadata_json
) VALUES (
  'MRV2-BUILD2-CONSTITUTIONAL-SCHEMA',
  2,
  'MRV2-CONSTITUTION-1.0.0',
  jsonb_build_object(
    'authority_writers', 0,
    'legacy_runtime_dependencies', false,
    'workflow_separate_from_authority', true,
    'evidence_append_only', true
  )
);

NOTIFY pgrst, 'reload schema';

COMMIT;
