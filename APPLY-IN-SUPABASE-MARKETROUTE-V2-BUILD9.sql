BEGIN;

-- Build 9: Unified Authority Lifecycle.
-- This build introduces NO new authority writer. It composes current R4/R5/R6
-- authority and keeps human workflow state independent from authority state.

ALTER TABLE public.opportunity_human_reviews
  ADD COLUMN IF NOT EXISTS review_request_id uuid,
  ADD COLUMN IF NOT EXISTS prior_workflow_state text,
  ADD COLUMN IF NOT EXISTS resulting_workflow_state text,
  ADD COLUMN IF NOT EXISTS authority_envelope_json jsonb,
  ADD COLUMN IF NOT EXISTS authority_envelope_fingerprint text;

ALTER TABLE public.opportunity_human_reviews
  DROP CONSTRAINT IF EXISTS opportunity_human_reviews_prior_workflow_state_check,
  ADD CONSTRAINT opportunity_human_reviews_prior_workflow_state_check
    CHECK (prior_workflow_state IS NULL OR prior_workflow_state IN ('RESEARCHING','REVIEWABLE','APPROVED','REJECTED','ENGAGED','ARCHIVED')),
  DROP CONSTRAINT IF EXISTS opportunity_human_reviews_resulting_workflow_state_check,
  ADD CONSTRAINT opportunity_human_reviews_resulting_workflow_state_check
    CHECK (resulting_workflow_state IS NULL OR resulting_workflow_state IN ('RESEARCHING','REVIEWABLE','APPROVED','REJECTED','ENGAGED','ARCHIVED')),
  DROP CONSTRAINT IF EXISTS opportunity_human_reviews_authority_envelope_json_check,
  ADD CONSTRAINT opportunity_human_reviews_authority_envelope_json_check
    CHECK (authority_envelope_json IS NULL OR jsonb_typeof(authority_envelope_json)='object'),
  DROP CONSTRAINT IF EXISTS opportunity_human_reviews_authority_envelope_fingerprint_check,
  ADD CONSTRAINT opportunity_human_reviews_authority_envelope_fingerprint_check
    CHECK (authority_envelope_fingerprint IS NULL OR authority_envelope_fingerprint ~ '^[a-f0-9]{64}$');

CREATE UNIQUE INDEX IF NOT EXISTS opportunity_human_reviews_request_idx
ON public.opportunity_human_reviews(opportunity_id, review_request_id)
WHERE review_request_id IS NOT NULL;

CREATE TABLE public.opportunity_workflow_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  opportunity_id uuid NOT NULL,
  organisation_id uuid NOT NULL REFERENCES public.organisations(id) ON DELETE RESTRICT,
  event_type text NOT NULL CHECK (event_type IN ('HUMAN_REVIEW','SYSTEM_REVIEWABILITY','ENGAGEMENT','ARCHIVE','RESTORE')),
  prior_workflow_state text NOT NULL CHECK (prior_workflow_state IN ('RESEARCHING','REVIEWABLE','APPROVED','REJECTED','ENGAGED','ARCHIVED')),
  resulting_workflow_state text NOT NULL CHECK (resulting_workflow_state IN ('RESEARCHING','REVIEWABLE','APPROVED','REJECTED','ENGAGED','ARCHIVED')),
  actor_user_id uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  request_id uuid NOT NULL,
  reason_code text NOT NULL,
  authority_envelope_json jsonb NOT NULL CHECK (jsonb_typeof(authority_envelope_json)='object'),
  authority_envelope_fingerprint text NOT NULL CHECK (authority_envelope_fingerprint ~ '^[a-f0-9]{64}$'),
  occurred_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT opportunity_workflow_events_scope_fk
    FOREIGN KEY (opportunity_id, organisation_id)
    REFERENCES public.opportunities(id, organisation_id)
    ON DELETE RESTRICT,
  UNIQUE (opportunity_id, request_id)
);

CREATE INDEX opportunity_workflow_events_opp_time_idx
ON public.opportunity_workflow_events(opportunity_id, occurred_at DESC, id DESC);

CREATE TRIGGER opportunity_workflow_events_append_only
BEFORE UPDATE OR DELETE ON public.opportunity_workflow_events
FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

