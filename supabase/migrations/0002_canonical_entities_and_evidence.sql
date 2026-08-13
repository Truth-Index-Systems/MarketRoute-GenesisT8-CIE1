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
