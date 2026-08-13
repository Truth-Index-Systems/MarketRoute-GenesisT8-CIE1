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
