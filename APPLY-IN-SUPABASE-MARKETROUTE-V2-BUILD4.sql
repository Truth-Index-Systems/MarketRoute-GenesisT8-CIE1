BEGIN;

-- MarketRoute V2 Build 4: Truth Engine V2
-- Evidence may now produce non-authoritative epistemic state. Commercial authority remains impossible.

CREATE TABLE public.truth_claim_policy_registry (
  policy_key text PRIMARY KEY,
  policy_version text NOT NULL,
  max_age_days integer NOT NULL CHECK (max_age_days BETWEEN 1 AND 3650),
  known_support_family_requirement integer NOT NULL CHECK (known_support_family_requirement >= 2),
  active boolean NOT NULL DEFAULT true,
  metadata_json jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata_json) = 'object'),
  registered_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.truth_claim_policy_bindings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  subject_type text NOT NULL,
  claim_key text NOT NULL,
  policy_key text NOT NULL REFERENCES public.truth_claim_policy_registry(policy_key) ON DELETE RESTRICT,
  precedence integer NOT NULL CHECK (precedence BETWEEN 1 AND 10000),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (subject_type, claim_key),
  UNIQUE (precedence, subject_type, claim_key),
  CHECK (subject_type = '*' OR subject_type IN ('COMPANY','PERSON','SELLER_BUSINESS','CAMPAIGN','RELATIONSHIP','CHANNEL','OTHER')),
  CHECK (length(btrim(claim_key)) > 0)
);

CREATE TABLE public.truth_entity_profile_registry (
  profile_key text PRIMARY KEY,
  profile_version text NOT NULL,
  subject_type text NOT NULL CHECK (subject_type IN ('COMPANY','PERSON','SELLER_BUSINESS','CAMPAIGN','RELATIONSHIP','CHANNEL','OTHER')),
  required_claim_keys jsonb NOT NULL CHECK (jsonb_typeof(required_claim_keys) = 'array' AND jsonb_array_length(required_claim_keys) > 0),
  active boolean NOT NULL DEFAULT true,
  metadata_json jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata_json) = 'object'),
  registered_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.truth_claim_policy_registry(
  policy_key, policy_version, max_age_days, known_support_family_requirement, metadata_json
) VALUES
  ('GENERAL_FACT_V1', '1.0.0', 180, 2, jsonb_build_object('purpose', 'default factual claim')),
  ('IDENTITY_V1', '1.0.0', 365, 2, jsonb_build_object('purpose', 'entity identity claim')),
  ('CURRENT_STATE_V1', '1.0.0', 120, 2, jsonb_build_object('purpose', 'time-sensitive current-state claim'));

INSERT INTO public.truth_claim_policy_bindings(subject_type, claim_key, policy_key, precedence) VALUES
  ('COMPANY', 'identity.canonical_name', 'IDENTITY_V1', 10),
  ('COMPANY', 'identity.canonical_domain', 'IDENTITY_V1', 11),
  ('COMPANY', 'operation.current', 'CURRENT_STATE_V1', 12),
  ('PERSON', 'identity.canonical_name', 'IDENTITY_V1', 20),
  ('PERSON', 'employment.current', 'CURRENT_STATE_V1', 21),
  ('PERSON', 'role.current', 'CURRENT_STATE_V1', 22),
  ('CHANNEL', 'ownership.current', 'CURRENT_STATE_V1', 30),
  ('*', '*', 'GENERAL_FACT_V1', 10000);

INSERT INTO public.truth_entity_profile_registry(
  profile_key, profile_version, subject_type, required_claim_keys, metadata_json
) VALUES
  (
    'COMPANY_CORE_V1', '1.0.0', 'COMPANY',
    '["identity.canonical_name","identity.canonical_domain","operation.current"]'::jsonb,
    jsonb_build_object('truth_index_semantics', 'MAXIMIN_EPISTEMIC_READINESS_NOT_PROBABILITY')
  ),
  (
    'SELLER_BUSINESS_CORE_V1', '1.0.0', 'SELLER_BUSINESS',
    '["identity.canonical_name","identity.canonical_domain"]'::jsonb,
    jsonb_build_object('truth_index_semantics', 'MAXIMIN_EPISTEMIC_READINESS_NOT_PROBABILITY')
  );

