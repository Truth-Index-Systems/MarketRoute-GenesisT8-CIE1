BEGIN;

-- MarketRoute V2 RC: Assisted Engagement Activation
-- Product policy: MarketRoute may prepare and review outreach, but the human owns
-- the final external action. Manual contact recording is append-only and never
-- creates commercial/contact authority.

CREATE TABLE IF NOT EXISTS public.engagement_manual_actions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id uuid NOT NULL UNIQUE,
  opportunity_id uuid NOT NULL,
  organisation_id uuid NOT NULL REFERENCES public.organisations(id) ON DELETE RESTRICT,
  campaign_id uuid NOT NULL,
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  strategy_id uuid NOT NULL REFERENCES public.engagement_strategies(id) ON DELETE RESTRICT,
  message_id uuid NOT NULL REFERENCES public.engagement_messages(id) ON DELETE RESTRICT,
  actor_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  path_fingerprint text NOT NULL CHECK(path_fingerprint ~ '^[a-f0-9]{64}$'),
  channel_kind text NOT NULL CHECK(channel_kind IN ('EMAIL','CONTACT_FORM','LINKEDIN','PHONE','OTHER')),
  access_point_id uuid NOT NULL REFERENCES public.commercial_graph_nodes(id) ON DELETE RESTRICT,
  person_id uuid REFERENCES public.people(id) ON DELETE RESTRICT,
  authority_envelope_fingerprint text NOT NULL CHECK(authority_envelope_fingerprint ~ '^[a-f0-9]{64}$'),
  note text CHECK(note IS NULL OR length(note) <= 1000),
  occurred_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT engagement_manual_actions_opportunity_scope_fk
    FOREIGN KEY(opportunity_id,organisation_id) REFERENCES public.opportunities(id,organisation_id) ON DELETE RESTRICT,
  CONSTRAINT engagement_manual_actions_campaign_scope_fk
    FOREIGN KEY(organisation_id,campaign_id) REFERENCES public.campaigns(organisation_id,id) ON DELETE RESTRICT
);
CREATE INDEX IF NOT EXISTS engagement_manual_actions_opportunity_idx
  ON public.engagement_manual_actions(opportunity_id,occurred_at DESC,id DESC);
CREATE INDEX IF NOT EXISTS engagement_manual_actions_scope_idx
  ON public.engagement_manual_actions(organisation_id,campaign_id,occurred_at DESC,id DESC);
DROP TRIGGER IF EXISTS engagement_manual_actions_append_only ON public.engagement_manual_actions;
CREATE TRIGGER engagement_manual_actions_append_only
  BEFORE UPDATE OR DELETE ON public.engagement_manual_actions
  FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

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
    RETURN QUERY SELECT v_existing.id,NULL::uuid,'APPROVED'::text,'ENGAGED'::text,v_existing.channel_kind,true;
    RETURN;
  END IF;

  IF p_at IS NULL OR abs(extract(epoch FROM(now()-p_at)))>300 THEN
    RAISE EXCEPTION 'MARKETROUTE_MANUAL_ENGAGEMENT_TIME_NOT_CURRENT';
  END IF;

  SELECT * INTO v_opp FROM public.opportunities WHERE id=p_opportunity_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_MANUAL_ENGAGEMENT_OPPORTUNITY_NOT_FOUND'; END IF;
  IF v_opp.workflow_state<>'APPROVED' THEN
    RAISE EXCEPTION 'MARKETROUTE_MANUAL_ENGAGEMENT_REQUIRES_APPROVED_OPPORTUNITY';
  END IF;
  IF NOT EXISTS(
    SELECT 1 FROM public.organisation_memberships m
    WHERE m.organisation_id=v_opp.organisation_id
      AND m.user_id=p_actor_user_id
      AND m.status='ACTIVE'
      AND m.role IN('OWNER','ADMIN','MEMBER')
  ) THEN RAISE EXCEPTION 'MARKETROUTE_MANUAL_ENGAGEMENT_ACTOR_NOT_AUTHORISED'; END IF;

  -- This existing context function revalidates ACTIVE organisation/campaign,
  -- APPROVED workflow, current R4/R5/R6, executable authority and an R6-authorised path.
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
  v_envelope_fp:=public.marketroute_authority_envelope_fingerprint_v1(v_envelope);
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
    v_opp.id,v_opp.organisation_id,'ENGAGEMENT','APPROVED','ENGAGED',p_actor_user_id,p_request_id,
    'FIRST_MANUAL_ENGAGEMENT_RECORDED',v_envelope,v_envelope_fp,p_at
  ) RETURNING id INTO v_event_id;

  RETURN QUERY SELECT v_action_id,v_event_id,'APPROVED'::text,'ENGAGED'::text,v_strategy.channel_kind,false;
