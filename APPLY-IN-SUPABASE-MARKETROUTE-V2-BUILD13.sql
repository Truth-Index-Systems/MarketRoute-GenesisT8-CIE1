BEGIN;

-- MarketRoute V2 Build 13: Canonical Application API + Authoritative Read Model
-- Read-only projection layer. No new authority writer. No workflow or intelligence mutation.

CREATE OR REPLACE FUNCTION public.marketroute_application_require_current_read_time_v1(p_at timestamptz)
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
BEGIN
  IF p_at IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_APPLICATION_READ_TIME_REQUIRED'; END IF;
  IF abs(extract(epoch FROM (now()-p_at))) > 300 THEN RAISE EXCEPTION 'MARKETROUTE_APPLICATION_READ_TIME_NOT_CURRENT'; END IF;
END $fn$;

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

  RETURN jsonb_build_object(
    'contractVersion','MRV2-APPLICATION-READ-1.0.0',
    'evaluatedAt',to_jsonb(p_at),
    'policyMode',COALESCE(v_policy,'HUMAN_ONLY'),
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
      'canApproveMessage',v_message.id IS NOT NULL AND COALESCE(v_review.verdict,'')='PASS' AND v_policy='HUMAN_ONLY' AND v_executable AND v_strategy_current,
      'canQueue',v_message.id IS NOT NULL AND COALESCE(v_review.verdict,'')='PASS' AND v_executable AND v_strategy_current AND (
        (v_policy='HUMAN_ONLY' AND COALESCE(v_approval.decision,'')='APPROVE') OR v_policy='AUTOPILOT'
      ),
      'deliveryNeedsReconciliation',COALESCE(v_job.status,'')='RECONCILIATION_REQUIRED'
    )
  );
END $fn$;

CREATE OR REPLACE FUNCTION public.marketroute_application_company_read_v1(
  p_organisation_id uuid,p_campaign_id uuid,p_company_id uuid,p_at timestamptz DEFAULT now()
)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE
  v_profile jsonb; v_env jsonb; v_gap jsonb; v_opp public.opportunities%ROWTYPE;
  v_r4 public.commercial_reality_r4_records%ROWTYPE; v_a4 public.authority_records%ROWTYPE;
  v_r5 public.route_authority_r5_records%ROWTYPE; v_a5 public.authority_records%ROWTYPE;
  v_r6 public.contact_authority_r6_records%ROWTYPE; v_a6 public.authority_records%ROWTYPE;
  v_truth public.truth_entity_snapshots%ROWTYPE;
  v_workflow_events jsonb:='[]'::jsonb; v_reviews jsonb:='[]'::jsonb; v_sync_events jsonb:='[]'::jsonb;
  v_engagement jsonb:=NULL;
