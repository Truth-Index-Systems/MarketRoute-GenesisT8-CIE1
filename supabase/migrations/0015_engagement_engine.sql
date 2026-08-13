BEGIN;

-- MarketRoute V2 Build 12: Engagement Engine
-- Engagement is non-authoritative. Queue and send permission are derived from current R4/R5/R6 + APPROVED workflow.
-- AI may generate language and judge language quality categorically. Numeric diagnostics are telemetry only.

CREATE TABLE public.campaign_engagement_policy_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id uuid NOT NULL UNIQUE,
  organisation_id uuid NOT NULL REFERENCES public.organisations(id) ON DELETE RESTRICT,
  campaign_id uuid NOT NULL,
  actor_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  policy_mode text NOT NULL CHECK (policy_mode IN ('HUMAN_ONLY','AUTOPILOT')),
  policy_version text NOT NULL CHECK (policy_version='MRV2-ENGAGEMENT-POLICY-1.0.0'),
  occurred_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT campaign_engagement_policy_campaign_scope_fk FOREIGN KEY(organisation_id,campaign_id) REFERENCES public.campaigns(organisation_id,id) ON DELETE RESTRICT
);
CREATE INDEX campaign_engagement_policy_scope_time_idx ON public.campaign_engagement_policy_events(organisation_id,campaign_id,occurred_at DESC,id DESC);
CREATE TRIGGER campaign_engagement_policy_events_append_only BEFORE UPDATE OR DELETE ON public.campaign_engagement_policy_events FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

CREATE TABLE public.engagement_strategies (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id uuid NOT NULL UNIQUE,
  opportunity_id uuid NOT NULL,
  organisation_id uuid NOT NULL REFERENCES public.organisations(id) ON DELETE RESTRICT,
  campaign_id uuid NOT NULL,
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  path_fingerprint text NOT NULL CHECK(path_fingerprint ~ '^[a-f0-9]{64}$'),
  access_point_id uuid NOT NULL REFERENCES public.commercial_graph_nodes(id) ON DELETE RESTRICT,
  access_point_kind text NOT NULL,
  access_point_value text NOT NULL CHECK(length(btrim(access_point_value)) BETWEEN 1 AND 2048),
  route_mode text NOT NULL CHECK(route_mode IN ('ORGANISATIONAL_ROUTE','NAMED_CONTACT')),
  person_id uuid REFERENCES public.people(id) ON DELETE RESTRICT,
  channel_kind text NOT NULL CHECK(channel_kind IN ('EMAIL','CONTACT_FORM','LINKEDIN','PHONE','OTHER')),
  strategy_version text NOT NULL CHECK(strategy_version='MRV2-ENGAGEMENT-STRATEGY-1.0.0'),
  generation_context_fingerprint text NOT NULL CHECK(generation_context_fingerprint ~ '^[a-f0-9]{64}$'),
  authority_envelope_fingerprint text NOT NULL CHECK(authority_envelope_fingerprint ~ '^[a-f0-9]{64}$'),
  r6_authority_record_id uuid NOT NULL REFERENCES public.authority_records(id) ON DELETE RESTRICT,
  r6_authority_fingerprint text NOT NULL CHECK(r6_authority_fingerprint ~ '^[a-f0-9]{64}$'),
  strategy_fingerprint text NOT NULL UNIQUE CHECK(strategy_fingerprint ~ '^[a-f0-9]{64}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT engagement_strategies_opportunity_scope_fk FOREIGN KEY(opportunity_id,organisation_id) REFERENCES public.opportunities(id,organisation_id) ON DELETE RESTRICT,
  CONSTRAINT engagement_strategies_campaign_scope_fk FOREIGN KEY(organisation_id,campaign_id) REFERENCES public.campaigns(organisation_id,id) ON DELETE RESTRICT,
  CHECK((route_mode='NAMED_CONTACT' AND person_id IS NOT NULL) OR (route_mode='ORGANISATIONAL_ROUTE' AND person_id IS NULL))
);
CREATE INDEX engagement_strategies_opportunity_idx ON public.engagement_strategies(opportunity_id,created_at DESC);
CREATE TRIGGER engagement_strategies_append_only BEFORE UPDATE OR DELETE ON public.engagement_strategies FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

CREATE TABLE public.engagement_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  generation_request_id uuid NOT NULL UNIQUE,
  strategy_id uuid NOT NULL REFERENCES public.engagement_strategies(id) ON DELETE RESTRICT,
  previous_message_id uuid REFERENCES public.engagement_messages(id) ON DELETE RESTRICT,
  rewrite_ordinal integer NOT NULL CHECK(rewrite_ordinal BETWEEN 0 AND 2),
  generation_contract_version text NOT NULL CHECK(generation_contract_version='MRV2-ENGAGEMENT-GENERATION-1.0.0'),
  generator_version text NOT NULL CHECK(length(btrim(generator_version)) BETWEEN 1 AND 160),
  generation_context_fingerprint text NOT NULL CHECK(generation_context_fingerprint ~ '^[a-f0-9]{64}$'),
  subject_text text CHECK(subject_text IS NULL OR length(btrim(subject_text)) BETWEEN 1 AND 300),
  body_text text NOT NULL CHECK(length(btrim(body_text)) BETWEEN 1 AND 8000),
  message_fingerprint text NOT NULL UNIQUE CHECK(message_fingerprint ~ '^[a-f0-9]{64}$'),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX engagement_messages_strategy_idx ON public.engagement_messages(strategy_id,rewrite_ordinal DESC,created_at DESC);
CREATE TRIGGER engagement_messages_append_only BEFORE UPDATE OR DELETE ON public.engagement_messages FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

CREATE TABLE public.engagement_ai_reviews (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  review_request_id uuid NOT NULL UNIQUE,
  message_id uuid NOT NULL UNIQUE REFERENCES public.engagement_messages(id) ON DELETE RESTRICT,
  review_contract_version text NOT NULL CHECK(review_contract_version='MRV2-ENGAGEMENT-REVIEW-1.0.0'),
  reviewer_version text NOT NULL CHECK(length(btrim(reviewer_version)) BETWEEN 1 AND 160),
  verdict text NOT NULL CHECK(verdict IN ('PASS','REWRITE','BLOCK')),
  reason_codes text[] NOT NULL DEFAULT '{}',
  diagnostics_json jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(diagnostics_json)='object'),
  review_fingerprint text NOT NULL UNIQUE CHECK(review_fingerprint ~ '^[a-f0-9]{64}$'),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX engagement_ai_reviews_verdict_idx ON public.engagement_ai_reviews(verdict,created_at DESC);
CREATE TRIGGER engagement_ai_reviews_append_only BEFORE UPDATE OR DELETE ON public.engagement_ai_reviews FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

CREATE TABLE public.engagement_message_approvals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  approval_request_id uuid NOT NULL UNIQUE,
  message_id uuid NOT NULL REFERENCES public.engagement_messages(id) ON DELETE RESTRICT,
  review_id uuid NOT NULL REFERENCES public.engagement_ai_reviews(id) ON DELETE RESTRICT,
  approval_mode text NOT NULL CHECK(approval_mode IN ('HUMAN','AUTOPILOT')),
  actor_user_id uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  decision text NOT NULL CHECK(decision IN ('APPROVE','REJECT')),
  policy_version text NOT NULL CHECK(policy_version='MRV2-ENGAGEMENT-POLICY-1.0.0'),
  authority_envelope_json jsonb NOT NULL CHECK(jsonb_typeof(authority_envelope_json)='object'),
  authority_envelope_fingerprint text NOT NULL CHECK(authority_envelope_fingerprint ~ '^[a-f0-9]{64}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK((approval_mode='HUMAN' AND actor_user_id IS NOT NULL) OR (approval_mode='AUTOPILOT' AND actor_user_id IS NULL))
);
CREATE INDEX engagement_message_approvals_message_idx ON public.engagement_message_approvals(message_id,created_at DESC,id DESC);
CREATE TRIGGER engagement_message_approvals_append_only BEFORE UPDATE OR DELETE ON public.engagement_message_approvals FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

CREATE TABLE public.engagement_queue_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  queue_request_id uuid NOT NULL UNIQUE,
  opportunity_id uuid NOT NULL,
  organisation_id uuid NOT NULL REFERENCES public.organisations(id) ON DELETE RESTRICT,
  campaign_id uuid NOT NULL,
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  strategy_id uuid NOT NULL REFERENCES public.engagement_strategies(id) ON DELETE RESTRICT,
  message_id uuid NOT NULL UNIQUE REFERENCES public.engagement_messages(id) ON DELETE RESTRICT,
  review_id uuid NOT NULL REFERENCES public.engagement_ai_reviews(id) ON DELETE RESTRICT,
  approval_id uuid NOT NULL REFERENCES public.engagement_message_approvals(id) ON DELETE RESTRICT,
  approval_mode text NOT NULL CHECK(approval_mode IN ('HUMAN','AUTOPILOT')),
  authority_envelope_json jsonb NOT NULL CHECK(jsonb_typeof(authority_envelope_json)='object'),
  authority_envelope_fingerprint text NOT NULL CHECK(authority_envelope_fingerprint ~ '^[a-f0-9]{64}$'),
  queued_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT engagement_queue_items_opportunity_scope_fk FOREIGN KEY(opportunity_id,organisation_id) REFERENCES public.opportunities(id,organisation_id) ON DELETE RESTRICT,
  CONSTRAINT engagement_queue_items_campaign_scope_fk FOREIGN KEY(organisation_id,campaign_id) REFERENCES public.campaigns(organisation_id,id) ON DELETE RESTRICT
);
CREATE INDEX engagement_queue_items_scope_idx ON public.engagement_queue_items(organisation_id,campaign_id,queued_at DESC);
CREATE TRIGGER engagement_queue_items_append_only BEFORE UPDATE OR DELETE ON public.engagement_queue_items FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