END $fn$;

-- Extend the canonical engagement read with the latest human action. Existing
-- strategy/message/review/approval/queue/delivery fields remain intact for audit history.
CREATE OR REPLACE FUNCTION public.marketroute_application_engagement_read_v1(p_opportunity_id uuid,p_at timestamptz DEFAULT now())
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE
  v_opp public.opportunities%ROWTYPE;
  v_policy text;
  v_strategy public.engagement_strategies%ROWTYPE;
  v_message public.engagement_messages%ROWTYPE;
  v_review public.engagement_ai_reviews%ROWTYPE;
  v_approval public.engagement_message_approvals%ROWTYPE;
  v_queue public.engagement_queue_items%ROWTYPE;
  v_job public.engagement_delivery_jobs%ROWTYPE;
  v_last_delivery public.engagement_delivery_events%ROWTYPE;
  v_manual public.engagement_manual_actions%ROWTYPE;
  v_strategy_current boolean:=false;
  v_executable boolean:=false;
BEGIN
  PERFORM public.marketroute_require_service_role();
  PERFORM public.marketroute_application_require_current_read_time_v1(p_at);
  SELECT * INTO v_opp FROM public.opportunities WHERE id=p_opportunity_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_APPLICATION_ENGAGEMENT_OPPORTUNITY_NOT_FOUND'; END IF;
  v_policy:=public.marketroute_current_engagement_policy_v1(v_opp.organisation_id,v_opp.campaign_id);
  v_executable:=public.marketroute_opportunity_executable_now_v1(v_opp.id,p_at);

  SELECT * INTO v_strategy FROM public.engagement_strategies WHERE opportunity_id=v_opp.id ORDER BY created_at DESC,id DESC LIMIT 1;
  IF v_strategy.id IS NOT NULL THEN
    v_strategy_current:=public.marketroute_engagement_strategy_current_v1(v_strategy.id,p_at);
    SELECT * INTO v_message FROM public.engagement_messages WHERE strategy_id=v_strategy.id ORDER BY rewrite_ordinal DESC,created_at DESC,id DESC LIMIT 1;
  END IF;
  IF v_message.id IS NOT NULL THEN
    SELECT * INTO v_review FROM public.engagement_ai_reviews WHERE message_id=v_message.id ORDER BY created_at DESC,id DESC LIMIT 1;
    SELECT * INTO v_approval FROM public.engagement_message_approvals WHERE message_id=v_message.id ORDER BY created_at DESC,id DESC LIMIT 1;
    SELECT * INTO v_queue FROM public.engagement_queue_items WHERE message_id=v_message.id ORDER BY queued_at DESC,id DESC LIMIT 1;
  END IF;
  IF v_queue.id IS NOT NULL THEN
    SELECT * INTO v_job FROM public.engagement_delivery_jobs WHERE queue_item_id=v_queue.id;
    SELECT * INTO v_last_delivery FROM public.engagement_delivery_events WHERE queue_item_id=v_queue.id ORDER BY occurred_at DESC,id DESC LIMIT 1;
  END IF;
  SELECT * INTO v_manual FROM public.engagement_manual_actions WHERE opportunity_id=v_opp.id ORDER BY occurred_at DESC,id DESC LIMIT 1;

  RETURN jsonb_build_object(
    'contractVersion','MRV2-APPLICATION-READ-1.0.0',
    'evaluatedAt',to_jsonb(p_at),
    'policyMode','HUMAN_ONLY',
    'engagementMode','ASSISTED_ONLY',
    'opportunityExecutableNow',v_executable,
    'strategy',CASE WHEN v_strategy.id IS NULL THEN NULL ELSE jsonb_build_object(
      'strategyId',v_strategy.id,'strategyFingerprint',v_strategy.strategy_fingerprint,'strategyVersion',v_strategy.strategy_version,
      'pathFingerprint',v_strategy.path_fingerprint,'channel',v_strategy.channel_kind,'routeMode',v_strategy.route_mode,
      'accessPointId',v_strategy.access_point_id,'accessPointKind',v_strategy.access_point_kind,'accessPointValue',v_strategy.access_point_value,
      'personId',v_strategy.person_id,'authorityEnvelopeFingerprint',v_strategy.authority_envelope_fingerprint,
      'r6AuthorityRecordId',v_strategy.r6_authority_record_id,'r6AuthorityFingerprint',v_strategy.r6_authority_fingerprint,
      'current',v_strategy_current,'createdAt',v_strategy.created_at
    ) END,
    'message',CASE WHEN v_message.id IS NULL THEN NULL ELSE jsonb_build_object(
      'messageId',v_message.id,'rewriteOrdinal',v_message.rewrite_ordinal,'generationContractVersion',v_message.generation_contract_version,
      'generatorVersion',v_message.generator_version,'subjectText',v_message.subject_text,'bodyText',v_message.body_text,
      'messageFingerprint',v_message.message_fingerprint,'createdAt',v_message.created_at
    ) END,
    'aiReview',CASE WHEN v_review.id IS NULL THEN NULL ELSE jsonb_build_object(
      'reviewId',v_review.id,'reviewContractVersion',v_review.review_contract_version,'reviewerVersion',v_review.reviewer_version,
      'verdict',v_review.verdict,'reasonCodes',to_jsonb(v_review.reason_codes),'diagnostics',v_review.diagnostics_json,
      'reviewFingerprint',v_review.review_fingerprint,'createdAt',v_review.created_at
    ) END,
    'approval',CASE WHEN v_approval.id IS NULL THEN NULL ELSE jsonb_build_object(
      'approvalId',v_approval.id,'mode',v_approval.approval_mode,'decision',v_approval.decision,'actorUserId',v_approval.actor_user_id,
      'authorityEnvelopeFingerprint',v_approval.authority_envelope_fingerprint,'createdAt',v_approval.created_at
    ) END,
    'manualAction',CASE WHEN v_manual.id IS NULL THEN NULL ELSE jsonb_build_object(
      'manualActionId',v_manual.id,'actorUserId',v_manual.actor_user_id,'channel',v_manual.channel_kind,
      'pathFingerprint',v_manual.path_fingerprint,'messageId',v_manual.message_id,
      'authorityEnvelopeFingerprint',v_manual.authority_envelope_fingerprint,'note',v_manual.note,'occurredAt',v_manual.occurred_at
    ) END,
    'queue',CASE WHEN v_queue.id IS NULL THEN NULL ELSE jsonb_build_object(
      'queueItemId',v_queue.id,'approvalMode',v_queue.approval_mode,'authorityEnvelopeFingerprint',v_queue.authority_envelope_fingerprint,'queuedAt',v_queue.queued_at
    ) END,
    'delivery',CASE WHEN v_job.id IS NULL THEN NULL ELSE jsonb_build_object(
      'jobId',v_job.id,'status',v_job.status,'attemptNumber',v_job.attempt_number,'claimedAt',v_job.claimed_at,
      'sendGateFingerprint',v_job.send_gate_fingerprint,'lastErrorCode',v_job.last_error_code,'finishedAt',v_job.finished_at,
      'lastEvent',CASE WHEN v_last_delivery.id IS NULL THEN NULL ELSE jsonb_build_object(
        'eventType',v_last_delivery.event_type,'providerMessageId',v_last_delivery.provider_message_id,
        'sendGateFingerprint',v_last_delivery.send_gate_fingerprint,'occurredAt',v_last_delivery.occurred_at
      ) END
    ) END,
    'actions',jsonb_build_object(
      'canGenerateDraft',v_opp.workflow_state='APPROVED' AND v_executable,
      'canApproveMessage',v_message.id IS NOT NULL AND COALESCE(v_review.verdict,'')='PASS' AND v_executable AND v_strategy_current,
      'canQueue',false,
      'canMarkContacted',v_manual.id IS NULL AND v_message.id IS NOT NULL AND COALESCE(v_review.verdict,'')='PASS'
        AND COALESCE(v_approval.decision,'')='APPROVE' AND COALESCE(v_approval.approval_mode,'')='HUMAN'
        AND v_executable AND v_strategy_current,
      'deliveryNeedsReconciliation',COALESCE(v_job.status,'')='RECONCILIATION_REQUIRED'
    )
  );
END $fn$;

ALTER TABLE public.engagement_manual_actions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.engagement_manual_actions FROM anon,authenticated,service_role;
GRANT SELECT ON public.engagement_manual_actions TO service_role;
REVOKE ALL ON FUNCTION public.marketroute_record_manual_engagement_v1(uuid,text,uuid,uuid,uuid,text,timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_record_manual_engagement_v1(uuid,text,uuid,uuid,uuid,text,timestamptz) TO service_role;

INSERT INTO public.marketroute_schema_releases(
  release_key,build_number,constitution_version,metadata_json
) VALUES(
  'MARKETROUTE_V2_ASSISTED_ENGAGEMENT_ACTIVATION_2026_08_18',
  26,
  'MRV2-CONSTITUTION-1.0.0',
  jsonb_build_object(
    'migration','0050_assisted_engagement_activation.sql',
    'new_authority_writer',false,
    'authority_semantics_unchanged',true,
    'mode','ASSISTED_ONLY',
    'human_final_action_required',true,
    'autonomous_delivery_runtime_disabled',true,
    'manual_action_append_only',true
  )
) ON CONFLICT(release_key) DO NOTHING;

NOTIFY pgrst,'reload schema';
COMMIT;