BEGIN
  PERFORM public.marketroute_require_service_role();
  PERFORM public.marketroute_application_require_current_read_time_v1(p_at);
  v_profile:=public.marketroute_opportunity_profile_v1(p_organisation_id,p_campaign_id,p_company_id,p_at);
  v_env:=v_profile->'authorityEnvelope';
  v_gap:=public.marketroute_research_gap_context_v1(p_organisation_id,p_campaign_id,p_company_id,p_at);
  SELECT * INTO v_opp FROM public.opportunities WHERE organisation_id=p_organisation_id AND campaign_id=p_campaign_id AND company_id=p_company_id LIMIT 1;

  IF NULLIF(v_env->'r4'->>'authorityRecordId','') IS NOT NULL THEN
    SELECT * INTO v_a4 FROM public.authority_records WHERE id=(v_env->'r4'->>'authorityRecordId')::uuid;
    SELECT * INTO v_r4 FROM public.commercial_reality_r4_records WHERE authority_record_id=v_a4.id;
    IF v_r4.id IS NOT NULL THEN SELECT * INTO v_truth FROM public.truth_entity_snapshots WHERE id=v_r4.target_truth_entity_snapshot_id; END IF;
  END IF;
  IF NULLIF(v_env->'r5'->>'authorityRecordId','') IS NOT NULL THEN
    SELECT * INTO v_a5 FROM public.authority_records WHERE id=(v_env->'r5'->>'authorityRecordId')::uuid;
    SELECT * INTO v_r5 FROM public.route_authority_r5_records WHERE authority_record_id=v_a5.id;
  END IF;
  IF NULLIF(v_env->'r6'->>'authorityRecordId','') IS NOT NULL THEN
    SELECT * INTO v_a6 FROM public.authority_records WHERE id=(v_env->'r6'->>'authorityRecordId')::uuid;
    SELECT * INTO v_r6 FROM public.contact_authority_r6_records WHERE authority_record_id=v_a6.id;
  END IF;

  IF v_opp.id IS NOT NULL THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'eventId',e.id,'eventType',e.event_type,'priorWorkflowState',e.prior_workflow_state,'resultingWorkflowState',e.resulting_workflow_state,
      'actorUserId',e.actor_user_id,'reasonCode',e.reason_code,'authorityEnvelopeFingerprint',e.authority_envelope_fingerprint,'occurredAt',e.occurred_at
    ) ORDER BY e.occurred_at DESC,e.id DESC),'[]'::jsonb) INTO v_workflow_events
    FROM (SELECT * FROM public.opportunity_workflow_events WHERE opportunity_id=v_opp.id ORDER BY occurred_at DESC,id DESC LIMIT 50) e;
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'reviewId',r.id,'decision',r.decision,'note',r.note,'reviewerUserId',r.reviewer_user_id,'priorWorkflowState',r.prior_workflow_state,
      'resultingWorkflowState',r.resulting_workflow_state,'authorityEnvelopeFingerprint',r.authority_envelope_fingerprint,'createdAt',r.created_at
    ) ORDER BY r.created_at DESC,r.id DESC),'[]'::jsonb) INTO v_reviews
    FROM (SELECT * FROM public.opportunity_human_reviews WHERE opportunity_id=v_opp.id ORDER BY created_at DESC,id DESC LIMIT 25) r;
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'syncEventId',s.id,'outcomeCode',s.outcome_code,'priorWorkflowState',s.prior_workflow_state,'resultingWorkflowState',s.resulting_workflow_state,
      'authorityEnvelopeFingerprint',s.authority_envelope_fingerprint,'occurredAt',s.occurred_at
    ) ORDER BY s.occurred_at DESC,s.id DESC),'[]'::jsonb) INTO v_sync_events
    FROM (SELECT * FROM public.opportunity_sync_events WHERE opportunity_id=v_opp.id ORDER BY occurred_at DESC,id DESC LIMIT 25) s;
    v_engagement:=public.marketroute_application_engagement_read_v1(v_opp.id,p_at);
  END IF;

  RETURN jsonb_build_object(
    'contractVersion','MRV2-APPLICATION-READ-1.0.0','resourceType','COMPANY_INTELLIGENCE','evaluatedAt',to_jsonb(p_at),
    'profile',v_profile - 'authorityEnvelope',
    'authority',jsonb_build_object(
      'envelope',v_env,'envelopeFingerprint',public.marketroute_authority_envelope_fingerprint_v1(v_env),
      'r4',CASE WHEN v_r4.id IS NULL THEN NULL ELSE jsonb_build_object(
        'recordId',v_r4.id,'authorityRecordId',v_r4.authority_record_id,'decision',v_r4.decision_code,'realityClass',v_r4.reality_class,
        'constitutionKey',v_r4.boundary_constitution_key,'constitutionVersion',v_r4.boundary_constitution_version,
        'boundaries',v_r4.boundaries_json,'inputFingerprint',v_r4.input_fingerprint,'authorityFingerprint',v_r4.authority_fingerprint,
        'referenceTime',v_r4.reference_time,'nextRevalidationAt',v_r4.next_revalidation_at,'validUntil',v_a4.valid_until
      ) END,
      'r5',CASE WHEN v_r5.id IS NULL THEN NULL ELSE jsonb_build_object(
        'recordId',v_r5.id,'authorityRecordId',v_r5.authority_record_id,'parentR4AuthorityRecordId',v_r5.parent_r4_authority_record_id,
        'decision',v_r5.decision_code,'paths',v_r5.paths_json,'openAccessPointIds',v_r5.open_access_point_ids,
        'contactTruthRequiredAccessPointIds',v_r5.contact_truth_required_access_point_ids,'distinctAccessPointCount',v_r5.distinct_access_point_count,
        'relationshipUniverseFingerprint',v_r5.relationship_universe_fingerprint,'inputFingerprint',v_r5.input_fingerprint,'authorityFingerprint',v_r5.authority_fingerprint,
        'referenceTime',v_r5.reference_time,'nextRevalidationAt',v_r5.next_revalidation_at,'validUntil',v_a5.valid_until
      ) END,
      'r6',CASE WHEN v_r6.id IS NULL THEN NULL ELSE jsonb_build_object(
        'recordId',v_r6.id,'authorityRecordId',v_r6.authority_record_id,'parentR5AuthorityRecordId',v_r6.parent_r5_authority_record_id,
        'decision',v_r6.decision_code,'bindings',v_r6.bindings_json,'authorisedPathFingerprints',v_r6.authorised_path_fingerprints,
        'authorisedAccessPointIds',v_r6.authorised_access_point_ids,'researchRequiredAccessPointIds',v_r6.research_required_access_point_ids,
        'distinctAuthorisedAccessPointCount',v_r6.distinct_authorised_access_point_count,'contactClaimUniverseFingerprint',v_r6.contact_claim_universe_fingerprint,
        'inputFingerprint',v_r6.input_fingerprint,'authorityFingerprint',v_r6.authority_fingerprint,
        'referenceTime',v_r6.reference_time,'nextRevalidationAt',v_r6.next_revalidation_at,'validUntil',v_a6.valid_until
      ) END
    ),
    'truth',CASE WHEN v_truth.id IS NULL THEN NULL ELSE jsonb_build_object(
      'snapshotId',v_truth.id,'snapshotFingerprint',v_truth.snapshot_fingerprint,'profileKey',v_truth.profile_key,'profileVersion',v_truth.profile_version,
      'entityState',v_truth.entity_state,'requiredClaimCount',v_truth.required_claim_count,'knownClaimCount',v_truth.known_claim_count,
      'supportedClaimCount',v_truth.supported_claim_count,'contradictedClaimCount',v_truth.contradicted_claim_count,'staleClaimCount',v_truth.stale_claim_count,
      'unresolvedClaimCount',v_truth.unresolved_claim_count,'coverage',v_truth.coverage,'currentCoverage',v_truth.current_coverage,
      'evidenceSufficiency',v_truth.evidence_sufficiency,'freshnessCoverage',v_truth.freshness_coverage,'coherence',v_truth.coherence,
      'truthIndex',v_truth.truth_index,'probabilityState',v_truth.probability_state,'referenceTime',v_truth.reference_time,'nextRevalidationAt',v_truth.next_revalidation_at
    ) END,
    'research',jsonb_build_object(
      'lifecycleState',v_gap->>'lifecycleState','gapSetFingerprint',v_gap->>'gapSetFingerprint','candidates',COALESCE(v_gap->'candidates','[]'::jsonb),
      'policy',COALESCE(v_gap->'policy','{}'::jsonb),'budget',COALESCE(v_gap->'budget','{}'::jsonb)
    ),
    'workflow',jsonb_build_object('opportunityId',v_opp.id,'state',v_opp.workflow_state,'events',v_workflow_events,'humanReviews',v_reviews,'syncEvents',v_sync_events),
    'engagement',v_engagement,
    'actions',jsonb_build_object(
      'canReview',COALESCE((v_profile->>'reviewableNow')::boolean,false),
      'canGenerateEngagement',COALESCE((v_profile->>'executableNow')::boolean,false),
      'canExecute',COALESCE((v_profile->>'executableNow')::boolean,false),
      'requiresResearch',COALESCE(v_profile->>'disposition','') IN ('RESEARCH_REQUIRED','REVALIDATION_REQUIRED')
    )
  );