CREATE TABLE public.truth_claim_snapshots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reasoning_run_id uuid NOT NULL,
  reasoning_artifact_id uuid NOT NULL,
  claim_id uuid NOT NULL REFERENCES public.claims(id) ON DELETE RESTRICT,
  tenant_scope_organisation_id uuid REFERENCES public.organisations(id) ON DELETE RESTRICT,
  subject_type text NOT NULL,
  subject_id uuid NOT NULL,
  claim_key text NOT NULL,
  proposition_fingerprint text NOT NULL CHECK (proposition_fingerprint ~ '^[a-f0-9]{64}$'),
  policy_key text NOT NULL REFERENCES public.truth_claim_policy_registry(policy_key) ON DELETE RESTRICT,
  policy_version text NOT NULL,
  engine_version text NOT NULL,
  semantics_version text NOT NULL,
  input_fingerprint text NOT NULL CHECK (input_fingerprint ~ '^[a-f0-9]{64}$'),
  snapshot_fingerprint text NOT NULL CHECK (snapshot_fingerprint ~ '^[a-f0-9]{64}$'),
  truth_state text NOT NULL CHECK (truth_state IN ('KNOWN','SUPPORTED','UNRESOLVED','CONTRADICTED','STALE')),
  current_support_family_count integer NOT NULL CHECK (current_support_family_count >= 0),
  current_contradiction_family_count integer NOT NULL CHECK (current_contradiction_family_count >= 0),
  stale_family_count integer NOT NULL CHECK (stale_family_count >= 0),
  temporal_anomaly_count integer NOT NULL CHECK (temporal_anomaly_count >= 0),
  evidence_sufficiency numeric(9,6) NOT NULL CHECK (evidence_sufficiency BETWEEN 0 AND 1),
  support_strength numeric(9,6) NOT NULL CHECK (support_strength BETWEEN 0 AND 1),
  contradiction_strength numeric(9,6) NOT NULL CHECK (contradiction_strength BETWEEN 0 AND 1),
  evidence_balance numeric(9,6) NOT NULL CHECK (evidence_balance BETWEEN -1 AND 1),
  freshness_coverage numeric(9,6) NOT NULL CHECK (freshness_coverage BETWEEN 0 AND 1),
  truth_probability numeric,
  probability_state text NOT NULL CHECK (probability_state = 'UNCALIBRATED'),
  reference_time timestamptz NOT NULL,
  next_revalidation_at timestamptz,
  payload_json jsonb NOT NULL CHECK (jsonb_typeof(payload_json) = 'object'),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (claim_id, input_fingerprint),
  UNIQUE (snapshot_fingerprint),
  CHECK (truth_probability IS NULL),
  CHECK (next_revalidation_at IS NULL OR next_revalidation_at > reference_time),
  CONSTRAINT truth_claim_snapshots_reasoning_artifact_fk
    FOREIGN KEY (reasoning_artifact_id, reasoning_run_id)
    REFERENCES public.reasoning_artifacts(id, reasoning_run_id)
    ON DELETE RESTRICT
);

CREATE INDEX truth_claim_snapshots_claim_time_idx ON public.truth_claim_snapshots(claim_id, reference_time DESC);
CREATE INDEX truth_claim_snapshots_subject_time_idx ON public.truth_claim_snapshots(subject_type, subject_id, reference_time DESC);
CREATE INDEX truth_claim_snapshots_org_time_idx ON public.truth_claim_snapshots(tenant_scope_organisation_id, reference_time DESC);

CREATE TABLE public.truth_entity_snapshots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reasoning_run_id uuid NOT NULL,
  reasoning_artifact_id uuid NOT NULL,
  tenant_scope_organisation_id uuid REFERENCES public.organisations(id) ON DELETE RESTRICT,
  subject_type text NOT NULL,
  subject_id uuid NOT NULL,
  profile_key text NOT NULL REFERENCES public.truth_entity_profile_registry(profile_key) ON DELETE RESTRICT,
  profile_version text NOT NULL,
  aggregation_version text NOT NULL,
  semantics_version text NOT NULL,
  input_fingerprint text NOT NULL CHECK (input_fingerprint ~ '^[a-f0-9]{64}$'),
  snapshot_fingerprint text NOT NULL CHECK (snapshot_fingerprint ~ '^[a-f0-9]{64}$'),
  entity_state text NOT NULL CHECK (entity_state IN ('KNOWN','SUPPORTED','PARTIAL','UNRESOLVED','CONTRADICTED','STALE')),
  required_claim_count integer NOT NULL CHECK (required_claim_count > 0),
  known_claim_count integer NOT NULL CHECK (known_claim_count >= 0),
  supported_claim_count integer NOT NULL CHECK (supported_claim_count >= 0),
  contradicted_claim_count integer NOT NULL CHECK (contradicted_claim_count >= 0),
  stale_claim_count integer NOT NULL CHECK (stale_claim_count >= 0),
  unresolved_claim_count integer NOT NULL CHECK (unresolved_claim_count >= 0),
  coverage numeric(9,6) NOT NULL CHECK (coverage BETWEEN 0 AND 1),
  current_coverage numeric(9,6) NOT NULL CHECK (current_coverage BETWEEN 0 AND 1),
  evidence_sufficiency numeric(9,6) NOT NULL CHECK (evidence_sufficiency BETWEEN 0 AND 1),
  freshness_coverage numeric(9,6) NOT NULL CHECK (freshness_coverage BETWEEN 0 AND 1),
  coherence numeric(9,6) NOT NULL CHECK (coherence BETWEEN 0 AND 1),
  truth_index numeric(6,2) NOT NULL CHECK (truth_index BETWEEN 0 AND 100),
  truth_probability numeric,
  probability_state text NOT NULL CHECK (probability_state = 'UNCALIBRATED'),
  reference_time timestamptz NOT NULL,
  next_revalidation_at timestamptz,
  claim_snapshot_map jsonb NOT NULL CHECK (jsonb_typeof(claim_snapshot_map) = 'object'),
  payload_json jsonb NOT NULL CHECK (jsonb_typeof(payload_json) = 'object'),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE NULLS NOT DISTINCT (tenant_scope_organisation_id, subject_type, subject_id, profile_key, input_fingerprint),
  UNIQUE (snapshot_fingerprint),
  CHECK (truth_probability IS NULL),
  CHECK (known_claim_count + supported_claim_count + contradicted_claim_count + stale_claim_count + unresolved_claim_count = required_claim_count),
  CHECK (next_revalidation_at IS NULL OR next_revalidation_at > reference_time),
  CONSTRAINT truth_entity_snapshots_reasoning_artifact_fk
    FOREIGN KEY (reasoning_artifact_id, reasoning_run_id)
    REFERENCES public.reasoning_artifacts(id, reasoning_run_id)
    ON DELETE RESTRICT
);

CREATE INDEX truth_entity_snapshots_subject_time_idx
ON public.truth_entity_snapshots(tenant_scope_organisation_id, subject_type, subject_id, profile_key, reference_time DESC);