CREATE OR REPLACE FUNCTION public.marketroute_authority_envelope_v1(
  p_organisation_id uuid,
  p_campaign_id uuid,
  p_company_id uuid,
  p_at timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
  v_r4 public.commercial_reality_r4_records%ROWTYPE;
  v_r5 public.route_authority_r5_records%ROWTYPE;
  v_r6 public.contact_authority_r6_records%ROWTYPE;
  v_a4 public.authority_records%ROWTYPE;
  v_a5 public.authority_records%ROWTYPE;
  v_a6 public.authority_records%ROWTYPE;
  v_state text;
  v_required_layer text;
  v_reason text;
  v_ready boolean := false;
  v_next timestamptz;
BEGIN
  IF p_at IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_AUTHORITY_LIFECYCLE_TIME_REQUIRED'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.campaigns c WHERE c.id=p_campaign_id AND c.organisation_id=p_organisation_id) THEN
    RAISE EXCEPTION 'MARKETROUTE_AUTHORITY_LIFECYCLE_CAMPAIGN_SCOPE_MISMATCH';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.organisation_company_scopes s WHERE s.organisation_id=p_organisation_id AND s.company_id=p_company_id) THEN
    RAISE EXCEPTION 'MARKETROUTE_AUTHORITY_LIFECYCLE_COMPANY_SCOPE_MISMATCH';
  END IF;

  SELECT r.* INTO v_r4
  FROM public.commercial_reality_r4_records r
  WHERE r.organisation_id=p_organisation_id AND r.campaign_id=p_campaign_id AND r.company_id=p_company_id
    AND public.marketroute_r4_authority_current_v1(r.authority_record_id,p_at)
  ORDER BY r.created_at DESC,r.id DESC LIMIT 1;

  IF FOUND THEN SELECT * INTO v_a4 FROM public.authority_records WHERE id=v_r4.authority_record_id; END IF;

  IF v_r4.id IS NULL THEN
    v_state := 'R4_REVALIDATION_REQUIRED'; v_required_layer := 'R4'; v_reason := 'CURRENT_R4_REQUIRED';
  ELSIF v_r4.decision_code='NOT_ADMISSIBLE' THEN
    v_state := 'NOT_ADMISSIBLE'; v_reason := 'R4_NOT_ADMISSIBLE';
  ELSIF v_r4.decision_code='RESEARCH_REQUIRED' THEN
    v_state := 'COMMERCIAL_RESEARCH_REQUIRED'; v_required_layer := 'R4'; v_reason := 'R4_RESEARCH_REQUIRED';
  ELSE
    SELECT r.* INTO v_r5
    FROM public.route_authority_r5_records r
    WHERE r.organisation_id=p_organisation_id AND r.campaign_id=p_campaign_id AND r.company_id=p_company_id
      AND public.marketroute_r5_authority_current_v1(r.authority_record_id,p_at)
    ORDER BY r.created_at DESC,r.id DESC LIMIT 1;
    IF FOUND THEN SELECT * INTO v_a5 FROM public.authority_records WHERE id=v_r5.authority_record_id; END IF;

    IF v_r5.id IS NULL THEN
      v_state := 'R5_REVALIDATION_REQUIRED'; v_required_layer := 'R5'; v_reason := 'CURRENT_R5_REQUIRED';
    ELSIF v_r5.decision_code='ROUTE_NOT_APPLICABLE' THEN
      v_state := 'ROUTE_NOT_APPLICABLE'; v_reason := 'R5_ROUTE_NOT_APPLICABLE';
    ELSIF v_r5.decision_code='ROUTE_RESEARCH_REQUIRED' THEN
      v_state := 'ROUTE_RESEARCH_REQUIRED'; v_required_layer := 'R5'; v_reason := 'R5_RESEARCH_REQUIRED';
    ELSE
      SELECT r.* INTO v_r6
      FROM public.contact_authority_r6_records r
      WHERE r.organisation_id=p_organisation_id AND r.campaign_id=p_campaign_id AND r.company_id=p_company_id
        AND public.marketroute_r6_authority_current_v1(r.authority_record_id,p_at)
      ORDER BY r.created_at DESC,r.id DESC LIMIT 1;
      IF FOUND THEN SELECT * INTO v_a6 FROM public.authority_records WHERE id=v_r6.authority_record_id; END IF;

      IF v_r6.id IS NULL THEN
        v_state := 'R6_REVALIDATION_REQUIRED'; v_required_layer := 'R6'; v_reason := 'CURRENT_R6_REQUIRED';
      ELSIF v_r6.decision_code='CONTACT_NOT_APPLICABLE' THEN
        v_state := 'CONTACT_NOT_APPLICABLE'; v_reason := 'R6_CONTACT_NOT_APPLICABLE';
      ELSIF v_r6.decision_code='CONTACT_RESEARCH_REQUIRED' THEN
        v_state := 'CONTACT_RESEARCH_REQUIRED'; v_required_layer := 'R6'; v_reason := 'R6_RESEARCH_REQUIRED';
      ELSE
        v_state := 'AUTHORITY_READY'; v_reason := 'R4_R5_R6_CURRENT_AND_AUTHORISED'; v_ready := true;
      END IF;
    END IF;
  END IF;

  SELECT min(value) INTO v_next FROM unnest(ARRAY[
    CASE WHEN v_a4.id IS NOT NULL THEN v_a4.valid_until ELSE NULL END,
    CASE WHEN v_a5.id IS NOT NULL THEN v_a5.valid_until ELSE NULL END,
    CASE WHEN v_a6.id IS NOT NULL THEN v_a6.valid_until ELSE NULL END
  ]::timestamptz[]) AS u(value) WHERE value IS NOT NULL AND value>p_at;

  RETURN jsonb_build_object(
    'version','MRV2-AUTHORITY-LIFECYCLE-1.0.0',
    'organisationId',p_organisation_id::text,
    'campaignId',p_campaign_id::text,
    'companyId',p_company_id::text,
    'evaluatedAt',to_jsonb(p_at),
    'lifecycleState',v_state,
    'authorityReady',v_ready,
    'requiredLayer',v_required_layer,
    'reasonCode',v_reason,
    'nextRevalidationAt',CASE WHEN v_next IS NULL THEN NULL ELSE to_jsonb(v_next) END,
    'r4',jsonb_build_object(
      'current',v_r4.id IS NOT NULL,
      'decision',v_r4.decision_code,
      'authorityRecordId',v_a4.id,
      'authorityFingerprint',v_a4.authority_fingerprint,
      'validUntil',v_a4.valid_until
    ),
    'r5',jsonb_build_object(
      'current',v_r5.id IS NOT NULL,
      'decision',v_r5.decision_code,
      'authorityRecordId',v_a5.id,
      'authorityFingerprint',v_a5.authority_fingerprint,
      'parentAuthorityRecordId',v_r5.parent_r4_authority_record_id,
      'validUntil',v_a5.valid_until
    ),
    'r6',jsonb_build_object(
      'current',v_r6.id IS NOT NULL,
      'decision',v_r6.decision_code,
      'authorityRecordId',v_a6.id,
      'authorityFingerprint',v_a6.authority_fingerprint,
      'parentAuthorityRecordId',v_r6.parent_r5_authority_record_id,
      'validUntil',v_a6.valid_until
    )
  );