END $fn$;

CREATE OR REPLACE FUNCTION public.marketroute_application_campaign_read_v1(p_organisation_id uuid,p_campaign_id uuid,p_at timestamptz DEFAULT now())
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE
  v_campaign public.campaigns%ROWTYPE; v_seller public.seller_businesses%ROWTYPE; v_seller_context jsonb; v_profiles jsonb;
  v_policy jsonb; v_budget jsonb; v_engagement_policy text; v_scoped_count int:=0; v_opportunity_count int:=0;
  v_lifecycle_counts jsonb:='{}'::jsonb; v_disposition_counts jsonb:='{}'::jsonb; v_workflow_counts jsonb:='{}'::jsonb;
BEGIN
  PERFORM public.marketroute_require_service_role();
  PERFORM public.marketroute_application_require_current_read_time_v1(p_at);
  SELECT * INTO v_campaign FROM public.campaigns WHERE id=p_campaign_id AND organisation_id=p_organisation_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_APPLICATION_CAMPAIGN_NOT_FOUND'; END IF;
  SELECT * INTO v_seller FROM public.seller_businesses WHERE id=v_campaign.seller_business_id AND organisation_id=p_organisation_id;
  v_seller_context:=public.marketroute_get_current_campaign_seller_context_v1(p_organisation_id,p_campaign_id);
  v_policy:=public.marketroute_research_policy_v1(p_organisation_id,p_campaign_id);
  v_budget:=public.marketroute_research_budget_snapshot_v1(p_organisation_id,p_campaign_id,p_at);
  v_engagement_policy:=public.marketroute_current_engagement_policy_v1(p_organisation_id,p_campaign_id);
  SELECT count(*)::int INTO v_scoped_count FROM public.organisation_company_scopes s WHERE s.organisation_id=p_organisation_id AND s.campaign_id=p_campaign_id AND s.scope_kind='CAMPAIGN';
  SELECT count(*)::int INTO v_opportunity_count FROM public.opportunities o WHERE o.organisation_id=p_organisation_id AND o.campaign_id=p_campaign_id;
  v_profiles:=public.marketroute_list_opportunity_profiles_v1(p_organisation_id,p_campaign_id,p_at);

  WITH scoped_profiles AS MATERIALIZED (
    SELECT public.marketroute_opportunity_profile_v1(s.organisation_id,s.campaign_id,s.company_id,p_at) AS profile
    FROM public.organisation_company_scopes s
    WHERE s.organisation_id=p_organisation_id AND s.campaign_id=p_campaign_id AND s.scope_kind='CAMPAIGN'
  )
  SELECT
    COALESCE((SELECT jsonb_object_agg(lifecycle_state,cnt) FROM (SELECT profile->>'lifecycleState' lifecycle_state,count(*)::int cnt FROM scoped_profiles GROUP BY profile->>'lifecycleState') x),'{}'::jsonb),
    COALESCE((SELECT jsonb_object_agg(disposition,cnt) FROM (SELECT profile->>'disposition' disposition,count(*)::int cnt FROM scoped_profiles GROUP BY profile->>'disposition') y),'{}'::jsonb)
  INTO v_lifecycle_counts,v_disposition_counts;
  SELECT COALESCE(jsonb_object_agg(workflow_state,cnt),'{}'::jsonb) INTO v_workflow_counts FROM (
    SELECT workflow_state,count(*)::int cnt FROM public.opportunities WHERE organisation_id=p_organisation_id AND campaign_id=p_campaign_id GROUP BY workflow_state
  ) w;

  RETURN jsonb_build_object(
    'contractVersion','MRV2-APPLICATION-READ-1.0.0','resourceType','CAMPAIGN','evaluatedAt',to_jsonb(p_at),
    'campaign',jsonb_build_object('campaignId',v_campaign.id,'organisationId',v_campaign.organisation_id,'name',v_campaign.name,'workflowState',v_campaign.workflow_state,'objectiveText',v_campaign.objective_text,'createdAt',v_campaign.created_at,'updatedAt',v_campaign.updated_at),
    'seller',CASE WHEN v_seller.id IS NULL THEN NULL ELSE jsonb_build_object('sellerBusinessId',v_seller.id,'name',v_seller.name,'canonicalDomain',v_seller.canonical_domain,'websiteUrl',v_seller.website_url,'lifecycleState',v_seller.lifecycle_state) END,
    'sellerContext',CASE WHEN v_seller_context IS NULL THEN NULL ELSE jsonb_build_object(
      'selectionId',v_seller_context->'selectionId','genomeSnapshotId',v_seller_context->'genomeSnapshotId','objectiveKey',v_seller_context->'objectiveKey',
      'semanticFingerprint',v_seller_context->'semanticFingerprint','contentFingerprint',v_seller_context->'contentFingerprint'
    ) END,
    'metrics',jsonb_build_object('scopedCompanies',v_scoped_count,'materialisedOpportunities',v_opportunity_count,'lifecycleCounts',v_lifecycle_counts,'dispositionCounts',v_disposition_counts,'workflowCounts',v_workflow_counts),
    'research',jsonb_build_object('policy',v_policy,'budget',v_budget),
    'engagementPolicy',COALESCE(v_engagement_policy,'HUMAN_ONLY'),
    'opportunities',COALESCE(v_profiles,'[]'::jsonb)
  );