CREATE TRIGGER truth_claim_snapshots_append_only
BEFORE UPDATE OR DELETE ON public.truth_claim_snapshots
FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

CREATE TRIGGER truth_entity_snapshots_append_only
BEFORE UPDATE OR DELETE ON public.truth_entity_snapshots
FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

CREATE OR REPLACE FUNCTION public.marketroute_truth_policy_for_claim_v1(
  p_subject_type text,
  p_claim_key text
)
RETURNS TABLE(
  policy_key text,
  policy_version text,
  max_age_days integer,
  known_support_family_requirement integer
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT r.policy_key, r.policy_version, r.max_age_days, r.known_support_family_requirement
  FROM public.truth_claim_policy_bindings b
  JOIN public.truth_claim_policy_registry r ON r.policy_key = b.policy_key
  WHERE r.active = true
    AND (b.subject_type = p_subject_type OR b.subject_type = '*')
    AND (b.claim_key = p_claim_key OR b.claim_key = '*')
  ORDER BY
    CASE WHEN b.subject_type = p_subject_type THEN 0 ELSE 1 END,
    CASE WHEN b.claim_key = p_claim_key THEN 0 ELSE 1 END,
    b.precedence
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.marketroute_truth_proposition_fingerprint_v1(
  p_claim_id uuid
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_claim public.claims%ROWTYPE;
BEGIN
  SELECT * INTO v_claim FROM public.claims WHERE id = p_claim_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_TRUTH_CLAIM_NOT_FOUND'; END IF;
  RETURN encode(extensions.digest(concat_ws('|',
    'MRV2-TRUTH-PROPOSITION-1.0.0',
    v_claim.subject_type,
    v_claim.subject_id::text,
    v_claim.claim_key,
    v_claim.predicate,
    v_claim.object_json::text,
    COALESCE(v_claim.canonical_value_text, '-')
  ), 'sha256'), 'hex');
END;
$$;

CREATE OR REPLACE FUNCTION public.marketroute_truth_context_fingerprint_v1(
  p_claim_id uuid,
  p_reference_time timestamptz
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_claim public.claims%ROWTYPE;
  v_policy record;
  v_evidence_identity text;
  v_reference_text text;
  v_proposition_fingerprint text;
BEGIN
  SELECT * INTO v_claim FROM public.claims WHERE id = p_claim_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_TRUTH_CLAIM_NOT_FOUND'; END IF;
  IF EXISTS (SELECT 1 FROM public.claim_supersessions WHERE prior_claim_id = p_claim_id) THEN
    RAISE EXCEPTION 'MARKETROUTE_TRUTH_SUPERSEDED_CLAIM_FORBIDDEN';
  END IF;

  SELECT * INTO v_policy
  FROM public.marketroute_truth_policy_for_claim_v1(v_claim.subject_type, v_claim.claim_key);
  IF v_policy.policy_key IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_TRUTH_POLICY_NOT_FOUND'; END IF;

  v_reference_text := to_char(p_reference_time AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"');
  v_proposition_fingerprint := public.marketroute_truth_proposition_fingerprint_v1(p_claim_id);

  SELECT COALESCE(string_agg(
    concat_ws(':',
      e.evidence_fingerprint,
      l.polarity,
      l.dependence_family_key,
      to_char(e.observed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
      COALESCE(to_char(e.origin_published_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'), '-'),
      COALESCE(to_char(s.published_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'), '-')
    ),
    ';' ORDER BY e.evidence_fingerprint, l.polarity, l.dependence_family_key
  ), '')
  INTO v_evidence_identity
  FROM public.claim_evidence_links l
  JOIN public.evidence_items e ON e.id = l.evidence_item_id
  JOIN public.source_acquisitions a ON a.id = e.acquisition_id
  JOIN public.source_records s ON s.id = a.source_id
  WHERE l.claim_id = p_claim_id;

  RETURN encode(extensions.digest(
    concat_ws('|',
      'MRV2-TRUTH-CONTEXT-1.0.0',
      v_claim.claim_fingerprint,
      v_proposition_fingerprint,
      v_policy.policy_key,
      v_policy.policy_version,
      v_policy.max_age_days::text,
      v_policy.known_support_family_requirement::text,
      v_reference_text,
      v_evidence_identity
    ), 'sha256'
  ), 'hex');
END;
$$;

CREATE OR REPLACE FUNCTION public.marketroute_truth_claim_facts_v1(
  p_claim_id uuid,
  p_reference_time timestamptz
)
RETURNS TABLE(
  policy_key text,
  policy_version text,
  max_age_days integer,
  known_support_family_requirement integer,
  current_support_family_count integer,
  current_contradiction_family_count integer,
  stale_family_count integer,
  temporal_anomaly_count integer,
  evidence_sufficiency numeric,
  support_strength numeric,
  contradiction_strength numeric,
  evidence_balance numeric,
  freshness_coverage numeric,
  truth_state text,
  next_revalidation_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_claim public.claims%ROWTYPE;
  v_policy record;
  v_support integer := 0;
  v_contradiction integer := 0;
  v_stale integer := 0;
  v_anomalies integer := 0;
  v_next timestamptz;
  v_current integer := 0;
  v_freshness_sum numeric := 0;
BEGIN
  SELECT * INTO v_claim FROM public.claims WHERE id = p_claim_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_TRUTH_CLAIM_NOT_FOUND'; END IF;
  IF EXISTS (SELECT 1 FROM public.claim_supersessions WHERE prior_claim_id = p_claim_id) THEN
    RAISE EXCEPTION 'MARKETROUTE_TRUTH_SUPERSEDED_CLAIM_FORBIDDEN';
  END IF;

  SELECT * INTO v_policy
  FROM public.marketroute_truth_policy_for_claim_v1(v_claim.subject_type, v_claim.claim_key);
  IF v_policy.policy_key IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_TRUTH_POLICY_NOT_FOUND'; END IF;

  WITH raw AS (
    SELECT
      l.dependence_family_key,
      l.polarity,
      e.observed_at,
      COALESCE(e.origin_published_at, s.published_at, e.observed_at) AS effective_origin,
      (e.observed_at > p_reference_time + interval '5 minutes'
       OR COALESCE(e.origin_published_at, s.published_at, e.observed_at) > p_reference_time + interval '5 minutes') AS temporal_anomaly
    FROM public.claim_evidence_links l
    JOIN public.evidence_items e ON e.id = l.evidence_item_id
    JOIN public.source_acquisitions a ON a.id = e.acquisition_id
    JOIN public.source_records s ON s.id = a.source_id
    WHERE l.claim_id = p_claim_id
  ), family AS (
    SELECT
      dependence_family_key,
      bool_or(NOT temporal_anomaly
              AND p_reference_time - effective_origin < make_interval(days => v_policy.max_age_days)
              AND polarity = 'SUPPORTS') AS current_support,
      bool_or(NOT temporal_anomaly
              AND p_reference_time - effective_origin < make_interval(days => v_policy.max_age_days)
              AND polarity = 'CONTRADICTS') AS current_contradiction,
      bool_or(NOT temporal_anomaly
              AND p_reference_time - effective_origin >= make_interval(days => v_policy.max_age_days)) AS has_stale,
      MAX(
        CASE
          WHEN NOT temporal_anomaly
               AND p_reference_time - effective_origin < make_interval(days => v_policy.max_age_days)
          THEN GREATEST(0::numeric, LEAST(1::numeric,
            1::numeric - (
              extract(epoch FROM (p_reference_time - effective_origin))
              / NULLIF(v_policy.max_age_days::numeric * 86400::numeric, 0)
            )
          ))
          ELSE NULL
        END
      ) AS current_freshness
    FROM raw
    GROUP BY dependence_family_key
  )
  SELECT
    COUNT(*) FILTER (WHERE current_support AND NOT current_contradiction)::integer,
    COUNT(*) FILTER (WHERE current_contradiction)::integer,
    COUNT(*) FILTER (WHERE NOT current_support AND NOT current_contradiction AND has_stale)::integer,
    COALESCE(SUM(current_freshness) FILTER (WHERE current_support OR current_contradiction), 0::numeric)
  INTO v_support, v_contradiction, v_stale, v_freshness_sum
  FROM family;

  SELECT COUNT(*)::integer
  INTO v_anomalies
  FROM public.claim_evidence_links l
  JOIN public.evidence_items e ON e.id = l.evidence_item_id
  JOIN public.source_acquisitions a ON a.id = e.acquisition_id
  JOIN public.source_records s ON s.id = a.source_id
  WHERE l.claim_id = p_claim_id
    AND (
      e.observed_at > p_reference_time + interval '5 minutes'
      OR COALESCE(e.origin_published_at, s.published_at, e.observed_at) > p_reference_time + interval '5 minutes'
    );

  SELECT MIN(COALESCE(e.origin_published_at, s.published_at, e.observed_at) + make_interval(days => v_policy.max_age_days))
  INTO v_next
  FROM public.claim_evidence_links l
  JOIN public.evidence_items e ON e.id = l.evidence_item_id
  JOIN public.source_acquisitions a ON a.id = e.acquisition_id
  JOIN public.source_records s ON s.id = a.source_id
  WHERE l.claim_id = p_claim_id
    AND e.observed_at <= p_reference_time + interval '5 minutes'
    AND COALESCE(e.origin_published_at, s.published_at, e.observed_at) <= p_reference_time + interval '5 minutes'
    AND p_reference_time - COALESCE(e.origin_published_at, s.published_at, e.observed_at) < make_interval(days => v_policy.max_age_days);

  v_current := v_support + v_contradiction;

  policy_key := v_policy.policy_key;
  policy_version := v_policy.policy_version;
  max_age_days := v_policy.max_age_days;
  known_support_family_requirement := v_policy.known_support_family_requirement;
  current_support_family_count := v_support;
  current_contradiction_family_count := v_contradiction;
  stale_family_count := v_stale;
  temporal_anomaly_count := v_anomalies;
  evidence_sufficiency := LEAST(1::numeric, v_current::numeric / v_policy.known_support_family_requirement::numeric);
  support_strength := LEAST(1::numeric, v_support::numeric / v_policy.known_support_family_requirement::numeric);
  contradiction_strength := LEAST(1::numeric, v_contradiction::numeric / v_policy.known_support_family_requirement::numeric);
  evidence_balance := CASE WHEN v_current = 0 THEN 0::numeric ELSE (v_support - v_contradiction)::numeric / v_current::numeric END;
  freshness_coverage := CASE WHEN v_current = 0 THEN 0::numeric ELSE v_freshness_sum / v_current::numeric END;
  truth_state := CASE
    WHEN v_contradiction > 0 THEN 'CONTRADICTED'
    WHEN v_support >= v_policy.known_support_family_requirement THEN 'KNOWN'
    WHEN v_support >= 1 THEN 'SUPPORTED'
    WHEN v_stale > 0 THEN 'STALE'
    ELSE 'UNRESOLVED'
  END;
  next_revalidation_at := v_next;
  RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION public.marketroute_get_claim_truth_context_v1(
  p_claim_id uuid,
  p_reference_time timestamptz DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_reference timestamptz := COALESCE(p_reference_time, now());
  v_claim public.claims%ROWTYPE;
  v_policy record;
  v_context_fingerprint text;
  v_proposition_fingerprint text;
  v_evidence jsonb;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF v_reference > now() + interval '5 minutes' THEN RAISE EXCEPTION 'MARKETROUTE_TRUTH_REFERENCE_TIME_IN_FUTURE'; END IF;

  SELECT * INTO v_claim FROM public.claims WHERE id = p_claim_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_TRUTH_CLAIM_NOT_FOUND'; END IF;
  IF EXISTS (SELECT 1 FROM public.claim_supersessions WHERE prior_claim_id = p_claim_id) THEN
    RAISE EXCEPTION 'MARKETROUTE_TRUTH_SUPERSEDED_CLAIM_FORBIDDEN';
  END IF;

  SELECT * INTO v_policy
  FROM public.marketroute_truth_policy_for_claim_v1(v_claim.subject_type, v_claim.claim_key);
  IF v_policy.policy_key IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_TRUTH_POLICY_NOT_FOUND'; END IF;

  v_context_fingerprint := public.marketroute_truth_context_fingerprint_v1(p_claim_id, v_reference);
  v_proposition_fingerprint := public.marketroute_truth_proposition_fingerprint_v1(p_claim_id);

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'evidenceItemId', e.id,
    'evidenceFingerprint', e.evidence_fingerprint,
    'polarity', l.polarity,
    'dependenceFamilyKey', l.dependence_family_key,
    'observedAt', e.observed_at,
    'originPublishedAt', e.origin_published_at,
    'sourcePublishedAt', s.published_at
  ) ORDER BY e.evidence_fingerprint, l.polarity), '[]'::jsonb)
  INTO v_evidence
  FROM public.claim_evidence_links l
  JOIN public.evidence_items e ON e.id = l.evidence_item_id
  JOIN public.source_acquisitions a ON a.id = e.acquisition_id
  JOIN public.source_records s ON s.id = a.source_id
  WHERE l.claim_id = p_claim_id;

  RETURN jsonb_build_object(
    'claimId', v_claim.id,
    'tenantScopeOrganisationId', v_claim.tenant_scope_organisation_id,
    'subjectType', v_claim.subject_type,
    'subjectId', v_claim.subject_id,
    'claimKey', v_claim.claim_key,
    'claimFingerprint', v_claim.claim_fingerprint,
    'propositionFingerprint', v_proposition_fingerprint,
    'referenceTime', v_reference,
    'contextFingerprint', v_context_fingerprint,
    'policy', jsonb_build_object(
      'policyKey', v_policy.policy_key,
      'policyVersion', v_policy.policy_version,
      'maxAgeDays', v_policy.max_age_days,
      'knownSupportFamilyRequirement', v_policy.known_support_family_requirement
    ),
    'evidence', v_evidence
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.marketroute_persist_claim_truth_v1(
  p_claim_id uuid,
  p_reference_time timestamptz,
  p_context_fingerprint text,
  p_engine_version text,
  p_semantics_version text,
  p_truth_state text,
  p_current_support_family_count integer,
  p_current_contradiction_family_count integer,
  p_stale_family_count integer,
  p_temporal_anomaly_count integer,
  p_evidence_sufficiency numeric,
  p_support_strength numeric,
  p_contradiction_strength numeric,
  p_evidence_balance numeric,
  p_freshness_coverage numeric,
  p_truth_probability numeric,
  p_probability_state text,
  p_next_revalidation_at timestamptz,
  p_payload_json jsonb
)
RETURNS TABLE(
  snapshot_id uuid,
  reasoning_run_id uuid,
  reasoning_artifact_id uuid,
  snapshot_fingerprint text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_claim public.claims%ROWTYPE;
  v_facts record;
  v_current_context text;
  v_proposition_fingerprint text;
  v_snapshot_fingerprint text;
  v_existing public.truth_claim_snapshots%ROWTYPE;
  v_run_id uuid;
  v_artifact_id uuid;
  v_snapshot_id uuid;
  v_metric_tolerance numeric := 0.000001;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF p_reference_time > now() + interval '5 minutes' THEN RAISE EXCEPTION 'MARKETROUTE_TRUTH_REFERENCE_TIME_IN_FUTURE'; END IF;
  IF p_engine_version IS DISTINCT FROM 'MRV2-TRUTH-1.0.0' OR p_semantics_version IS DISTINCT FROM 'MRV2-TRUTH-SEM-1.0.0' THEN
    RAISE EXCEPTION 'MARKETROUTE_TRUTH_ENGINE_VERSION_MISMATCH';
  END IF;
  IF p_truth_probability IS NOT NULL OR p_probability_state IS DISTINCT FROM 'UNCALIBRATED' THEN
    RAISE EXCEPTION 'MARKETROUTE_TRUTH_PROBABILITY_FORBIDDEN_UNTIL_CALIBRATED';
  END IF;

  SELECT * INTO v_claim FROM public.claims WHERE id = p_claim_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_TRUTH_CLAIM_NOT_FOUND'; END IF;

  v_current_context := public.marketroute_truth_context_fingerprint_v1(p_claim_id, p_reference_time);
  v_proposition_fingerprint := public.marketroute_truth_proposition_fingerprint_v1(p_claim_id);
  IF v_current_context IS DISTINCT FROM p_context_fingerprint THEN
    RAISE EXCEPTION 'MARKETROUTE_TRUTH_CONTEXT_CHANGED';
  END IF;

  SELECT * INTO v_facts FROM public.marketroute_truth_claim_facts_v1(p_claim_id, p_reference_time);

  IF p_truth_state IS DISTINCT FROM v_facts.truth_state
     OR p_current_support_family_count IS DISTINCT FROM v_facts.current_support_family_count
     OR p_current_contradiction_family_count IS DISTINCT FROM v_facts.current_contradiction_family_count
     OR p_stale_family_count IS DISTINCT FROM v_facts.stale_family_count
     OR p_temporal_anomaly_count IS DISTINCT FROM v_facts.temporal_anomaly_count
     OR abs(p_evidence_sufficiency - v_facts.evidence_sufficiency) > v_metric_tolerance
     OR abs(p_support_strength - v_facts.support_strength) > v_metric_tolerance
     OR abs(p_contradiction_strength - v_facts.contradiction_strength) > v_metric_tolerance
     OR abs(p_evidence_balance - v_facts.evidence_balance) > v_metric_tolerance
     OR abs(p_freshness_coverage - v_facts.freshness_coverage) > v_metric_tolerance
     OR (p_next_revalidation_at IS NULL) IS DISTINCT FROM (v_facts.next_revalidation_at IS NULL)
     OR (p_next_revalidation_at IS NOT NULL AND v_facts.next_revalidation_at IS NOT NULL
         AND abs(extract(epoch FROM (p_next_revalidation_at - v_facts.next_revalidation_at))) > 0.002) THEN
    RAISE EXCEPTION 'MARKETROUTE_TRUTH_OUTPUT_DOES_NOT_MATCH_EVIDENCE';
  END IF;

  v_snapshot_fingerprint := encode(extensions.digest(
    concat_ws('|',
      'MRV2-TRUTH-SNAPSHOT-1.0.0',
      p_context_fingerprint,
      v_proposition_fingerprint,
      p_engine_version,
      p_semantics_version,
      v_facts.policy_key,
      v_facts.policy_version,
      p_truth_state,
      p_current_support_family_count::text,
      p_current_contradiction_family_count::text,
      p_stale_family_count::text,
      p_temporal_anomaly_count::text,
      round(p_evidence_sufficiency, 6)::text,
      round(p_support_strength, 6)::text,
      round(p_contradiction_strength, 6)::text,
      round(p_evidence_balance, 6)::text,
      round(p_freshness_coverage, 6)::text,
      p_probability_state,
      COALESCE(to_char(v_facts.next_revalidation_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'), '-')
    ), 'sha256'
  ), 'hex');

  SELECT * INTO v_existing
  FROM public.truth_claim_snapshots
  WHERE claim_id = p_claim_id AND input_fingerprint = p_context_fingerprint;

  IF FOUND THEN
    IF v_existing.snapshot_fingerprint IS DISTINCT FROM v_snapshot_fingerprint THEN
      RAISE EXCEPTION 'MARKETROUTE_TRUTH_SNAPSHOT_COLLISION';
    END IF;
    RETURN QUERY SELECT v_existing.id, v_existing.reasoning_run_id, v_existing.reasoning_artifact_id, v_existing.snapshot_fingerprint;
    RETURN;
  END IF;

  INSERT INTO public.reasoning_runs(
    organisation_id, campaign_id, reasoning_kind, engine_version, input_fingerprint,
    status, started_at, completed_at, metadata_json
  ) VALUES (
    v_claim.tenant_scope_organisation_id, NULL, 'TRUTH', p_engine_version, p_context_fingerprint,
    'SUCCEEDED', p_reference_time, p_reference_time,
    jsonb_build_object('semanticsVersion', p_semantics_version, 'artifact', 'CLAIM_TRUTH')
  ) RETURNING id INTO v_run_id;

  INSERT INTO public.reasoning_artifacts(
    reasoning_run_id, artifact_kind, subject_type, subject_id,
    artifact_fingerprint, payload_json, evaluated_at
  ) VALUES (
    v_run_id, 'TRUTH_CLAIM_SNAPSHOT', v_claim.subject_type, v_claim.subject_id,
    v_snapshot_fingerprint,
    jsonb_build_object(
      'engineVersion', p_engine_version,
      'semanticsVersion', p_semantics_version,
      'claimId', v_claim.id,
      'claimKey', v_claim.claim_key,
      'claimFingerprint', v_claim.claim_fingerprint,
      'propositionFingerprint', v_proposition_fingerprint,
      'truthState', p_truth_state,
      'currentSupportFamilyCount', p_current_support_family_count,
      'currentContradictionFamilyCount', p_current_contradiction_family_count,
      'staleFamilyCount', p_stale_family_count,
      'temporalAnomalyCount', p_temporal_anomaly_count,
      'evidenceSufficiency', round(p_evidence_sufficiency,6),
      'supportStrength', round(p_support_strength,6),
      'contradictionStrength', round(p_contradiction_strength,6),
      'evidenceBalance', round(p_evidence_balance,6),
      'freshnessCoverage', round(p_freshness_coverage,6),
      'truthProbability', NULL,
      'probabilityState', p_probability_state,
      'referenceTime', p_reference_time,
      'nextRevalidationAt', v_facts.next_revalidation_at,
      'familyDiagnostics', COALESCE(p_payload_json->'familyDiagnostics', '[]'::jsonb)
    ),
    p_reference_time
  ) RETURNING id INTO v_artifact_id;

  INSERT INTO public.truth_claim_snapshots(
    reasoning_run_id, reasoning_artifact_id, claim_id, tenant_scope_organisation_id,
    subject_type, subject_id, claim_key, proposition_fingerprint,
    policy_key, policy_version, engine_version, semantics_version,
    input_fingerprint, snapshot_fingerprint, truth_state,
    current_support_family_count, current_contradiction_family_count, stale_family_count, temporal_anomaly_count,
    evidence_sufficiency, support_strength, contradiction_strength, evidence_balance, freshness_coverage,
    truth_probability, probability_state, reference_time, next_revalidation_at, payload_json
  ) VALUES (
    v_run_id, v_artifact_id, v_claim.id, v_claim.tenant_scope_organisation_id,
    v_claim.subject_type, v_claim.subject_id, v_claim.claim_key, v_proposition_fingerprint,
    v_facts.policy_key, v_facts.policy_version, p_engine_version, p_semantics_version,
    p_context_fingerprint, v_snapshot_fingerprint, p_truth_state,
    p_current_support_family_count, p_current_contradiction_family_count, p_stale_family_count, p_temporal_anomaly_count,
    round(p_evidence_sufficiency, 6), round(p_support_strength, 6), round(p_contradiction_strength, 6), round(p_evidence_balance, 6), round(p_freshness_coverage, 6),
    NULL, p_probability_state, p_reference_time, v_facts.next_revalidation_at,
    jsonb_build_object(
      'engineVersion', p_engine_version,
      'semanticsVersion', p_semantics_version,
      'claimId', v_claim.id,
      'claimKey', v_claim.claim_key,
      'claimFingerprint', v_claim.claim_fingerprint,
      'propositionFingerprint', v_proposition_fingerprint,
      'truthState', p_truth_state,
      'currentSupportFamilyCount', p_current_support_family_count,
      'currentContradictionFamilyCount', p_current_contradiction_family_count,
      'staleFamilyCount', p_stale_family_count,
      'temporalAnomalyCount', p_temporal_anomaly_count,
      'evidenceSufficiency', round(p_evidence_sufficiency,6),
      'supportStrength', round(p_support_strength,6),
      'contradictionStrength', round(p_contradiction_strength,6),
      'evidenceBalance', round(p_evidence_balance,6),
      'freshnessCoverage', round(p_freshness_coverage,6),
      'truthProbability', NULL,
      'probabilityState', p_probability_state,
      'referenceTime', p_reference_time,
      'nextRevalidationAt', v_facts.next_revalidation_at,
      'familyDiagnostics', COALESCE(p_payload_json->'familyDiagnostics', '[]'::jsonb)
    )
  ) RETURNING id INTO v_snapshot_id;

  RETURN QUERY SELECT v_snapshot_id, v_run_id, v_artifact_id, v_snapshot_fingerprint;
END;
$$;

CREATE OR REPLACE FUNCTION public.marketroute_get_entity_truth_context_v1(
  p_tenant_scope_organisation_id uuid,
  p_subject_type text,
  p_subject_id uuid,
  p_profile_key text,
  p_reference_time timestamptz DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_reference timestamptz := COALESCE(p_reference_time, now());
  v_profile public.truth_entity_profile_registry%ROWTYPE;
  v_claims jsonb;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF v_reference > now() + interval '5 minutes' THEN RAISE EXCEPTION 'MARKETROUTE_TRUTH_REFERENCE_TIME_IN_FUTURE'; END IF;

  SELECT * INTO v_profile
  FROM public.truth_entity_profile_registry
  WHERE profile_key = p_profile_key AND active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_TRUTH_ENTITY_PROFILE_NOT_FOUND'; END IF;
  IF v_profile.subject_type IS DISTINCT FROM p_subject_type THEN RAISE EXCEPTION 'MARKETROUTE_TRUTH_ENTITY_PROFILE_SUBJECT_MISMATCH'; END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'claimKey', key.value,
    'claimIds', COALESCE((
      SELECT jsonb_agg(c.id ORDER BY c.created_at, c.id)
      FROM public.claims c
      WHERE c.subject_type = p_subject_type
        AND c.subject_id = p_subject_id
        AND c.claim_key = key.value
        AND (
          (p_tenant_scope_organisation_id IS NULL AND c.tenant_scope_organisation_id IS NULL)
          OR (p_tenant_scope_organisation_id IS NOT NULL AND (c.tenant_scope_organisation_id IS NULL OR c.tenant_scope_organisation_id = p_tenant_scope_organisation_id))
        )
        AND NOT EXISTS (SELECT 1 FROM public.claim_supersessions s WHERE s.prior_claim_id = c.id)
    ), '[]'::jsonb)
  ) ORDER BY key.ordinality), '[]'::jsonb)
  INTO v_claims
  FROM jsonb_array_elements_text(v_profile.required_claim_keys) WITH ORDINALITY AS key(value, ordinality);

  RETURN jsonb_build_object(
    'tenantScopeOrganisationId', p_tenant_scope_organisation_id,
    'subjectType', p_subject_type,
    'subjectId', p_subject_id,
    'referenceTime', v_reference,
    'profile', jsonb_build_object(
      'profileKey', v_profile.profile_key,
      'profileVersion', v_profile.profile_version,
      'subjectType', v_profile.subject_type,
      'requiredClaimKeys', v_profile.required_claim_keys
    ),
    'claims', v_claims
  );
END;
$$;

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

  SELECT * INTO v_existing
  FROM public.truth_entity_snapshots
  WHERE tenant_scope_organisation_id IS NOT DISTINCT FROM p_tenant_scope_organisation_id
    AND subject_type = p_subject_type
    AND subject_id = p_subject_id
    AND profile_key = p_profile_key
    AND input_fingerprint = v_input_fingerprint;
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

CREATE OR REPLACE VIEW public.latest_truth_claim_snapshots AS
SELECT DISTINCT ON (claim_id)
  id, reasoning_run_id, reasoning_artifact_id, claim_id, tenant_scope_organisation_id,
  subject_type, subject_id, claim_key, proposition_fingerprint, policy_key, policy_version, engine_version, semantics_version,
  input_fingerprint, snapshot_fingerprint, truth_state,
  current_support_family_count, current_contradiction_family_count, stale_family_count, temporal_anomaly_count,
  evidence_sufficiency, support_strength, contradiction_strength, evidence_balance, freshness_coverage,
  truth_probability, probability_state, reference_time, next_revalidation_at, created_at
FROM public.truth_claim_snapshots
ORDER BY claim_id, reference_time DESC, created_at DESC;

CREATE OR REPLACE VIEW public.latest_truth_entity_snapshots AS
SELECT DISTINCT ON (tenant_scope_organisation_id, subject_type, subject_id, profile_key)
  id, reasoning_run_id, reasoning_artifact_id, tenant_scope_organisation_id,
  subject_type, subject_id, profile_key, profile_version, aggregation_version, semantics_version,
  input_fingerprint, snapshot_fingerprint, entity_state,
  required_claim_count, known_claim_count, supported_claim_count, contradicted_claim_count, stale_claim_count, unresolved_claim_count,
  coverage, current_coverage, evidence_sufficiency, freshness_coverage, coherence, truth_index,
  truth_probability, probability_state, reference_time, next_revalidation_at, created_at
FROM public.truth_entity_snapshots
ORDER BY tenant_scope_organisation_id, subject_type, subject_id, profile_key, reference_time DESC, created_at DESC;

ALTER TABLE public.truth_claim_policy_registry ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.truth_claim_policy_bindings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.truth_entity_profile_registry ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.truth_claim_snapshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.truth_entity_snapshots ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.truth_claim_policy_registry FROM anon, authenticated, service_role;
REVOKE ALL ON public.truth_claim_policy_bindings FROM anon, authenticated, service_role;
REVOKE ALL ON public.truth_entity_profile_registry FROM anon, authenticated, service_role;
REVOKE ALL ON public.truth_claim_snapshots FROM anon, authenticated, service_role;
REVOKE ALL ON public.truth_entity_snapshots FROM anon, authenticated, service_role;
REVOKE ALL ON public.latest_truth_claim_snapshots FROM anon, authenticated, service_role;
REVOKE ALL ON public.latest_truth_entity_snapshots FROM anon, authenticated, service_role;

GRANT SELECT ON public.truth_claim_policy_registry TO service_role;
GRANT SELECT ON public.truth_claim_policy_bindings TO service_role;
GRANT SELECT ON public.truth_entity_profile_registry TO service_role;
GRANT SELECT ON public.truth_claim_snapshots TO service_role;
GRANT SELECT ON public.truth_entity_snapshots TO service_role;
GRANT SELECT ON public.latest_truth_claim_snapshots TO service_role;
GRANT SELECT ON public.latest_truth_entity_snapshots TO service_role;

-- From Build 4 onward, generic reasoning persistence is no longer directly writable.
-- Each reasoning layer must provide an audited SECURITY DEFINER RPC like Truth does here.
REVOKE INSERT, UPDATE, DELETE ON public.reasoning_runs FROM service_role;
REVOKE INSERT, UPDATE, DELETE ON public.reasoning_artifacts FROM service_role;
GRANT SELECT ON public.reasoning_runs TO service_role;
GRANT SELECT ON public.reasoning_artifacts TO service_role;

REVOKE ALL ON FUNCTION public.marketroute_truth_policy_for_claim_v1(text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_truth_proposition_fingerprint_v1(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_truth_context_fingerprint_v1(uuid,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_truth_claim_facts_v1(uuid,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_get_claim_truth_context_v1(uuid,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_persist_claim_truth_v1(uuid,timestamptz,text,text,text,text,integer,integer,integer,integer,numeric,numeric,numeric,numeric,numeric,numeric,text,timestamptz,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_get_entity_truth_context_v1(uuid,text,uuid,text,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_persist_entity_truth_v1(uuid,text,uuid,text,timestamptz,jsonb,text,text,text,integer,integer,integer,integer,integer,integer,numeric,numeric,numeric,numeric,numeric,numeric,numeric,text,timestamptz,jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.marketroute_get_claim_truth_context_v1(uuid,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_persist_claim_truth_v1(uuid,timestamptz,text,text,text,text,integer,integer,integer,integer,numeric,numeric,numeric,numeric,numeric,numeric,text,timestamptz,jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_get_entity_truth_context_v1(uuid,text,uuid,text,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_persist_entity_truth_v1(uuid,text,uuid,text,timestamptz,jsonb,text,text,text,integer,integer,integer,integer,integer,integer,numeric,numeric,numeric,numeric,numeric,numeric,numeric,text,timestamptz,jsonb) TO service_role;

INSERT INTO public.marketroute_schema_releases(
  release_key, build_number, constitution_version, metadata_json
) VALUES (
  'MRV2-BUILD4-TRUTH-ENGINE-V2',
  4,
  'MRV2-CONSTITUTION-1.0.0',
  jsonb_build_object(
    'authority_writers', 0,
    'truth_engine', 'MRV2-TRUTH-1.0.0',
    'truth_semantics', 'MRV2-TRUTH-SEM-1.0.0',
    'truth_probability', 'UNCALIBRATED_NULL',
    'categorical_truth', true,
    'dependence_family_collapse', true,
    'commercial_authority', false
  )
);

NOTIFY pgrst, 'reload schema';
COMMIT;