CREATE TABLE public.engagement_delivery_jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  queue_item_id uuid NOT NULL UNIQUE REFERENCES public.engagement_queue_items(id) ON DELETE RESTRICT,
  status text NOT NULL DEFAULT 'PENDING' CHECK(status IN ('PENDING','RUNNING','SENT','FAILED','BLOCKED_STALE','RECONCILIATION_REQUIRED')),
  attempt_number integer NOT NULL DEFAULT 0 CHECK(attempt_number BETWEEN 0 AND 1),
  claimed_by text,
  claimed_at timestamptz,
  send_gate_fingerprint text CHECK(send_gate_fingerprint IS NULL OR send_gate_fingerprint ~ '^[a-f0-9]{64}$'),
  last_error_code text,
  finished_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX engagement_delivery_jobs_claim_idx ON public.engagement_delivery_jobs(status,created_at,id);
CREATE TRIGGER engagement_delivery_jobs_touch_updated_at BEFORE UPDATE ON public.engagement_delivery_jobs FOR EACH ROW EXECUTE FUNCTION public.marketroute_touch_updated_at();

CREATE TABLE public.engagement_delivery_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  queue_item_id uuid NOT NULL REFERENCES public.engagement_queue_items(id) ON DELETE RESTRICT,
  job_id uuid NOT NULL REFERENCES public.engagement_delivery_jobs(id) ON DELETE RESTRICT,
  event_type text NOT NULL CHECK(event_type IN ('QUEUED','CLAIMED','SENT','FAILED','BLOCKED_STALE','RECONCILIATION_REQUIRED')),
  worker_id text,
  send_gate_fingerprint text CHECK(send_gate_fingerprint IS NULL OR send_gate_fingerprint ~ '^[a-f0-9]{64}$'),
  provider_message_id text,
  metadata_json jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(metadata_json)='object'),
  occurred_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX engagement_delivery_events_queue_idx ON public.engagement_delivery_events(queue_item_id,occurred_at DESC,id DESC);
CREATE TRIGGER engagement_delivery_events_append_only BEFORE UPDATE OR DELETE ON public.engagement_delivery_events FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

CREATE OR REPLACE FUNCTION public.marketroute_engagement_channel_kind_v1(p_access_point_kind text)
RETURNS text LANGUAGE sql IMMUTABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
 SELECT CASE p_access_point_kind
  WHEN 'GENERIC_EMAIL' THEN 'EMAIL' WHEN 'DEPARTMENT_EMAIL' THEN 'EMAIL' WHEN 'PERSONAL_EMAIL' THEN 'EMAIL'
  WHEN 'CONTACT_FORM' THEN 'CONTACT_FORM' WHEN 'DEPARTMENT_FORM' THEN 'CONTACT_FORM'
  WHEN 'LINKEDIN' THEN 'LINKEDIN'
  WHEN 'SWITCHBOARD' THEN 'PHONE' WHEN 'PERSONAL_PHONE' THEN 'PHONE'
  WHEN 'OTHER' THEN 'OTHER' ELSE NULL END;
$fn$;