END $fn$;

CREATE OR REPLACE FUNCTION public.marketroute_application_command_centre_read_v1(p_organisation_id uuid,p_at timestamptz DEFAULT now())
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_org public.organisations%ROWTYPE; v_campaigns jsonb:='[]'::jsonb; v_campaign public.campaigns%ROWTYPE; v_read jsonb;
BEGIN
  PERFORM public.marketroute_require_service_role();
  PERFORM public.marketroute_application_require_current_read_time_v1(p_at);
  SELECT * INTO v_org FROM public.organisations WHERE id=p_organisation_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_APPLICATION_ORGANISATION_NOT_FOUND'; END IF;
  FOR v_campaign IN SELECT * FROM public.campaigns WHERE organisation_id=p_organisation_id ORDER BY CASE workflow_state WHEN 'ACTIVE' THEN 0 WHEN 'PAUSED' THEN 1 WHEN 'DRAFT' THEN 2 ELSE 3 END,updated_at DESC,id LOOP
    v_read:=public.marketroute_application_campaign_read_v1(p_organisation_id,v_campaign.id,p_at);
    v_campaigns:=v_campaigns||jsonb_build_array(jsonb_build_object(
      'campaign',v_read->'campaign','seller',v_read->'seller','metrics',v_read->'metrics','research',v_read->'research','engagementPolicy',v_read->'engagementPolicy'
    ));
  END LOOP;
  RETURN jsonb_build_object(
    'contractVersion','MRV2-APPLICATION-READ-1.0.0','resourceType','COMMAND_CENTRE','evaluatedAt',to_jsonb(p_at),
    'organisation',jsonb_build_object('organisationId',v_org.id,'name',v_org.name,'slug',v_org.slug,'status',v_org.status),
    'campaigns',v_campaigns
  );
