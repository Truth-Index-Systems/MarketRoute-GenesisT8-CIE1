BEGIN;

-- RC hotfix: engagement currentness must compare semantic authority state, not observation time.
-- The global authority-envelope fingerprint remains frozen and untouched. Engagement gets a
-- dedicated stable snapshot fingerprint that excludes only evaluatedAt.
CREATE OR REPLACE FUNCTION public.marketroute_engagement_authority_snapshot_fingerprint_v1(p_envelope jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
  SELECT encode(
    extensions.digest(
      'MRV2-ENGAGEMENT-AUTHORITY-SNAPSHOT-1.0.0|' ||
      (COALESCE(p_envelope,'{}'::jsonb) - 'evaluatedAt')::text,
      'sha256'
    ),
    'hex'
  );
$fn$;

REVOKE ALL ON FUNCTION public.marketroute_engagement_authority_snapshot_fingerprint_v1(jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_engagement_authority_snapshot_fingerprint_v1(jsonb) TO service_role;

-- Generation-context fingerprints are also observation-time independent. The 1.0.2
-- namespace intentionally invalidates strategies created under the two timestamp-sensitive
-- predecessor algorithms; pressing Prepare message creates a fresh strategy.
CREATE OR REPLACE FUNCTION public.marketroute_engagement_generation_context_fingerprint_v1(p_context jsonb)
RETURNS text
LANGUAGE sql IMMUTABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
  SELECT encode(
    extensions.digest(
      'MRV2-ENGAGEMENT-GENERATION-CONTEXT-1.0.2|' ||
      (COALESCE(p_context,'{}'::jsonb) - 'evaluatedAt')::text,
      'sha256'
    ),
    'hex'
  );
$fn$;

REVOKE ALL ON FUNCTION public.marketroute_engagement_generation_context_fingerprint_v1(jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_engagement_generation_context_fingerprint_v1(jsonb) TO service_role;

-- Rebind generation context to the stable engagement authority snapshot.
CREATE OR REPLACE FUNCTION public.marketroute_engagement_generation_context_v1(p_opportunity_id uuid,p_path_fingerprint text,p_at timestamptz DEFAULT now())
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE
 v_opp public.opportunities%ROWTYPE; v_company public.companies%ROWTYPE; v_env jsonb; v_envfp text;
 v_r4 public.commercial_reality_r4_records%ROWTYPE; v_r6 public.contact_authority_r6_records%ROWTYPE; v_a6 public.authority_records%ROWTYPE; v_r5 public.route_authority_r5_records%ROWTYPE;
 v_binding jsonb; v_path jsonb; v_node public.commercial_graph_nodes%ROWTYPE; v_person public.people%ROWTYPE; v_seller jsonb;
 v_objective text; v_objective_statement text; v_offering_keys jsonb:='[]'::jsonb; v_offering_labels jsonb:='[]'::jsonb; v_offering_summaries jsonb:='[]'::jsonb; v_boundary_facts jsonb:='[]'::jsonb; v_channel text;
BEGIN
 PERFORM public.marketroute_require_service_role();
 IF p_at IS NULL OR abs(extract(epoch FROM(now()-p_at)))>300 THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_CONTEXT_TIME_NOT_CURRENT'; END IF;
 IF p_path_fingerprint IS NULL OR p_path_fingerprint !~ '^[a-f0-9]{64}$' THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_PATH_FINGERPRINT_INVALID'; END IF;
 SELECT * INTO v_opp FROM public.opportunities WHERE id=p_opportunity_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_OPPORTUNITY_NOT_FOUND'; END IF;
 IF NOT EXISTS(
   SELECT 1 FROM public.organisations o
   JOIN public.campaigns c ON c.organisation_id=o.id AND c.id=v_opp.campaign_id
   JOIN public.seller_businesses sb ON sb.organisation_id=c.organisation_id AND sb.id=c.seller_business_id
   WHERE o.id=v_opp.organisation_id AND o.status='ACTIVE' AND c.workflow_state='ACTIVE' AND sb.lifecycle_state='ACTIVE'
 ) THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_ACTIVE_COMMERCIAL_CONTEXT_REQUIRED'; END IF;
 IF v_opp.workflow_state NOT IN('REVIEWABLE','APPROVED') THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_REQUIRES_READY_OPPORTUNITY'; END IF;
 IF NOT public.marketroute_opportunity_executable_now_v1(v_opp.id,p_at) THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_REQUIRES_CURRENT_AUTHORITY'; END IF;
 SELECT * INTO v_company FROM public.companies WHERE id=v_opp.company_id;
 IF NOT FOUND OR v_company.lifecycle_state<>'ACTIVE' THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_ACTIVE_TARGET_COMPANY_REQUIRED'; END IF;
 v_env:=public.marketroute_authority_envelope_v1(v_opp.organisation_id,v_opp.campaign_id,v_opp.company_id,p_at); v_envfp:=public.marketroute_engagement_authority_snapshot_fingerprint_v1(v_env);
 SELECT r.* INTO v_r4 FROM public.commercial_reality_r4_records r WHERE r.authority_record_id=(v_env->'r4'->>'authorityRecordId')::uuid;
 IF NOT FOUND OR v_r4.decision_code<>'COMMERCIAL_CANDIDATE' THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_CURRENT_R4_REQUIRED'; END IF;
 SELECT COALESCE(jsonb_agg(jsonb_build_object('boundaryKey',b.value->>'boundaryKey','claimKey',b.value->>'claimKey','observedValue',b.value->>'observedValue') ORDER BY b.value->>'boundaryKey'),'[]'::jsonb) INTO v_boundary_facts
 FROM jsonb_array_elements(v_r4.boundaries_json) b(value)
 WHERE b.value->>'state'='SATISFIED' AND NULLIF(b.value->>'claimKey','') IS NOT NULL AND NULLIF(b.value->>'observedValue','') IS NOT NULL;
 SELECT r.* INTO v_r6 FROM public.contact_authority_r6_records r WHERE r.authority_record_id=(v_env->'r6'->>'authorityRecordId')::uuid;
 IF NOT FOUND OR v_r6.decision_code<>'CONTACT_AUTHORISED' THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_CURRENT_R6_REQUIRED'; END IF;
 SELECT * INTO v_a6 FROM public.authority_records WHERE id=v_r6.authority_record_id;
 SELECT r.* INTO v_r5 FROM public.route_authority_r5_records r WHERE r.authority_record_id=v_r6.parent_r5_authority_record_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_PARENT_R5_NOT_FOUND'; END IF;
 SELECT b.value INTO v_binding FROM jsonb_array_elements(v_r6.bindings_json) b(value) WHERE b.value->>'pathFingerprint'=p_path_fingerprint AND b.value->>'authorityState'='AUTHORISED' LIMIT 1;
 IF v_binding IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_PATH_NOT_R6_AUTHORISED'; END IF;
 SELECT p.value INTO v_path FROM jsonb_array_elements(v_r5.paths_json) p(value) WHERE p.value->>'pathFingerprint'=p_path_fingerprint LIMIT 1;
 IF v_path IS NULL OR v_path->>'terminalAccessPointId' IS DISTINCT FROM v_binding->>'terminalAccessPointId' THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_R5_R6_PATH_MISMATCH'; END IF;
 SELECT * INTO v_node FROM public.commercial_graph_nodes WHERE id=(v_binding->>'terminalAccessPointId')::uuid AND node_kind='ACCESS_POINT';
 IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_ACCESS_POINT_NOT_FOUND'; END IF;
 v_channel:=public.marketroute_engagement_channel_kind_v1(v_node.access_point_kind); IF v_channel IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_ACCESS_POINT_KIND_UNSUPPORTED'; END IF;
 IF NULLIF(v_binding->>'personId','') IS NOT NULL THEN SELECT * INTO v_person FROM public.people WHERE id=(v_binding->>'personId')::uuid AND lifecycle_state='ACTIVE'; IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_PERSON_NOT_ACTIVE'; END IF; END IF;
 v_seller:=public.marketroute_get_current_campaign_seller_context_v1(v_opp.organisation_id,v_opp.campaign_id); IF v_seller IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_SELLER_CONTEXT_REQUIRED'; END IF;
 v_objective:=v_seller->>'objectiveKey';
 SELECT e.value->>'statement' INTO v_objective_statement FROM jsonb_array_elements(COALESCE(v_seller->'canonicalGenome'->'explanatory'->'objectiveCopy','[]'::jsonb)) e(value) WHERE e.value->>'objectiveKey'=v_objective LIMIT 1;
 SELECT COALESCE(o.value->'offeringKeys','[]'::jsonb) INTO v_offering_keys FROM jsonb_array_elements(COALESCE(v_seller->'canonicalGenome'->'semantic'->'commercialObjectives'->'items','[]'::jsonb)) o(value) WHERE o.value->>'objectiveKey'=v_objective LIMIT 1;
 SELECT COALESCE(jsonb_agg(c.value->>'label' ORDER BY c.value->>'offeringKey'),'[]'::jsonb),
        COALESCE(jsonb_agg(jsonb_build_object('offeringKey',c.value->>'offeringKey','label',c.value->>'label','description',c.value->'description') ORDER BY c.value->>'offeringKey'),'[]'::jsonb)
 INTO v_offering_labels,v_offering_summaries
 FROM jsonb_array_elements(COALESCE(v_seller->'canonicalGenome'->'explanatory'->'offeringCopy','[]'::jsonb)) c(value)
 WHERE (c.value->>'offeringKey') IN (SELECT jsonb_array_elements_text(COALESCE(v_offering_keys,'[]'::jsonb)));
 RETURN jsonb_build_object(
  'opportunityId',v_opp.id::text,'organisationId',v_opp.organisation_id::text,'campaignId',v_opp.campaign_id::text,'companyId',v_opp.company_id::text,
  'companyName',v_company.canonical_name,'canonicalDomain',v_company.canonical_domain,'pathFingerprint',p_path_fingerprint,
  'accessPointId',v_node.id::text,'accessPointKind',v_node.access_point_kind,'accessPointValue',v_node.canonical_value,
  'routeMode',v_binding->>'mode','personId',NULLIF(v_binding->>'personId',''),'personName',CASE WHEN v_person.id IS NULL THEN NULL ELSE COALESCE(v_person.canonical_name,v_person.display_name) END,
  'sellerObjectiveKey',v_objective,'sellerObjectiveStatement',v_objective_statement,'sellerOfferingLabels',COALESCE(v_offering_labels,'[]'::jsonb),
  'sellerOfferings',COALESCE(v_offering_summaries,'[]'::jsonb),'commercialBoundaryFacts',COALESCE(v_boundary_facts,'[]'::jsonb),
  'authorityEnvelopeFingerprint',v_envfp,'r6AuthorityRecordId',v_r6.authority_record_id::text,'r6AuthorityFingerprint',v_a6.authority_fingerprint,
  'evaluatedAt',to_jsonb(p_at),'executableNow',true
 );
END $fn$;

-- Human message approval stores the same stable semantic authority snapshot used by
-- the strategy, so approval is not invalidated merely because time advanced.
CREATE OR REPLACE FUNCTION public.marketroute_record_engagement_message_approval_v1(
 p_message_id uuid,p_actor_user_id uuid,p_decision text,p_request_id uuid,p_at timestamptz DEFAULT now()
) RETURNS TABLE(approval_id uuid,decision text,approval_mode text,deduplicated boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_existing public.engagement_message_approvals%ROWTYPE; v_message public.engagement_messages%ROWTYPE; v_strategy public.engagement_strategies%ROWTYPE; v_review public.engagement_ai_reviews%ROWTYPE; v_env jsonb; v_envfp text; v_id uuid;
BEGIN
 PERFORM public.marketroute_require_service_role(); IF p_request_id IS NULL OR p_actor_user_id IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_APPROVAL_IDENTITY_REQUIRED'; END IF;
 SELECT * INTO v_existing FROM public.engagement_message_approvals WHERE approval_request_id=p_request_id;
 IF FOUND THEN
  IF v_existing.message_id IS DISTINCT FROM p_message_id OR v_existing.actor_user_id IS DISTINCT FROM p_actor_user_id OR v_existing.decision IS DISTINCT FROM p_decision OR v_existing.approval_mode<>'HUMAN' THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_APPROVAL_IDEMPOTENCY_COLLISION'; END IF;
  RETURN QUERY SELECT v_existing.id,v_existing.decision,v_existing.approval_mode,true; RETURN;
 END IF;
 IF p_at IS NULL OR abs(extract(epoch FROM(now()-p_at)))>300 THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_APPROVAL_TIME_NOT_CURRENT'; END IF; IF p_decision NOT IN('APPROVE','REJECT') THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_APPROVAL_DECISION_INVALID'; END IF;
 SELECT * INTO v_message FROM public.engagement_messages WHERE id=p_message_id; IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_MESSAGE_NOT_FOUND'; END IF;
 SELECT * INTO v_strategy FROM public.engagement_strategies WHERE id=v_message.strategy_id; SELECT * INTO v_review FROM public.engagement_ai_reviews WHERE message_id=p_message_id;
 IF v_review.id IS NULL OR v_review.verdict<>'PASS' THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_HUMAN_APPROVAL_REQUIRES_PASS_REVIEW'; END IF;
 IF NOT public.marketroute_engagement_strategy_current_v1(v_strategy.id,p_at) THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_APPROVAL_STRATEGY_NOT_CURRENT'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.organisation_memberships m WHERE m.organisation_id=v_strategy.organisation_id AND m.user_id=p_actor_user_id AND m.status='ACTIVE' AND m.role IN('OWNER','ADMIN','MEMBER')) THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_APPROVER_NOT_AUTHORISED'; END IF;
 PERFORM 1 FROM public.opportunities o WHERE o.id=v_strategy.opportunity_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_OPPORTUNITY_NOT_FOUND'; END IF;
 IF EXISTS(SELECT 1 FROM public.engagement_delivery_jobs j JOIN public.engagement_queue_items q ON q.id=j.queue_item_id WHERE q.opportunity_id=v_strategy.opportunity_id AND j.status='RUNNING') THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_MESSAGE_APPROVAL_BLOCKED_DURING_DELIVERY'; END IF;
 v_env:=public.marketroute_authority_envelope_v1(v_strategy.organisation_id,v_strategy.campaign_id,v_strategy.company_id,p_at); v_envfp:=public.marketroute_engagement_authority_snapshot_fingerprint_v1(v_env);
 INSERT INTO public.engagement_message_approvals(approval_request_id,message_id,review_id,approval_mode,actor_user_id,decision,policy_version,authority_envelope_json,authority_envelope_fingerprint,created_at)
 VALUES(p_request_id,p_message_id,v_review.id,'HUMAN',p_actor_user_id,p_decision,'MRV2-ENGAGEMENT-POLICY-1.0.0',v_env,v_envfp,p_at) RETURNING id INTO v_id;
 RETURN QUERY SELECT v_id,p_decision,'HUMAN'::text,false;
END $fn$;

-- Manual "Mark contacted" compares strategy + approval against the same stable snapshot.
CREATE OR REPLACE FUNCTION public.marketroute_record_manual_engagement_v1(
  p_opportunity_id uuid,
  p_path_fingerprint text,
  p_message_id uuid,
  p_actor_user_id uuid,
  p_request_id uuid,
  p_note text DEFAULT NULL,
  p_at timestamptz DEFAULT now()
)
RETURNS TABLE(
  manual_action_id uuid,
  workflow_event_id uuid,
  prior_workflow_state text,
  resulting_workflow_state text,
  channel_kind text,
  deduplicated boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
DECLARE
  v_existing public.engagement_manual_actions%ROWTYPE;
  v_opp public.opportunities%ROWTYPE;
  v_strategy public.engagement_strategies%ROWTYPE;
  v_message public.engagement_messages%ROWTYPE;
  v_review public.engagement_ai_reviews%ROWTYPE;
  v_approval public.engagement_message_approvals%ROWTYPE;
  v_context jsonb;
  v_envelope jsonb;
  v_envelope_fp text;
  v_action_id uuid;
  v_event_id uuid;
  v_note text:=NULLIF(left(btrim(COALESCE(p_note,'')),1000),'');
  v_prior text;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF p_request_id IS NULL OR p_actor_user_id IS NULL OR p_opportunity_id IS NULL OR p_message_id IS NULL THEN
    RAISE EXCEPTION 'MARKETROUTE_MANUAL_ENGAGEMENT_IDENTITY_REQUIRED';
  END IF;
  IF p_path_fingerprint IS NULL OR p_path_fingerprint !~ '^[a-f0-9]{64}$' THEN
    RAISE EXCEPTION 'MARKETROUTE_MANUAL_ENGAGEMENT_PATH_INVALID';
  END IF;

  SELECT * INTO v_existing FROM public.engagement_manual_actions WHERE request_id=p_request_id;
  IF FOUND THEN
    IF v_existing.opportunity_id IS DISTINCT FROM p_opportunity_id
      OR v_existing.path_fingerprint IS DISTINCT FROM p_path_fingerprint
      OR v_existing.message_id IS DISTINCT FROM p_message_id
      OR v_existing.actor_user_id IS DISTINCT FROM p_actor_user_id
      OR v_existing.note IS DISTINCT FROM v_note THEN
      RAISE EXCEPTION 'MARKETROUTE_MANUAL_ENGAGEMENT_IDEMPOTENCY_COLLISION';
    END IF;
    RETURN QUERY SELECT v_existing.id,NULL::uuid,'REVIEWABLE'::text,'ENGAGED'::text,v_existing.channel_kind,true;
    RETURN;
  END IF;

  IF p_at IS NULL OR abs(extract(epoch FROM(now()-p_at)))>300 THEN
    RAISE EXCEPTION 'MARKETROUTE_MANUAL_ENGAGEMENT_TIME_NOT_CURRENT';
  END IF;

  SELECT * INTO v_opp FROM public.opportunities WHERE id=p_opportunity_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_MANUAL_ENGAGEMENT_OPPORTUNITY_NOT_FOUND'; END IF;
  IF v_opp.workflow_state NOT IN('REVIEWABLE','APPROVED') THEN
    RAISE EXCEPTION 'MARKETROUTE_MANUAL_ENGAGEMENT_REQUIRES_READY_OPPORTUNITY';
  END IF;
  v_prior:=v_opp.workflow_state;
  IF NOT EXISTS(
    SELECT 1 FROM public.organisation_memberships m
    WHERE m.organisation_id=v_opp.organisation_id
      AND m.user_id=p_actor_user_id
      AND m.status='ACTIVE'
      AND m.role IN('OWNER','ADMIN','MEMBER')
  ) THEN RAISE EXCEPTION 'MARKETROUTE_MANUAL_ENGAGEMENT_ACTOR_NOT_AUTHORISED'; END IF;

  -- The context function revalidates ACTIVE organisation/campaign, system-ready
  -- workflow, current R4/R5/R6, executable authority and an R6-authorised path.
  v_context:=public.marketroute_engagement_generation_context_v1(p_opportunity_id,p_path_fingerprint,p_at);

  SELECT * INTO v_strategy
  FROM public.engagement_strategies s
  WHERE s.opportunity_id=p_opportunity_id AND s.path_fingerprint=p_path_fingerprint
  ORDER BY s.created_at DESC,s.id DESC LIMIT 1;
  IF NOT FOUND OR public.marketroute_engagement_strategy_current_v1(v_strategy.id,p_at) IS NOT TRUE THEN
    RAISE EXCEPTION 'MARKETROUTE_MANUAL_ENGAGEMENT_CURRENT_STRATEGY_REQUIRED';
  END IF;

  SELECT * INTO v_message FROM public.engagement_messages WHERE id=p_message_id AND strategy_id=v_strategy.id;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_MANUAL_ENGAGEMENT_MESSAGE_SCOPE_MISMATCH'; END IF;
  IF EXISTS(SELECT 1 FROM public.engagement_messages newer WHERE newer.strategy_id=v_strategy.id AND newer.rewrite_ordinal>v_message.rewrite_ordinal) THEN
    RAISE EXCEPTION 'MARKETROUTE_MANUAL_ENGAGEMENT_MESSAGE_NOT_CURRENT';
  END IF;

  SELECT * INTO v_review FROM public.engagement_ai_reviews WHERE message_id=v_message.id ORDER BY created_at DESC,id DESC LIMIT 1;
  IF NOT FOUND OR v_review.verdict<>'PASS' THEN
    RAISE EXCEPTION 'MARKETROUTE_MANUAL_ENGAGEMENT_PASS_REVIEW_REQUIRED';
  END IF;
  SELECT * INTO v_approval FROM public.engagement_message_approvals WHERE message_id=v_message.id ORDER BY created_at DESC,id DESC LIMIT 1;
  IF NOT FOUND OR v_approval.approval_mode<>'HUMAN' OR v_approval.decision<>'APPROVE' THEN
    RAISE EXCEPTION 'MARKETROUTE_MANUAL_ENGAGEMENT_HUMAN_APPROVAL_REQUIRED';
  END IF;

  v_envelope:=public.marketroute_authority_envelope_v1(v_opp.organisation_id,v_opp.campaign_id,v_opp.company_id,p_at);
  v_envelope_fp:=public.marketroute_engagement_authority_snapshot_fingerprint_v1(v_envelope);
  IF v_envelope_fp IS DISTINCT FROM v_strategy.authority_envelope_fingerprint
    OR v_envelope_fp IS DISTINCT FROM v_approval.authority_envelope_fingerprint THEN
    RAISE EXCEPTION 'MARKETROUTE_MANUAL_ENGAGEMENT_AUTHORITY_CHANGED';
  END IF;

  INSERT INTO public.engagement_manual_actions(
    request_id,opportunity_id,organisation_id,campaign_id,company_id,strategy_id,message_id,actor_user_id,
    path_fingerprint,channel_kind,access_point_id,person_id,authority_envelope_fingerprint,note,occurred_at
  ) VALUES(
    p_request_id,v_opp.id,v_opp.organisation_id,v_opp.campaign_id,v_opp.company_id,v_strategy.id,v_message.id,p_actor_user_id,
    p_path_fingerprint,v_strategy.channel_kind,v_strategy.access_point_id,v_strategy.person_id,v_envelope_fp,v_note,p_at
  ) RETURNING id INTO v_action_id;

  UPDATE public.opportunities SET workflow_state='ENGAGED',updated_at=p_at WHERE id=v_opp.id;
  INSERT INTO public.opportunity_workflow_events(
    opportunity_id,organisation_id,event_type,prior_workflow_state,resulting_workflow_state,
    actor_user_id,request_id,reason_code,authority_envelope_json,authority_envelope_fingerprint,occurred_at
  ) VALUES(
    v_opp.id,v_opp.organisation_id,'ENGAGEMENT',v_prior,'ENGAGED',p_actor_user_id,p_request_id,
    'FIRST_MANUAL_ENGAGEMENT_RECORDED',v_envelope,v_envelope_fp,p_at
  ) RETURNING id INTO v_event_id;

  RETURN QUERY SELECT v_action_id,v_event_id,v_prior,'ENGAGED'::text,v_strategy.channel_kind,false;
END $fn$;

INSERT INTO public.marketroute_schema_releases(
  release_key,build_number,constitution_version,metadata_json
)
VALUES(
  'MARKETROUTE_V2_RC_ENGAGEMENT_STABLE_AUTHORITY_SNAPSHOT_HOTFIX',
  26,
  'MRV2-CONSTITUTION-1.0.0',
  jsonb_build_object(
    'migration','0055_engagement_stable_authority_snapshot_hotfix.sql',
    'new_authority_writer',false,
    'authority_semantics_unchanged',true,
    'global_authority_envelope_fingerprint_unchanged',true,
    'engagement_authority_snapshot_excludes_observation_time',true,
    'r4_r5_r6_identity_and_fingerprints_preserved',true,
    'message_approval_remains_human',true,
    'autonomous_delivery_enabled',false
  )
)
ON CONFLICT(release_key) DO NOTHING;

NOTIFY pgrst,'reload schema';
COMMIT;