CREATE OR REPLACE FUNCTION public.marketroute_current_engagement_policy_v1(p_organisation_id uuid,p_campaign_id uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
 SELECT COALESCE((SELECT e.policy_mode FROM public.campaign_engagement_policy_events e WHERE e.organisation_id=p_organisation_id AND e.campaign_id=p_campaign_id ORDER BY e.occurred_at DESC,e.id DESC LIMIT 1),'HUMAN_ONLY');
$fn$;

CREATE OR REPLACE FUNCTION public.marketroute_record_engagement_policy_v1(
 p_organisation_id uuid,p_campaign_id uuid,p_actor_user_id uuid,p_policy_mode text,p_request_id uuid,p_at timestamptz DEFAULT now()
) RETURNS TABLE(policy_event_id uuid,policy_mode text,deduplicated boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_existing public.campaign_engagement_policy_events%ROWTYPE; v_id uuid;
BEGIN
 PERFORM public.marketroute_require_service_role();
 IF p_request_id IS NULL OR p_actor_user_id IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_POLICY_IDENTITY_REQUIRED'; END IF;
 SELECT * INTO v_existing FROM public.campaign_engagement_policy_events WHERE request_id=p_request_id;
 IF FOUND THEN
  IF v_existing.organisation_id IS DISTINCT FROM p_organisation_id OR v_existing.campaign_id IS DISTINCT FROM p_campaign_id OR v_existing.actor_user_id IS DISTINCT FROM p_actor_user_id OR v_existing.policy_mode IS DISTINCT FROM p_policy_mode THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_POLICY_IDEMPOTENCY_COLLISION'; END IF;
  RETURN QUERY SELECT v_existing.id,v_existing.policy_mode,true; RETURN;
 END IF;
 IF p_at IS NULL OR abs(extract(epoch FROM(now()-p_at)))>300 THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_POLICY_TIME_NOT_CURRENT'; END IF;
 IF p_policy_mode NOT IN('HUMAN_ONLY','AUTOPILOT') THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_POLICY_MODE_INVALID'; END IF;
 PERFORM 1 FROM public.campaigns c WHERE c.id=p_campaign_id AND c.organisation_id=p_organisation_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_POLICY_CAMPAIGN_SCOPE_MISMATCH'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.organisation_memberships m WHERE m.organisation_id=p_organisation_id AND m.user_id=p_actor_user_id AND m.status='ACTIVE' AND m.role IN('OWNER','ADMIN')) THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_POLICY_ACTOR_NOT_AUTHORISED'; END IF;
 IF EXISTS(SELECT 1 FROM public.engagement_delivery_jobs j JOIN public.engagement_queue_items q ON q.id=j.queue_item_id WHERE q.organisation_id=p_organisation_id AND q.campaign_id=p_campaign_id AND j.status='RUNNING') THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_POLICY_CHANGE_BLOCKED_DURING_DELIVERY'; END IF;
 INSERT INTO public.campaign_engagement_policy_events(request_id,organisation_id,campaign_id,actor_user_id,policy_mode,policy_version,occurred_at)
 VALUES(p_request_id,p_organisation_id,p_campaign_id,p_actor_user_id,p_policy_mode,'MRV2-ENGAGEMENT-POLICY-1.0.0',p_at) RETURNING id INTO v_id;
 RETURN QUERY SELECT v_id,p_policy_mode,false;
END $fn$;

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
 IF v_opp.workflow_state<>'APPROVED' THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_REQUIRES_APPROVED_OPPORTUNITY'; END IF;
 IF NOT public.marketroute_opportunity_executable_now_v1(v_opp.id,p_at) THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_REQUIRES_CURRENT_AUTHORITY'; END IF;
 SELECT * INTO v_company FROM public.companies WHERE id=v_opp.company_id;
 IF NOT FOUND OR v_company.lifecycle_state<>'ACTIVE' THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_ACTIVE_TARGET_COMPANY_REQUIRED'; END IF;
 v_env:=public.marketroute_authority_envelope_v1(v_opp.organisation_id,v_opp.campaign_id,v_opp.company_id,p_at); v_envfp:=public.marketroute_authority_envelope_fingerprint_v1(v_env);
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

CREATE OR REPLACE FUNCTION public.marketroute_engagement_generation_context_fingerprint_v1(p_context jsonb)
RETURNS text LANGUAGE sql IMMUTABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
 SELECT encode(extensions.digest('MRV2-ENGAGEMENT-GENERATION-CONTEXT-1.0.0|'||COALESCE(p_context,'{}'::jsonb)::text,'sha256'),'hex');
$fn$;

CREATE OR REPLACE FUNCTION public.marketroute_engagement_strategy_fingerprint_v1(p_context jsonb,p_channel text)
RETURNS text LANGUAGE sql IMMUTABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
 SELECT encode(extensions.digest(concat_ws('|','MRV2-ENGAGEMENT-STRATEGY-FINGERPRINT-1.0.0',
  p_context->>'opportunityId',p_context->>'organisationId',p_context->>'campaignId',p_context->>'companyId',p_context->>'pathFingerprint',p_context->>'accessPointId',p_channel,p_context->>'routeMode',p_context->>'accessPointValue',COALESCE(p_context->>'personId','NONE'),p_context->>'authorityEnvelopeFingerprint',p_context->>'r6AuthorityRecordId',p_context->>'r6AuthorityFingerprint'),'sha256'),'hex');
$fn$;

CREATE OR REPLACE FUNCTION public.marketroute_create_engagement_strategy_v1(
 p_opportunity_id uuid,p_path_fingerprint text,p_request_id uuid,p_context_fingerprint text,p_strategy_fingerprint text,p_strategy_version text,p_at timestamptz DEFAULT now()
) RETURNS TABLE(strategy_id uuid,strategy_fingerprint text,channel_kind text,deduplicated boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_existing public.engagement_strategies%ROWTYPE; v_ctx jsonb; v_ctxfp text; v_channel text; v_expected text; v_id uuid;
BEGIN
 PERFORM public.marketroute_require_service_role(); IF p_request_id IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_STRATEGY_REQUEST_ID_REQUIRED'; END IF;
 SELECT * INTO v_existing FROM public.engagement_strategies WHERE request_id=p_request_id;
 IF FOUND THEN
  IF v_existing.opportunity_id IS DISTINCT FROM p_opportunity_id OR v_existing.path_fingerprint IS DISTINCT FROM p_path_fingerprint OR v_existing.generation_context_fingerprint IS DISTINCT FROM p_context_fingerprint OR v_existing.strategy_fingerprint IS DISTINCT FROM p_strategy_fingerprint THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_STRATEGY_IDEMPOTENCY_COLLISION'; END IF;
  RETURN QUERY SELECT v_existing.id,v_existing.strategy_fingerprint,v_existing.channel_kind,true; RETURN;
 END IF;
 IF p_strategy_version<>'MRV2-ENGAGEMENT-STRATEGY-1.0.0' THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_STRATEGY_VERSION_MISMATCH'; END IF;
 v_ctx:=public.marketroute_engagement_generation_context_v1(p_opportunity_id,p_path_fingerprint,p_at); v_ctxfp:=public.marketroute_engagement_generation_context_fingerprint_v1(v_ctx);
 IF p_context_fingerprint IS DISTINCT FROM v_ctxfp THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_GENERATION_CONTEXT_CHANGED'; END IF;
 v_channel:=public.marketroute_engagement_channel_kind_v1(v_ctx->>'accessPointKind'); v_expected:=public.marketroute_engagement_strategy_fingerprint_v1(v_ctx,v_channel);
 IF p_strategy_fingerprint IS DISTINCT FROM v_expected THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_STRATEGY_FINGERPRINT_MISMATCH'; END IF;
 INSERT INTO public.engagement_strategies(request_id,opportunity_id,organisation_id,campaign_id,company_id,path_fingerprint,access_point_id,access_point_kind,access_point_value,route_mode,person_id,channel_kind,strategy_version,generation_context_fingerprint,authority_envelope_fingerprint,r6_authority_record_id,r6_authority_fingerprint,strategy_fingerprint,created_at)
 VALUES(p_request_id,p_opportunity_id,(v_ctx->>'organisationId')::uuid,(v_ctx->>'campaignId')::uuid,(v_ctx->>'companyId')::uuid,p_path_fingerprint,(v_ctx->>'accessPointId')::uuid,v_ctx->>'accessPointKind',v_ctx->>'accessPointValue',v_ctx->>'routeMode',NULLIF(v_ctx->>'personId','')::uuid,v_channel,p_strategy_version,v_ctxfp,v_ctx->>'authorityEnvelopeFingerprint',(v_ctx->>'r6AuthorityRecordId')::uuid,v_ctx->>'r6AuthorityFingerprint',v_expected,p_at) RETURNING id INTO v_id;
 RETURN QUERY SELECT v_id,v_expected,v_channel,false;
END $fn$;

CREATE OR REPLACE FUNCTION public.marketroute_engagement_strategy_current_v1(p_strategy_id uuid,p_at timestamptz DEFAULT now())
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_strategy public.engagement_strategies%ROWTYPE; v_ctx jsonb; v_fp text;
BEGIN
 SELECT * INTO v_strategy FROM public.engagement_strategies WHERE id=p_strategy_id; IF NOT FOUND THEN RETURN false; END IF;
 IF NOT public.marketroute_opportunity_executable_now_v1(v_strategy.opportunity_id,p_at) THEN RETURN false; END IF;
 BEGIN
  v_ctx:=public.marketroute_engagement_generation_context_v1(v_strategy.opportunity_id,v_strategy.path_fingerprint,p_at);
  v_fp:=public.marketroute_engagement_generation_context_fingerprint_v1(v_ctx);
 EXCEPTION WHEN OTHERS THEN RETURN false;
 END;
 RETURN v_fp=v_strategy.generation_context_fingerprint AND v_ctx->>'authorityEnvelopeFingerprint'=v_strategy.authority_envelope_fingerprint AND v_ctx->>'r6AuthorityRecordId'=v_strategy.r6_authority_record_id::text AND v_ctx->>'r6AuthorityFingerprint'=v_strategy.r6_authority_fingerprint AND v_ctx->>'accessPointId'=v_strategy.access_point_id::text;
END $fn$;

CREATE OR REPLACE FUNCTION public.marketroute_record_engagement_message_v1(
 p_strategy_id uuid,p_previous_message_id uuid,p_request_id uuid,p_context_fingerprint text,p_generation_contract_version text,p_generator_version text,p_subject_text text,p_body_text text,p_at timestamptz DEFAULT now()
) RETURNS TABLE(message_id uuid,message_fingerprint text,deduplicated boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_existing public.engagement_messages%ROWTYPE; v_strategy public.engagement_strategies%ROWTYPE; v_prev public.engagement_messages%ROWTYPE; v_ordinal int:=0; v_subject text; v_body text; v_fp text; v_id uuid;
BEGIN
 PERFORM public.marketroute_require_service_role(); IF p_request_id IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_MESSAGE_REQUEST_ID_REQUIRED'; END IF;
 SELECT * INTO v_existing FROM public.engagement_messages WHERE generation_request_id=p_request_id;
 IF FOUND THEN
  IF v_existing.strategy_id IS DISTINCT FROM p_strategy_id OR v_existing.previous_message_id IS DISTINCT FROM p_previous_message_id OR v_existing.generation_context_fingerprint IS DISTINCT FROM p_context_fingerprint OR v_existing.generator_version IS DISTINCT FROM btrim(p_generator_version) OR v_existing.subject_text IS DISTINCT FROM NULLIF(btrim(p_subject_text),'') OR v_existing.body_text IS DISTINCT FROM btrim(p_body_text) THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_MESSAGE_IDEMPOTENCY_COLLISION'; END IF;
  RETURN QUERY SELECT v_existing.id,v_existing.message_fingerprint,true; RETURN;
 END IF;
 IF p_at IS NULL OR abs(extract(epoch FROM(now()-p_at)))>300 THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_MESSAGE_TIME_NOT_CURRENT'; END IF;
 IF p_generation_contract_version<>'MRV2-ENGAGEMENT-GENERATION-1.0.0' THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_GENERATION_CONTRACT_MISMATCH'; END IF;
 IF length(btrim(COALESCE(p_generator_version,''))) NOT BETWEEN 1 AND 160 THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_GENERATOR_VERSION_INVALID'; END IF;
 SELECT * INTO v_strategy FROM public.engagement_strategies WHERE id=p_strategy_id; IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_STRATEGY_NOT_FOUND'; END IF;
 IF p_context_fingerprint IS DISTINCT FROM v_strategy.generation_context_fingerprint OR NOT public.marketroute_engagement_strategy_current_v1(v_strategy.id,p_at) THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_STRATEGY_NOT_CURRENT'; END IF;
 v_subject:=NULLIF(btrim(p_subject_text),''); v_body:=btrim(COALESCE(p_body_text,'')); IF length(v_body) NOT BETWEEN 1 AND 8000 THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_BODY_INVALID'; END IF;
 IF v_strategy.channel_kind='EMAIL' THEN IF v_subject IS NULL OR length(v_subject)>300 THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_EMAIL_SUBJECT_REQUIRED'; END IF; ELSE IF v_subject IS NOT NULL THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_NON_EMAIL_SUBJECT_FORBIDDEN'; END IF; END IF;
 IF p_previous_message_id IS NOT NULL THEN SELECT * INTO v_prev FROM public.engagement_messages WHERE id=p_previous_message_id; IF NOT FOUND OR v_prev.strategy_id<>p_strategy_id THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_REWRITE_PARENT_INVALID'; END IF; v_ordinal:=v_prev.rewrite_ordinal+1; END IF;
 IF v_ordinal>2 THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_REWRITE_LIMIT_EXCEEDED'; END IF;
 IF EXISTS(SELECT 1 FROM public.engagement_messages m WHERE m.strategy_id=p_strategy_id AND m.rewrite_ordinal=v_ordinal) THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_REWRITE_ORDINAL_ALREADY_EXISTS'; END IF;
 v_fp:=encode(extensions.digest(concat_ws('|','MRV2-ENGAGEMENT-MESSAGE-1.0.0',v_strategy.strategy_fingerprint,octet_length(COALESCE(v_subject,''))::text,COALESCE(v_subject,''),octet_length(v_body)::text,v_body),'sha256'),'hex');
 INSERT INTO public.engagement_messages(generation_request_id,strategy_id,previous_message_id,rewrite_ordinal,generation_contract_version,generator_version,generation_context_fingerprint,subject_text,body_text,message_fingerprint,created_at)
 VALUES(p_request_id,p_strategy_id,p_previous_message_id,v_ordinal,p_generation_contract_version,btrim(p_generator_version),p_context_fingerprint,v_subject,v_body,v_fp,p_at) RETURNING id INTO v_id;
 RETURN QUERY SELECT v_id,v_fp,false;
END $fn$;

CREATE OR REPLACE FUNCTION public.marketroute_record_engagement_ai_review_v1(
 p_message_id uuid,p_request_id uuid,p_review_contract_version text,p_reviewer_version text,p_verdict text,p_reason_codes text[],p_diagnostics_json jsonb,p_at timestamptz DEFAULT now()
) RETURNS TABLE(review_id uuid,verdict text,review_fingerprint text,deduplicated boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_existing public.engagement_ai_reviews%ROWTYPE; v_message public.engagement_messages%ROWTYPE; v_reasons text[]; v_diag jsonb:=COALESCE(p_diagnostics_json,'{}'::jsonb); v_fp text; v_id uuid;
BEGIN
 PERFORM public.marketroute_require_service_role(); IF p_request_id IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_REVIEW_REQUEST_ID_REQUIRED'; END IF;
 SELECT * INTO v_existing FROM public.engagement_ai_reviews WHERE review_request_id=p_request_id;
 IF FOUND THEN
  IF v_existing.message_id IS DISTINCT FROM p_message_id OR v_existing.reviewer_version IS DISTINCT FROM btrim(p_reviewer_version) OR v_existing.verdict IS DISTINCT FROM p_verdict THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_REVIEW_IDEMPOTENCY_COLLISION'; END IF;
  RETURN QUERY SELECT v_existing.id,v_existing.verdict,v_existing.review_fingerprint,true; RETURN;
 END IF;
 IF EXISTS(SELECT 1 FROM public.engagement_ai_reviews WHERE message_id=p_message_id) THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_MESSAGE_ALREADY_REVIEWED'; END IF;
 IF p_at IS NULL OR abs(extract(epoch FROM(now()-p_at)))>300 THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_REVIEW_TIME_NOT_CURRENT'; END IF;
 IF p_review_contract_version<>'MRV2-ENGAGEMENT-REVIEW-1.0.0' OR p_verdict NOT IN('PASS','REWRITE','BLOCK') THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_REVIEW_CONTRACT_INVALID'; END IF;
 IF length(btrim(COALESCE(p_reviewer_version,''))) NOT BETWEEN 1 AND 160 THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_REVIEWER_VERSION_INVALID'; END IF;
 IF jsonb_typeof(v_diag)<>'object' THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_REVIEW_DIAGNOSTICS_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_each(v_diag) d(key,value) WHERE d.key !~ '^[A-Za-z][A-Za-z0-9_.-]{0,79}$' OR d.key ~* '(authority|executionpermission|commercialviability|routeauthority|contactauthority)' OR jsonb_typeof(d.value) NOT IN('string','number','boolean','null')) THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_REVIEW_DIAGNOSTIC_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM unnest(COALESCE(p_reason_codes,'{}'::text[])) x WHERE x IS NULL) THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_REVIEW_REASON_INVALID'; END IF;
 SELECT COALESCE(array_agg(DISTINCT upper(btrim(x)) ORDER BY upper(btrim(x))),'{}'::text[]) INTO v_reasons FROM unnest(COALESCE(p_reason_codes,'{}'::text[])) x;
 IF EXISTS(SELECT 1 FROM unnest(v_reasons) x WHERE x !~ '^[A-Z0-9][A-Z0-9_:-]{0,95}$') THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_REVIEW_REASON_INVALID'; END IF;
 IF p_verdict<>'PASS' AND cardinality(v_reasons)=0 THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_NONPASS_REASON_REQUIRED'; END IF;
 SELECT * INTO v_message FROM public.engagement_messages WHERE id=p_message_id; IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_MESSAGE_NOT_FOUND'; END IF;
 IF NOT public.marketroute_engagement_strategy_current_v1(v_message.strategy_id,p_at) THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_REVIEW_STRATEGY_NOT_CURRENT'; END IF;
 v_fp:=encode(extensions.digest(concat_ws('|','MRV2-ENGAGEMENT-REVIEW-1.0.0',v_message.message_fingerprint,p_review_contract_version,btrim(p_reviewer_version),p_verdict,to_jsonb(v_reasons)::text,v_diag::text),'sha256'),'hex');
 INSERT INTO public.engagement_ai_reviews(review_request_id,message_id,review_contract_version,reviewer_version,verdict,reason_codes,diagnostics_json,review_fingerprint,created_at)
 VALUES(p_request_id,p_message_id,p_review_contract_version,btrim(p_reviewer_version),p_verdict,v_reasons,v_diag,v_fp,p_at) RETURNING id INTO v_id;
 RETURN QUERY SELECT v_id,p_verdict,v_fp,false;
END $fn$;

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
 v_env:=public.marketroute_authority_envelope_v1(v_strategy.organisation_id,v_strategy.campaign_id,v_strategy.company_id,p_at); v_envfp:=public.marketroute_authority_envelope_fingerprint_v1(v_env);
 INSERT INTO public.engagement_message_approvals(approval_request_id,message_id,review_id,approval_mode,actor_user_id,decision,policy_version,authority_envelope_json,authority_envelope_fingerprint,created_at)
 VALUES(p_request_id,p_message_id,v_review.id,'HUMAN',p_actor_user_id,p_decision,'MRV2-ENGAGEMENT-POLICY-1.0.0',v_env,v_envfp,p_at) RETURNING id INTO v_id;
 RETURN QUERY SELECT v_id,p_decision,'HUMAN'::text,false;
END $fn$;

CREATE OR REPLACE FUNCTION public.marketroute_queue_engagement_v1(p_message_id uuid,p_request_id uuid,p_at timestamptz DEFAULT now())
RETURNS TABLE(queue_item_id uuid,job_id uuid,approval_mode text,deduplicated boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_existing public.engagement_queue_items%ROWTYPE; v_message public.engagement_messages%ROWTYPE; v_strategy public.engagement_strategies%ROWTYPE; v_review public.engagement_ai_reviews%ROWTYPE; v_approval public.engagement_message_approvals%ROWTYPE; v_policy text; v_env jsonb; v_envfp text; v_queue uuid; v_job uuid; v_auto uuid;
BEGIN
 PERFORM public.marketroute_require_service_role(); IF p_request_id IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_QUEUE_REQUEST_ID_REQUIRED'; END IF;
 SELECT * INTO v_existing FROM public.engagement_queue_items WHERE queue_request_id=p_request_id;
 IF FOUND THEN IF v_existing.message_id IS DISTINCT FROM p_message_id THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_QUEUE_IDEMPOTENCY_COLLISION'; END IF; SELECT id INTO v_job FROM public.engagement_delivery_jobs WHERE queue_item_id=v_existing.id; RETURN QUERY SELECT v_existing.id,v_job,v_existing.approval_mode,true; RETURN; END IF;
 IF EXISTS(SELECT 1 FROM public.engagement_queue_items WHERE message_id=p_message_id) THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_MESSAGE_ALREADY_QUEUED'; END IF;
 IF p_at IS NULL OR abs(extract(epoch FROM(now()-p_at)))>300 THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_QUEUE_TIME_NOT_CURRENT'; END IF;
 SELECT * INTO v_message FROM public.engagement_messages WHERE id=p_message_id; IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_MESSAGE_NOT_FOUND'; END IF; SELECT * INTO v_strategy FROM public.engagement_strategies WHERE id=v_message.strategy_id;
 IF NOT public.marketroute_engagement_strategy_current_v1(v_strategy.id,p_at) THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_QUEUE_STRATEGY_NOT_CURRENT'; END IF;
 SELECT * INTO v_review FROM public.engagement_ai_reviews WHERE message_id=p_message_id; IF NOT FOUND OR v_review.verdict<>'PASS' OR v_review.review_contract_version<>'MRV2-ENGAGEMENT-REVIEW-1.0.0' THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_QUEUE_REQUIRES_CATEGORICAL_PASS'; END IF;
 v_policy:=public.marketroute_current_engagement_policy_v1(v_strategy.organisation_id,v_strategy.campaign_id);
 IF v_policy='HUMAN_ONLY' THEN SELECT * INTO v_approval FROM public.engagement_message_approvals WHERE message_id=p_message_id AND approval_mode='HUMAN' ORDER BY created_at DESC,id DESC LIMIT 1; IF v_approval.id IS NULL OR v_approval.decision<>'APPROVE' THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_QUEUE_REQUIRES_HUMAN_APPROVAL'; END IF;
 ELSE
  v_env:=public.marketroute_authority_envelope_v1(v_strategy.organisation_id,v_strategy.campaign_id,v_strategy.company_id,p_at); v_envfp:=public.marketroute_authority_envelope_fingerprint_v1(v_env); v_auto:=gen_random_uuid();
  INSERT INTO public.engagement_message_approvals(approval_request_id,message_id,review_id,approval_mode,actor_user_id,decision,policy_version,authority_envelope_json,authority_envelope_fingerprint,created_at)
  VALUES(v_auto,p_message_id,v_review.id,'AUTOPILOT',NULL,'APPROVE','MRV2-ENGAGEMENT-POLICY-1.0.0',v_env,v_envfp,p_at) RETURNING * INTO v_approval;
 END IF;
 v_env:=public.marketroute_authority_envelope_v1(v_strategy.organisation_id,v_strategy.campaign_id,v_strategy.company_id,p_at); v_envfp:=public.marketroute_authority_envelope_fingerprint_v1(v_env);
 IF v_envfp IS DISTINCT FROM v_strategy.authority_envelope_fingerprint OR NOT public.marketroute_opportunity_executable_now_v1(v_strategy.opportunity_id,p_at) THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_QUEUE_AUTHORITY_CHANGED'; END IF;
 INSERT INTO public.engagement_queue_items(queue_request_id,opportunity_id,organisation_id,campaign_id,company_id,strategy_id,message_id,review_id,approval_id,approval_mode,authority_envelope_json,authority_envelope_fingerprint,queued_at)
 VALUES(p_request_id,v_strategy.opportunity_id,v_strategy.organisation_id,v_strategy.campaign_id,v_strategy.company_id,v_strategy.id,v_message.id,v_review.id,v_approval.id,v_approval.approval_mode,v_env,v_envfp,p_at) RETURNING id INTO v_queue;
 INSERT INTO public.engagement_delivery_jobs(queue_item_id,status,attempt_number,created_at,updated_at) VALUES(v_queue,'PENDING',0,p_at,p_at) RETURNING id INTO v_job;
 INSERT INTO public.engagement_delivery_events(queue_item_id,job_id,event_type,metadata_json,occurred_at) VALUES(v_queue,v_job,'QUEUED',jsonb_build_object('approvalMode',v_approval.approval_mode,'reviewVerdict',v_review.verdict),p_at);
 RETURN QUERY SELECT v_queue,v_job,v_approval.approval_mode,false;
END $fn$;

CREATE OR REPLACE FUNCTION public.marketroute_engagement_send_gate_v1(p_queue_item_id uuid,p_at timestamptz DEFAULT now())
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_queue public.engagement_queue_items%ROWTYPE; v_message public.engagement_messages%ROWTYPE; v_strategy public.engagement_strategies%ROWTYPE; v_review public.engagement_ai_reviews%ROWTYPE; v_approval public.engagement_message_approvals%ROWTYPE; v_policy text; v_env jsonb; v_envfp text; v_allowed boolean:=false; v_reason text:='UNKNOWN'; v_fp text;
BEGIN
 PERFORM public.marketroute_require_service_role(); IF p_at IS NULL OR abs(extract(epoch FROM(now()-p_at)))>300 THEN RETURN jsonb_build_object('allowed',false,'reasonCode','SEND_GATE_TIME_NOT_CURRENT'); END IF; SELECT * INTO v_queue FROM public.engagement_queue_items WHERE id=p_queue_item_id; IF NOT FOUND THEN RETURN jsonb_build_object('allowed',false,'reasonCode','QUEUE_ITEM_NOT_FOUND'); END IF;
 SELECT * INTO v_message FROM public.engagement_messages WHERE id=v_queue.message_id; SELECT * INTO v_strategy FROM public.engagement_strategies WHERE id=v_queue.strategy_id; SELECT * INTO v_review FROM public.engagement_ai_reviews WHERE id=v_queue.review_id; SELECT * INTO v_approval FROM public.engagement_message_approvals WHERE id=v_queue.approval_id;
 IF NOT public.marketroute_opportunity_executable_now_v1(v_queue.opportunity_id,p_at) THEN v_reason:='OPPORTUNITY_NOT_EXECUTABLE_NOW';
 ELSIF NOT public.marketroute_engagement_strategy_current_v1(v_strategy.id,p_at) THEN v_reason:='STRATEGY_AUTHORITY_STALE';
 ELSIF v_review.verdict<>'PASS' OR v_review.review_contract_version<>'MRV2-ENGAGEMENT-REVIEW-1.0.0' THEN v_reason:='CATEGORICAL_PASS_REQUIRED';
 ELSE
  IF v_queue.approval_mode='HUMAN' THEN
   SELECT * INTO v_approval FROM public.engagement_message_approvals a WHERE a.message_id=v_queue.message_id AND a.approval_mode='HUMAN' ORDER BY a.created_at DESC,a.id DESC LIMIT 1;
  END IF;
  IF v_approval.id IS NULL OR v_approval.decision<>'APPROVE' THEN v_reason:='MESSAGE_APPROVAL_REQUIRED';
  ELSE
  v_policy:=public.marketroute_current_engagement_policy_v1(v_queue.organisation_id,v_queue.campaign_id);
  IF v_approval.approval_mode='AUTOPILOT' AND v_policy<>'AUTOPILOT' THEN v_reason:='AUTOPILOT_POLICY_REVOKED';
  ELSE
   v_env:=public.marketroute_authority_envelope_v1(v_queue.organisation_id,v_queue.campaign_id,v_queue.company_id,p_at); v_envfp:=public.marketroute_authority_envelope_fingerprint_v1(v_env);
   IF v_envfp IS DISTINCT FROM v_strategy.authority_envelope_fingerprint OR v_queue.authority_envelope_fingerprint IS DISTINCT FROM v_strategy.authority_envelope_fingerprint THEN v_reason:='AUTHORITY_ENVELOPE_CHANGED'; ELSE v_allowed:=true;v_reason:='SEND_GATE_OPEN'; END IF;
  END IF;
  END IF;
 END IF;
 v_fp:=encode(extensions.digest(concat_ws('|','MRV2-ENGAGEMENT-SEND-GATE-1.0.0',v_queue.id::text,COALESCE(v_strategy.strategy_fingerprint,''),COALESCE(v_message.message_fingerprint,''),COALESCE(v_review.review_fingerprint,''),COALESCE(v_approval.id::text,''),COALESCE(v_policy,''),COALESCE(v_envfp,''),v_allowed::text,v_reason),'sha256'),'hex');
 RETURN jsonb_build_object('allowed',v_allowed,'reasonCode',v_reason,'sendGateFingerprint',v_fp,'authorityEnvelopeFingerprint',v_envfp,'currentApprovalId',CASE WHEN v_approval.id IS NULL THEN NULL ELSE v_approval.id::text END,'currentApprovalMode',v_approval.approval_mode,
  'deliveryPayload',CASE WHEN v_allowed THEN jsonb_build_object('queueItemId',v_queue.id::text,'idempotencyKey',v_queue.id::text,'channel',v_strategy.channel_kind,'accessPointValue',v_strategy.access_point_value,'subjectText',v_message.subject_text,'bodyText',v_message.body_text) ELSE NULL END);
END $fn$;

CREATE OR REPLACE FUNCTION public.marketroute_recover_abandoned_engagement_delivery_v1(p_at timestamptz DEFAULT now())
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_count int:=0; r record;
BEGIN
 PERFORM public.marketroute_require_service_role(); IF p_at IS NULL OR abs(extract(epoch FROM(now()-p_at)))>300 THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_RECOVERY_TIME_NOT_CURRENT'; END IF;
 FOR r IN SELECT j.* FROM public.engagement_delivery_jobs j WHERE j.status='RUNNING' AND j.claimed_at < p_at-interval '10 minutes' FOR UPDATE SKIP LOCKED LOOP
  UPDATE public.engagement_delivery_jobs SET status='RECONCILIATION_REQUIRED',finished_at=p_at,last_error_code='ABANDONED_IN_FLIGHT_DELIVERY_STATUS_UNKNOWN' WHERE id=r.id;
  INSERT INTO public.engagement_delivery_events(queue_item_id,job_id,event_type,worker_id,send_gate_fingerprint,metadata_json,occurred_at) VALUES(r.queue_item_id,r.id,'RECONCILIATION_REQUIRED',r.claimed_by,r.send_gate_fingerprint,jsonb_build_object('reason','ABANDONED_RUNNING_DELIVERY_MAY_HAVE_SENT'),p_at); v_count:=v_count+1;
 END LOOP; RETURN v_count;
END $fn$;

CREATE OR REPLACE FUNCTION public.marketroute_claim_engagement_delivery_v1(p_worker_id text,p_at timestamptz DEFAULT now())
RETURNS TABLE(queue_item_id uuid,job_id uuid,attempt_number integer,send_gate_fingerprint text,delivery_payload jsonb)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_job public.engagement_delivery_jobs%ROWTYPE; v_queue public.engagement_queue_items%ROWTYPE; v_gate jsonb;
BEGIN
 PERFORM public.marketroute_require_service_role(); IF p_at IS NULL OR abs(extract(epoch FROM(now()-p_at)))>300 THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_CLAIM_TIME_NOT_CURRENT'; END IF; IF length(btrim(COALESCE(p_worker_id,''))) NOT BETWEEN 1 AND 160 THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_WORKER_ID_INVALID'; END IF; PERFORM public.marketroute_recover_abandoned_engagement_delivery_v1(p_at);
 SELECT j.* INTO v_job
 FROM public.engagement_delivery_jobs j
 JOIN public.engagement_queue_items q ON q.id=j.queue_item_id
 WHERE j.status='PENDING'
   AND NOT EXISTS(SELECT 1 FROM public.engagement_delivery_jobs running JOIN public.engagement_queue_items rq ON rq.id=running.queue_item_id WHERE rq.opportunity_id=q.opportunity_id AND running.status='RUNNING')
   AND NOT EXISTS(SELECT 1 FROM public.engagement_delivery_jobs older JOIN public.engagement_queue_items oq ON oq.id=older.queue_item_id WHERE oq.opportunity_id=q.opportunity_id AND older.status='PENDING' AND (older.created_at,older.id)<(j.created_at,j.id))
 ORDER BY j.created_at,j.id FOR UPDATE OF j SKIP LOCKED LIMIT 1;
 IF NOT FOUND THEN RETURN; END IF;
 SELECT * INTO v_queue FROM public.engagement_queue_items WHERE id=v_job.queue_item_id;
 PERFORM 1 FROM public.campaigns c WHERE c.id=v_queue.campaign_id AND c.organisation_id=v_queue.organisation_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_DELIVERY_CAMPAIGN_NOT_FOUND'; END IF;
 PERFORM 1 FROM public.opportunities WHERE id=v_queue.opportunity_id FOR UPDATE;
 IF EXISTS(SELECT 1 FROM public.engagement_delivery_jobs other JOIN public.engagement_queue_items oq ON oq.id=other.queue_item_id WHERE oq.opportunity_id=v_queue.opportunity_id AND other.status='RUNNING' AND other.id<>v_job.id) THEN RETURN; END IF;
 v_gate:=public.marketroute_engagement_send_gate_v1(v_job.queue_item_id,p_at);
 IF COALESCE((v_gate->>'allowed')::boolean,false) IS NOT TRUE THEN
  UPDATE public.engagement_delivery_jobs SET status='BLOCKED_STALE',finished_at=p_at,last_error_code=v_gate->>'reasonCode' WHERE id=v_job.id;
  INSERT INTO public.engagement_delivery_events(queue_item_id,job_id,event_type,worker_id,send_gate_fingerprint,metadata_json,occurred_at) VALUES(v_job.queue_item_id,v_job.id,'BLOCKED_STALE',p_worker_id,v_gate->>'sendGateFingerprint',jsonb_build_object('reasonCode',v_gate->>'reasonCode'),p_at); RETURN;
 END IF;
 UPDATE public.engagement_delivery_jobs SET status='RUNNING',attempt_number=1,claimed_by=p_worker_id,claimed_at=p_at,send_gate_fingerprint=v_gate->>'sendGateFingerprint',last_error_code=NULL WHERE id=v_job.id RETURNING * INTO v_job;
 INSERT INTO public.engagement_delivery_events(queue_item_id,job_id,event_type,worker_id,send_gate_fingerprint,metadata_json,occurred_at) VALUES(v_job.queue_item_id,v_job.id,'CLAIMED',p_worker_id,v_job.send_gate_fingerprint,jsonb_build_object('authorityEnvelopeFingerprint',v_gate->>'authorityEnvelopeFingerprint','currentApprovalId',v_gate->>'currentApprovalId','currentApprovalMode',v_gate->>'currentApprovalMode'),p_at);
 RETURN QUERY SELECT v_job.queue_item_id,v_job.id,v_job.attempt_number,v_job.send_gate_fingerprint,v_gate->'deliveryPayload';
END $fn$;

CREATE OR REPLACE FUNCTION public.marketroute_complete_engagement_delivery_v1(p_queue_item_id uuid,p_worker_id text,p_provider_message_id text,p_provider_metadata_json jsonb,p_at timestamptz DEFAULT now())
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_job public.engagement_delivery_jobs%ROWTYPE; v_queue public.engagement_queue_items%ROWTYPE; v_opp public.opportunities%ROWTYPE; v_request uuid:=gen_random_uuid();
BEGIN
 PERFORM public.marketroute_require_service_role(); IF p_at IS NULL OR abs(extract(epoch FROM(now()-p_at)))>300 THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_COMPLETE_TIME_NOT_CURRENT'; END IF; SELECT * INTO v_job FROM public.engagement_delivery_jobs WHERE queue_item_id=p_queue_item_id FOR UPDATE; IF NOT FOUND OR v_job.status<>'RUNNING' OR v_job.claimed_by IS DISTINCT FROM p_worker_id THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_DELIVERY_CLAIM_MISMATCH'; END IF;
 SELECT * INTO v_queue FROM public.engagement_queue_items WHERE id=p_queue_item_id; SELECT * INTO v_opp FROM public.opportunities WHERE id=v_queue.opportunity_id FOR UPDATE;
 UPDATE public.engagement_delivery_jobs SET status='SENT',finished_at=p_at,last_error_code=NULL WHERE id=v_job.id;
 INSERT INTO public.engagement_delivery_events(queue_item_id,job_id,event_type,worker_id,send_gate_fingerprint,provider_message_id,metadata_json,occurred_at) VALUES(v_queue.id,v_job.id,'SENT',p_worker_id,v_job.send_gate_fingerprint,NULLIF(btrim(p_provider_message_id),''),COALESCE(p_provider_metadata_json,'{}'::jsonb),p_at);
 IF v_opp.workflow_state='APPROVED' THEN
  UPDATE public.opportunities SET workflow_state='ENGAGED',updated_at=p_at WHERE id=v_opp.id;
  INSERT INTO public.opportunity_workflow_events(opportunity_id,organisation_id,event_type,prior_workflow_state,resulting_workflow_state,actor_user_id,request_id,reason_code,authority_envelope_json,authority_envelope_fingerprint,occurred_at)
  VALUES(v_opp.id,v_opp.organisation_id,'ENGAGEMENT','APPROVED','ENGAGED',NULL,v_request,'FIRST_ENGAGEMENT_DELIVERED',v_queue.authority_envelope_json,v_queue.authority_envelope_fingerprint,p_at);
 END IF;
 RETURN true;
END $fn$;

CREATE OR REPLACE FUNCTION public.marketroute_fail_engagement_delivery_v1(p_queue_item_id uuid,p_worker_id text,p_error_code text,p_delivery_state_unknown boolean,p_at timestamptz DEFAULT now())
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_job public.engagement_delivery_jobs%ROWTYPE; v_status text;
BEGIN
 PERFORM public.marketroute_require_service_role(); IF p_at IS NULL OR abs(extract(epoch FROM(now()-p_at)))>300 THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_FAILURE_TIME_NOT_CURRENT'; END IF; SELECT * INTO v_job FROM public.engagement_delivery_jobs WHERE queue_item_id=p_queue_item_id FOR UPDATE; IF NOT FOUND OR v_job.status<>'RUNNING' OR v_job.claimed_by IS DISTINCT FROM p_worker_id THEN RAISE EXCEPTION 'MARKETROUTE_ENGAGEMENT_DELIVERY_CLAIM_MISMATCH'; END IF;
 v_status:=CASE WHEN COALESCE(p_delivery_state_unknown,true) THEN 'RECONCILIATION_REQUIRED' ELSE 'FAILED' END;
 UPDATE public.engagement_delivery_jobs SET status=v_status,finished_at=p_at,last_error_code=left(COALESCE(NULLIF(btrim(p_error_code),''),'MARKETROUTE_ENGAGEMENT_DELIVERY_FAILED'),500) WHERE id=v_job.id;
 INSERT INTO public.engagement_delivery_events(queue_item_id,job_id,event_type,worker_id,send_gate_fingerprint,metadata_json,occurred_at) VALUES(v_job.queue_item_id,v_job.id,v_status,p_worker_id,v_job.send_gate_fingerprint,jsonb_build_object('errorCode',left(COALESCE(p_error_code,'MARKETROUTE_ENGAGEMENT_DELIVERY_FAILED'),500),'deliveryStateUnknown',COALESCE(p_delivery_state_unknown,true)),p_at);
 RETURN v_status;
END $fn$;

-- Rebuild the Build 9 review RPC with the same signature/return type, adding an in-flight delivery race guard.
CREATE OR REPLACE FUNCTION public.marketroute_record_opportunity_review_v1(
  p_opportunity_id uuid,p_reviewer_user_id uuid,p_decision text,p_note text,p_request_id uuid,p_reviewed_at timestamptz DEFAULT now()
) RETURNS TABLE(review_id uuid,workflow_event_id uuid,prior_workflow_state text,resulting_workflow_state text,authority_envelope_fingerprint text,executable_now boolean,deduplicated boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_opp public.opportunities%ROWTYPE; v_existing public.opportunity_human_reviews%ROWTYPE; v_review_id uuid; v_event_id uuid; v_result text; v_envelope jsonb; v_envelope_fp text; v_note text:=NULLIF(btrim(p_note),''); v_reason text;
BEGIN
 IF p_request_id IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_REVIEW_REQUEST_ID_REQUIRED'; END IF; IF p_reviewer_user_id IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_REVIEWER_REQUIRED'; END IF; IF p_decision NOT IN('APPROVE','REJECT','RETURN_TO_RESEARCH') THEN RAISE EXCEPTION 'MARKETROUTE_REVIEW_DECISION_INVALID'; END IF;
 SELECT * INTO v_opp FROM public.opportunities WHERE id=p_opportunity_id FOR UPDATE; IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_OPPORTUNITY_NOT_FOUND'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.organisation_memberships m WHERE m.organisation_id=v_opp.organisation_id AND m.user_id=p_reviewer_user_id AND m.status='ACTIVE' AND m.role IN('OWNER','ADMIN','MEMBER')) THEN RAISE EXCEPTION 'MARKETROUTE_REVIEWER_NOT_AUTHORISED'; END IF;
 SELECT * INTO v_existing FROM public.opportunity_human_reviews WHERE opportunity_id=p_opportunity_id AND review_request_id=p_request_id LIMIT 1;
 IF FOUND THEN
  IF v_existing.reviewer_user_id IS DISTINCT FROM p_reviewer_user_id OR v_existing.decision IS DISTINCT FROM p_decision OR COALESCE(v_existing.note,'') IS DISTINCT FROM COALESCE(v_note,'') THEN RAISE EXCEPTION 'MARKETROUTE_REVIEW_IDEMPOTENCY_COLLISION'; END IF;
  SELECT e.id INTO v_event_id FROM public.opportunity_workflow_events e WHERE e.opportunity_id=p_opportunity_id AND e.request_id=p_request_id LIMIT 1;
  RETURN QUERY SELECT v_existing.id,v_event_id,v_existing.prior_workflow_state,v_existing.resulting_workflow_state,v_existing.authority_envelope_fingerprint,public.marketroute_opportunity_executable_now_v1(p_opportunity_id,now()),true; RETURN;
 END IF;
 IF EXISTS(SELECT 1 FROM public.engagement_delivery_jobs j JOIN public.engagement_queue_items q ON q.id=j.queue_item_id WHERE q.opportunity_id=p_opportunity_id AND j.status='RUNNING') THEN RAISE EXCEPTION 'MARKETROUTE_REVIEW_BLOCKED_DURING_ENGAGEMENT_DELIVERY'; END IF;
 IF p_reviewed_at IS NULL OR abs(extract(epoch FROM(now()-p_reviewed_at)))>300 THEN RAISE EXCEPTION 'MARKETROUTE_REVIEW_TIME_NOT_CURRENT'; END IF;
 v_envelope:=public.marketroute_authority_envelope_v1(v_opp.organisation_id,v_opp.campaign_id,v_opp.company_id,p_reviewed_at); v_envelope_fp:=public.marketroute_authority_envelope_fingerprint_v1(v_envelope);
 IF p_decision='APPROVE' THEN IF v_opp.workflow_state<>'REVIEWABLE' THEN RAISE EXCEPTION 'MARKETROUTE_APPROVAL_REQUIRES_REVIEWABLE'; END IF; IF COALESCE((v_envelope->>'authorityReady')::boolean,false) IS NOT TRUE THEN RAISE EXCEPTION 'MARKETROUTE_APPROVAL_REQUIRES_CURRENT_AUTHORITY'; END IF; v_result:='APPROVED';v_reason:='FOUNDER_APPROVED_CURRENT_AUTHORITY';
 ELSIF p_decision='REJECT' THEN IF v_opp.workflow_state NOT IN('REVIEWABLE','APPROVED') THEN RAISE EXCEPTION 'MARKETROUTE_REJECTION_STATE_INVALID'; END IF;v_result:='REJECTED';v_reason:='FOUNDER_REJECTED';
 ELSE IF v_opp.workflow_state NOT IN('REVIEWABLE','APPROVED','REJECTED') THEN RAISE EXCEPTION 'MARKETROUTE_RETURN_TO_RESEARCH_STATE_INVALID'; END IF;v_result:='RESEARCHING';v_reason:='FOUNDER_RETURNED_TO_RESEARCH'; END IF;
 UPDATE public.opportunities SET workflow_state=v_result WHERE id=v_opp.id;
 INSERT INTO public.opportunity_human_reviews(opportunity_id,organisation_id,reviewer_user_id,decision,note,review_request_id,prior_workflow_state,resulting_workflow_state,authority_envelope_json,authority_envelope_fingerprint,created_at)
 VALUES(v_opp.id,v_opp.organisation_id,p_reviewer_user_id,p_decision,v_note,p_request_id,v_opp.workflow_state,v_result,v_envelope,v_envelope_fp,p_reviewed_at) RETURNING id INTO v_review_id;
 INSERT INTO public.opportunity_workflow_events(opportunity_id,organisation_id,event_type,prior_workflow_state,resulting_workflow_state,actor_user_id,request_id,reason_code,authority_envelope_json,authority_envelope_fingerprint,occurred_at)
 VALUES(v_opp.id,v_opp.organisation_id,'HUMAN_REVIEW',v_opp.workflow_state,v_result,p_reviewer_user_id,p_request_id,v_reason,v_envelope,v_envelope_fp,p_reviewed_at) RETURNING id INTO v_event_id;
 RETURN QUERY SELECT v_review_id,v_event_id,v_opp.workflow_state,v_result,v_envelope_fp,public.marketroute_opportunity_executable_now_v1(p_opportunity_id,p_reviewed_at),false;
END $fn$;

ALTER TABLE public.campaign_engagement_policy_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.engagement_strategies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.engagement_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.engagement_ai_reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.engagement_message_approvals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.engagement_queue_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.engagement_delivery_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.engagement_delivery_events ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.campaign_engagement_policy_events,public.engagement_strategies,public.engagement_messages,public.engagement_ai_reviews,public.engagement_message_approvals,public.engagement_queue_items,public.engagement_delivery_jobs,public.engagement_delivery_events FROM anon,authenticated,service_role;
GRANT SELECT ON public.campaign_engagement_policy_events,public.engagement_strategies,public.engagement_messages,public.engagement_ai_reviews,public.engagement_message_approvals,public.engagement_queue_items,public.engagement_delivery_jobs,public.engagement_delivery_events TO service_role;

REVOKE ALL ON FUNCTION public.marketroute_engagement_channel_kind_v1(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_current_engagement_policy_v1(uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_record_engagement_policy_v1(uuid,uuid,uuid,text,uuid,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_engagement_generation_context_v1(uuid,text,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_engagement_generation_context_fingerprint_v1(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_engagement_strategy_fingerprint_v1(jsonb,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_create_engagement_strategy_v1(uuid,text,uuid,text,text,text,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_engagement_strategy_current_v1(uuid,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_record_engagement_message_v1(uuid,uuid,uuid,text,text,text,text,text,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_record_engagement_ai_review_v1(uuid,uuid,text,text,text,text[],jsonb,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_record_engagement_message_approval_v1(uuid,uuid,text,uuid,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_queue_engagement_v1(uuid,uuid,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_engagement_send_gate_v1(uuid,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_recover_abandoned_engagement_delivery_v1(timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_claim_engagement_delivery_v1(text,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_complete_engagement_delivery_v1(uuid,text,text,jsonb,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_fail_engagement_delivery_v1(uuid,text,text,boolean,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_record_opportunity_review_v1(uuid,uuid,text,text,uuid,timestamptz) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.marketroute_current_engagement_policy_v1(uuid,uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_record_engagement_policy_v1(uuid,uuid,uuid,text,uuid,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_engagement_generation_context_v1(uuid,text,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_engagement_generation_context_fingerprint_v1(jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_create_engagement_strategy_v1(uuid,text,uuid,text,text,text,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_record_engagement_message_v1(uuid,uuid,uuid,text,text,text,text,text,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_record_engagement_ai_review_v1(uuid,uuid,text,text,text,text[],jsonb,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_record_engagement_message_approval_v1(uuid,uuid,text,uuid,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_queue_engagement_v1(uuid,uuid,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_engagement_send_gate_v1(uuid,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_recover_abandoned_engagement_delivery_v1(timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_claim_engagement_delivery_v1(text,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_complete_engagement_delivery_v1(uuid,text,text,jsonb,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_fail_engagement_delivery_v1(uuid,text,text,boolean,timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_record_opportunity_review_v1(uuid,uuid,text,text,uuid,timestamptz) TO service_role;

REVOKE INSERT,UPDATE,DELETE ON public.opportunities FROM anon,authenticated,service_role;

INSERT INTO public.marketroute_schema_releases(release_key,build_number,constitution_version,metadata_json)
VALUES('MARKETROUTE_V2_BUILD12_ENGAGEMENT_ENGINE',12,'MRV2-CONSTITUTION-1.0.0',jsonb_build_object(
 'migration','0015_engagement_engine.sql','new_authority_writer',false,'engagement_is_authority',false,'categorical_ai_review_only',true,
 'numeric_quality_thresholds',false,'queue_requires_current_authority',true,'send_time_recheck',true,'autopilot_cannot_bypass_opportunity_approval',true,
 'delivery_recovery_fails_to_reconciliation',true,'first_successful_delivery_advances_workflow_to_engaged',true,
 'active_commercial_context_required',true,'latest_human_message_approval_controls_send',true,'delivery_claim_fair_across_opportunities',true,'structured_r4_grounded_generation_brief',true
)) ON CONFLICT(release_key) DO NOTHING;

NOTIFY pgrst,'reload schema';
COMMIT;