END $fn$;


CREATE OR REPLACE FUNCTION public.marketroute_application_claim_snapshot_in_current_lineage_v1(
  p_organisation_id uuid,p_campaign_id uuid,p_company_id uuid,p_claim_snapshot_id uuid,p_at timestamptz DEFAULT now()
)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE
  v_env jsonb;
  v_r4 public.commercial_reality_r4_records%ROWTYPE;
  v_r5 public.route_authority_r5_records%ROWTYPE;
  v_r6 public.contact_authority_r6_records%ROWTYPE;
  v_entity public.truth_entity_snapshots%ROWTYPE;
BEGIN
  PERFORM public.marketroute_require_service_role();
  PERFORM public.marketroute_application_require_current_read_time_v1(p_at);
  v_env:=public.marketroute_authority_envelope_v1(p_organisation_id,p_campaign_id,p_company_id,p_at);

  IF NULLIF(v_env->'r4'->>'authorityRecordId','') IS NOT NULL THEN
    SELECT * INTO v_r4 FROM public.commercial_reality_r4_records WHERE authority_record_id=(v_env->'r4'->>'authorityRecordId')::uuid;
    IF v_r4.id IS NOT NULL THEN
      SELECT * INTO v_entity FROM public.truth_entity_snapshots WHERE id=v_r4.target_truth_entity_snapshot_id;
      IF v_entity.id IS NOT NULL AND EXISTS(
        SELECT 1 FROM jsonb_each(v_entity.claim_snapshot_map) kv
        CROSS JOIN LATERAL jsonb_array_elements_text(kv.value) sid(value)
        WHERE sid.value=p_claim_snapshot_id::text
      ) THEN RETURN true; END IF;
      IF EXISTS(
        SELECT 1 FROM jsonb_each(v_r4.constraint_truth_snapshot_map) kv
        CROSS JOIN LATERAL jsonb_array_elements_text(kv.value) sid(value)
        WHERE sid.value=p_claim_snapshot_id::text
      ) THEN RETURN true; END IF;
    END IF;
  END IF;

  IF NULLIF(v_env->'r5'->>'authorityRecordId','') IS NOT NULL THEN
    SELECT * INTO v_r5 FROM public.route_authority_r5_records WHERE authority_record_id=(v_env->'r5'->>'authorityRecordId')::uuid;
    IF v_r5.id IS NOT NULL AND EXISTS(
      SELECT 1 FROM jsonb_each_text(v_r5.relationship_truth_snapshot_map) kv(key,value)
      WHERE kv.value=p_claim_snapshot_id::text
    ) THEN RETURN true; END IF;
  END IF;

  IF NULLIF(v_env->'r6'->>'authorityRecordId','') IS NOT NULL THEN
    SELECT * INTO v_r6 FROM public.contact_authority_r6_records WHERE authority_record_id=(v_env->'r6'->>'authorityRecordId')::uuid;
    IF v_r6.id IS NOT NULL AND EXISTS(
      SELECT 1 FROM jsonb_each_text(v_r6.contact_truth_snapshot_map) kv(key,value)
      WHERE kv.value=p_claim_snapshot_id::text
    ) THEN RETURN true; END IF;
  END IF;

  RETURN false;