END $$;

CREATE OR REPLACE FUNCTION public.marketroute_authority_envelope_fingerprint_v1(p_envelope jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
 SELECT encode(extensions.digest('MRV2-AUTHORITY-ENVELOPE-1.0.0|' || COALESCE(p_envelope,'{}'::jsonb)::text,'sha256'),'hex');
$$;

CREATE OR REPLACE FUNCTION public.marketroute_authority_ready_v1(
  p_organisation_id uuid,p_campaign_id uuid,p_company_id uuid,p_at timestamptz DEFAULT now()
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
 SELECT COALESCE((public.marketroute_authority_envelope_v1(p_organisation_id,p_campaign_id,p_company_id,p_at)->>'authorityReady')::boolean,false);
$$;

CREATE OR REPLACE FUNCTION public.marketroute_opportunity_executable_now_v1(
  p_opportunity_id uuid,
  p_at timestamptz DEFAULT now()
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
 SELECT COALESCE((
   SELECT o.workflow_state='APPROVED'
     AND public.marketroute_authority_ready_v1(o.organisation_id,o.campaign_id,o.company_id,p_at)
   FROM public.opportunities o WHERE o.id=p_opportunity_id
 ),false);
$$;

CREATE OR REPLACE FUNCTION public.marketroute_record_opportunity_review_v1(
  p_opportunity_id uuid,
  p_reviewer_user_id uuid,
  p_decision text,
  p_note text,
  p_request_id uuid,
  p_reviewed_at timestamptz DEFAULT now()
)
RETURNS TABLE(
  review_id uuid,
  workflow_event_id uuid,
  prior_workflow_state text,
  resulting_workflow_state text,
  authority_envelope_fingerprint text,
  executable_now boolean,
  deduplicated boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
  v_opp public.opportunities%ROWTYPE;
  v_existing public.opportunity_human_reviews%ROWTYPE;
  v_review_id uuid;
  v_event_id uuid;
  v_result text;
  v_envelope jsonb;
  v_envelope_fp text;
  v_note text := NULLIF(btrim(p_note),'');
  v_reason text;
BEGIN
  IF p_request_id IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_REVIEW_REQUEST_ID_REQUIRED'; END IF;
  IF p_reviewer_user_id IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_REVIEWER_REQUIRED'; END IF;
  IF p_decision NOT IN ('APPROVE','REJECT','RETURN_TO_RESEARCH') THEN RAISE EXCEPTION 'MARKETROUTE_REVIEW_DECISION_INVALID'; END IF;

  SELECT * INTO v_opp FROM public.opportunities WHERE id=p_opportunity_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_OPPORTUNITY_NOT_FOUND'; END IF;

  IF NOT EXISTS(
    SELECT 1 FROM public.organisation_memberships m
    WHERE m.organisation_id=v_opp.organisation_id AND m.user_id=p_reviewer_user_id
      AND m.status='ACTIVE' AND m.role IN ('OWNER','ADMIN','MEMBER')
  ) THEN RAISE EXCEPTION 'MARKETROUTE_REVIEWER_NOT_AUTHORISED'; END IF;

  SELECT * INTO v_existing FROM public.opportunity_human_reviews
  WHERE opportunity_id=p_opportunity_id AND review_request_id=p_request_id LIMIT 1;
  IF FOUND THEN
    IF v_existing.reviewer_user_id IS DISTINCT FROM p_reviewer_user_id
       OR v_existing.decision IS DISTINCT FROM p_decision
       OR COALESCE(v_existing.note,'') IS DISTINCT FROM COALESCE(v_note,'') THEN
      RAISE EXCEPTION 'MARKETROUTE_REVIEW_IDEMPOTENCY_COLLISION';
    END IF;
    SELECT e.id INTO v_event_id FROM public.opportunity_workflow_events e
      WHERE e.opportunity_id=p_opportunity_id AND e.request_id=p_request_id LIMIT 1;
    RETURN QUERY SELECT v_existing.id,v_event_id,v_existing.prior_workflow_state,v_existing.resulting_workflow_state,
      v_existing.authority_envelope_fingerprint,public.marketroute_opportunity_executable_now_v1(p_opportunity_id,now()),true;
    RETURN;
  END IF;

  -- Fresh review actions must be near-current, but an idempotent retry may arrive much later.
  IF p_reviewed_at IS NULL OR abs(extract(epoch FROM (now()-p_reviewed_at))) > 300 THEN
    RAISE EXCEPTION 'MARKETROUTE_REVIEW_TIME_NOT_CURRENT';
  END IF;

  v_envelope := public.marketroute_authority_envelope_v1(v_opp.organisation_id,v_opp.campaign_id,v_opp.company_id,p_reviewed_at);
  v_envelope_fp := public.marketroute_authority_envelope_fingerprint_v1(v_envelope);

  IF p_decision='APPROVE' THEN
    IF v_opp.workflow_state<>'REVIEWABLE' THEN RAISE EXCEPTION 'MARKETROUTE_APPROVAL_REQUIRES_REVIEWABLE'; END IF;
    IF COALESCE((v_envelope->>'authorityReady')::boolean,false) IS NOT TRUE THEN RAISE EXCEPTION 'MARKETROUTE_APPROVAL_REQUIRES_CURRENT_AUTHORITY'; END IF;
    v_result := 'APPROVED'; v_reason := 'FOUNDER_APPROVED_CURRENT_AUTHORITY';
  ELSIF p_decision='REJECT' THEN
    IF v_opp.workflow_state NOT IN ('REVIEWABLE','APPROVED') THEN RAISE EXCEPTION 'MARKETROUTE_REJECTION_STATE_INVALID'; END IF;
    v_result := 'REJECTED'; v_reason := 'FOUNDER_REJECTED';
  ELSE
    IF v_opp.workflow_state NOT IN ('REVIEWABLE','APPROVED','REJECTED') THEN RAISE EXCEPTION 'MARKETROUTE_RETURN_TO_RESEARCH_STATE_INVALID'; END IF;
    v_result := 'RESEARCHING'; v_reason := 'FOUNDER_RETURNED_TO_RESEARCH';
  END IF;

  UPDATE public.opportunities SET workflow_state=v_result WHERE id=v_opp.id;

  INSERT INTO public.opportunity_human_reviews(
    opportunity_id,organisation_id,reviewer_user_id,decision,note,review_request_id,
    prior_workflow_state,resulting_workflow_state,authority_envelope_json,authority_envelope_fingerprint,created_at
  ) VALUES(
    v_opp.id,v_opp.organisation_id,p_reviewer_user_id,p_decision,v_note,p_request_id,
    v_opp.workflow_state,v_result,v_envelope,v_envelope_fp,p_reviewed_at
  ) RETURNING id INTO v_review_id;

  INSERT INTO public.opportunity_workflow_events(
    opportunity_id,organisation_id,event_type,prior_workflow_state,resulting_workflow_state,
    actor_user_id,request_id,reason_code,authority_envelope_json,authority_envelope_fingerprint,occurred_at
  ) VALUES(
    v_opp.id,v_opp.organisation_id,'HUMAN_REVIEW',v_opp.workflow_state,v_result,
    p_reviewer_user_id,p_request_id,v_reason,v_envelope,v_envelope_fp,p_reviewed_at
  ) RETURNING id INTO v_event_id;

  RETURN QUERY SELECT v_review_id,v_event_id,v_opp.workflow_state,v_result,v_envelope_fp,
    public.marketroute_opportunity_executable_now_v1(p_opportunity_id,p_reviewed_at),false;
END $$;

ALTER TABLE public.opportunity_workflow_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY opportunity_workflow_events_member_select ON public.opportunity_workflow_events
FOR SELECT TO authenticated
USING (public.marketroute_is_org_member(organisation_id));

REVOKE ALL ON public.opportunity_workflow_events FROM anon,authenticated,service_role;
GRANT SELECT ON public.opportunity_workflow_events TO authenticated,service_role;

-- Direct workflow DML remains forbidden. Build 9 grants only the scoped review RPC.
REVOKE INSERT,UPDATE,DELETE ON public.opportunities FROM anon,authenticated,service_role;
REVOKE INSERT,UPDATE,DELETE ON public.opportunity_human_reviews FROM anon,authenticated,service_role;

REVOKE ALL ON FUNCTION public.marketroute_authority_envelope_v1(uuid,uuid,uuid,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_authority_envelope_fingerprint_v1(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_authority_ready_v1(uuid,uuid,uuid,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_opportunity_executable_now_v1(uuid,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_record_opportunity_review_v1(uuid,uuid,text,text,uuid,timestamptz) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.marketroute_authority_envelope_v1(uuid,uuid,uuid,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_authority_ready_v1(uuid,uuid,uuid,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_opportunity_executable_now_v1(uuid,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_record_opportunity_review_v1(uuid,uuid,text,text,uuid,timestamptz) TO service_role;

INSERT INTO public.marketroute_schema_releases(release_key,build_number,constitution_version,metadata_json)
VALUES('MARKETROUTE_V2_BUILD9_AUTHORITY_LIFECYCLE',9,'MRV2-CONSTITUTION-1.0.0',jsonb_build_object(
  'migration','0012_unified_authority_lifecycle.sql',
  'authority_writers',3,
  'new_authority_writer',false,
  'workflow_state_independent_of_authority',true,
  'approval_captures_exact_authority_envelope',true,
  'approved_stale_authority_preserves_approval',true,
  'execution_predicate_requires_approved_and_current_r4_r5_r6',true
))
ON CONFLICT(release_key) DO NOTHING;

NOTIFY pgrst,'reload schema';
COMMIT;