END $fn$;

CREATE OR REPLACE FUNCTION public.marketroute_application_claim_provenance_read_v1(
  p_organisation_id uuid,p_campaign_id uuid,p_company_id uuid,p_claim_snapshot_id uuid,p_at timestamptz DEFAULT now()
)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE
  v_snapshot public.truth_claim_snapshots%ROWTYPE;
  v_claim public.claims%ROWTYPE;
  v_evidence jsonb:='[]'::jsonb;
  v_total int:=0;
BEGIN
  PERFORM public.marketroute_require_service_role();
  PERFORM public.marketroute_application_require_current_read_time_v1(p_at);
  IF NOT public.marketroute_application_claim_snapshot_in_current_lineage_v1(p_organisation_id,p_campaign_id,p_company_id,p_claim_snapshot_id,p_at) THEN
    RAISE EXCEPTION 'MARKETROUTE_APPLICATION_PROVENANCE_NOT_IN_CURRENT_LINEAGE';
  END IF;
  SELECT * INTO v_snapshot FROM public.truth_claim_snapshots WHERE id=p_claim_snapshot_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_APPLICATION_PROVENANCE_SNAPSHOT_NOT_FOUND'; END IF;
  SELECT * INTO v_claim FROM public.claims WHERE id=v_snapshot.claim_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_APPLICATION_PROVENANCE_CLAIM_NOT_FOUND'; END IF;

  IF v_claim.tenant_scope_organisation_id IS NOT NULL AND v_claim.tenant_scope_organisation_id<>p_organisation_id THEN
    RAISE EXCEPTION 'MARKETROUTE_APPLICATION_PROVENANCE_TENANT_MISMATCH';
  END IF;

  SELECT count(*)::int INTO v_total FROM public.claim_evidence_links l WHERE l.claim_id=v_claim.id;
  SELECT COALESCE(jsonb_agg(row_payload ORDER BY observed_at DESC,evidence_id DESC),'[]'::jsonb) INTO v_evidence FROM (
    SELECT e.observed_at,e.id evidence_id,jsonb_build_object(
      'evidenceId',e.id,
      'polarity',l.polarity,
      'dependenceFamilyKey',l.dependence_family_key,
      'evidenceKind',e.evidence_kind,
      'excerpt',e.excerpt_text,
      'structuredValue',e.structured_value_json,
      'observedAt',e.observed_at,
      'originPublishedAt',e.origin_published_at,
      'extractionMethod',e.extraction_method,
      'extractionVersion',e.extraction_version,
      'evidenceFingerprint',e.evidence_fingerprint,
      'temporalAnomalyAtSnapshot',(e.observed_at>v_snapshot.reference_time+interval '5 minutes' OR COALESCE(e.origin_published_at,s.published_at,e.observed_at)>v_snapshot.reference_time+interval '5 minutes'),
      'source',jsonb_build_object(
        'sourceId',s.id,'sourceKind',s.source_kind,'canonicalUrl',s.canonical_url,'publisherDomain',s.publisher_domain,
        'title',s.title,'publishedAt',s.published_at,'acquisitionId',a.id,'acquiredAt',a.acquired_at,'acquisitionMethod',a.acquisition_method
      )
    ) row_payload
    FROM public.claim_evidence_links l
    JOIN public.evidence_items e ON e.id=l.evidence_item_id
    JOIN public.source_acquisitions a ON a.id=e.acquisition_id
    JOIN public.source_records s ON s.id=a.source_id
    WHERE l.claim_id=v_claim.id
    ORDER BY e.observed_at DESC,e.id DESC
    LIMIT 50
  ) q;

  RETURN jsonb_build_object(
    'contractVersion','MRV2-APPLICATION-READ-1.0.0','resourceType','CLAIM_PROVENANCE','evaluatedAt',to_jsonb(p_at),
    'scope',jsonb_build_object('organisationId',p_organisation_id,'campaignId',p_campaign_id,'companyId',p_company_id),
    'truthSnapshot',jsonb_build_object(
      'snapshotId',v_snapshot.id,'snapshotFingerprint',v_snapshot.snapshot_fingerprint,'claimId',v_snapshot.claim_id,
      'claimKey',v_snapshot.claim_key,'truthState',v_snapshot.truth_state,'evidenceSufficiency',v_snapshot.evidence_sufficiency,
      'supportFamilyCount',v_snapshot.current_support_family_count,'contradictionFamilyCount',v_snapshot.current_contradiction_family_count,
      'staleFamilyCount',v_snapshot.stale_family_count,'temporalAnomalyCount',v_snapshot.temporal_anomaly_count,
      'freshnessCoverage',v_snapshot.freshness_coverage,'probabilityState',v_snapshot.probability_state,
      'referenceTime',v_snapshot.reference_time,'nextRevalidationAt',v_snapshot.next_revalidation_at
    ),
    'claim',jsonb_build_object(
      'claimId',v_claim.id,'subjectType',v_claim.subject_type,'subjectId',v_claim.subject_id,'claimKey',v_claim.claim_key,
      'predicate',v_claim.predicate,'canonicalValue',v_claim.canonical_value_text,'object',v_claim.object_json,
      'propositionFingerprint',v_snapshot.proposition_fingerprint
    ),
    'evidence',v_evidence,
    'evidenceCount',v_total,
    'returnedEvidenceCount',jsonb_array_length(v_evidence),
    'truncated',v_total>jsonb_array_length(v_evidence)
  );
END $fn$;

REVOKE ALL ON FUNCTION public.marketroute_application_require_current_read_time_v1(timestamptz) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_application_engagement_read_v1(uuid,timestamptz) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_application_company_read_v1(uuid,uuid,uuid,timestamptz) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_application_campaign_read_v1(uuid,uuid,timestamptz) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_application_command_centre_read_v1(uuid,timestamptz) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_application_claim_snapshot_in_current_lineage_v1(uuid,uuid,uuid,uuid,timestamptz) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_application_claim_provenance_read_v1(uuid,uuid,uuid,uuid,timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_application_engagement_read_v1(uuid,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_application_company_read_v1(uuid,uuid,uuid,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_application_campaign_read_v1(uuid,uuid,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_application_command_centre_read_v1(uuid,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_application_claim_provenance_read_v1(uuid,uuid,uuid,uuid,timestamptz) TO service_role;

INSERT INTO public.marketroute_schema_releases(release_key,build_number,constitution_version,metadata_json)
VALUES('MARKETROUTE_V2_BUILD13_CANONICAL_APPLICATION_READ_MODEL',13,'MRV2-CONSTITUTION-1.0.0',jsonb_build_object(
  'migration','0016_canonical_application_read_model.sql','new_authority_writer',false,'read_only',true,
  'browser_direct_database_forbidden',true,'current_authority_reused_not_reconstructed',true,'ui_authority_derivation_forbidden',true,'lineage_scoped_provenance_read',true
)) ON CONFLICT(release_key) DO NOTHING;

NOTIFY pgrst,'reload schema';
COMMIT;
