BEGIN;

-- MarketRoute V2 Product Build 25: Billing + Instant Unlock.
-- Billing can activate/revoke product entitlement only. It does not create or modify
-- Truth, R4, R5, R6, opportunity authority, evidence or contact authority.

CREATE TABLE IF NOT EXISTS public.marketroute_billing_checkout_attempts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organisation_id uuid NOT NULL REFERENCES public.organisations(id) ON DELETE RESTRICT,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  plan_code text NOT NULL REFERENCES public.marketroute_plan_catalog(plan_code) ON DELETE RESTRICT,
  provider text NOT NULL DEFAULT 'STRIPE' CHECK (provider='STRIPE'),
  status text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','REDIRECTED','COMPLETED','FAILED','EXPIRED')),
  external_checkout_session_id text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  metadata_json jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata_json)='object')
);
CREATE UNIQUE INDEX IF NOT EXISTS marketroute_billing_checkout_external_unique
  ON public.marketroute_billing_checkout_attempts(external_checkout_session_id) WHERE external_checkout_session_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS marketroute_billing_checkout_org_idx
  ON public.marketroute_billing_checkout_attempts(organisation_id,created_at DESC);

CREATE TABLE IF NOT EXISTS public.marketroute_billing_events (
  provider text NOT NULL DEFAULT 'STRIPE' CHECK (provider='STRIPE'),
  external_event_id text PRIMARY KEY,
  event_type text NOT NULL,
  status text NOT NULL DEFAULT 'RECEIVED' CHECK (status IN ('RECEIVED','PROCESSED','IGNORED','FAILED')),
  payload_sha256 text NOT NULL CHECK (payload_sha256 ~ '^[a-f0-9]{64}$'),
  error_code text,
  metadata_json jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata_json)='object'),
  received_at timestamptz NOT NULL DEFAULT now(),
  processed_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.marketroute_billing_checkout_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketroute_billing_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.marketroute_billing_checkout_attempts FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON public.marketroute_billing_events FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT,INSERT,UPDATE ON public.marketroute_billing_checkout_attempts TO service_role;
GRANT SELECT,INSERT,UPDATE ON public.marketroute_billing_events TO service_role;

CREATE OR REPLACE FUNCTION public.marketroute_billing_context_v1(p_organisation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_ent public.organisation_commercial_entitlements%ROWTYPE;
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT * INTO v_ent FROM public.organisation_commercial_entitlements e WHERE e.organisation_id=p_organisation_id LIMIT 1;
  RETURN jsonb_build_object(
    'organisationId',p_organisation_id,
    'planCode',CASE WHEN FOUND THEN v_ent.plan_code ELSE NULL END,
    'entitlementStatus',CASE WHEN FOUND THEN v_ent.status ELSE NULL END,
    'externalCustomerId',CASE WHEN FOUND THEN v_ent.external_customer_id ELSE NULL END,
    'externalSubscriptionId',CASE WHEN FOUND THEN v_ent.external_subscription_id ELSE NULL END,
    'currentPeriodStart',CASE WHEN FOUND THEN v_ent.current_period_start ELSE NULL END,
    'currentPeriodEnd',CASE WHEN FOUND THEN v_ent.current_period_end ELSE NULL END,
    'cancelAtPeriodEnd',CASE WHEN FOUND THEN COALESCE((v_ent.metadata_json->>'cancelAtPeriodEnd')::boolean,false) ELSE false END
  );
END;$fn$;

CREATE OR REPLACE FUNCTION public.marketroute_begin_billing_checkout_v1(p_organisation_id uuid,p_user_id uuid,p_plan_code text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_access jsonb;v_attempt uuid;v_ent public.organisation_commercial_entitlements%ROWTYPE;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF p_plan_code NOT IN('STARTER','GROWTH','SCALE') OR NOT EXISTS(SELECT 1 FROM public.marketroute_plan_catalog p WHERE p.plan_code=p_plan_code AND p.public_visible=true) THEN RAISE EXCEPTION 'MARKETROUTE_BILLING_PLAN_INVALID'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.organisation_memberships m WHERE m.organisation_id=p_organisation_id AND m.user_id=p_user_id AND m.status='ACTIVE' AND m.role='OWNER') THEN RAISE EXCEPTION 'MARKETROUTE_BILLING_OWNER_REQUIRED'; END IF;
  v_access:=public.marketroute_workspace_commercial_access_v1(p_organisation_id,now());
  IF COALESCE(v_access->>'mode','UNENTITLED')<>'DISCOVERY_FREE' THEN RAISE EXCEPTION 'MARKETROUTE_BILLING_CHECKOUT_NOT_AVAILABLE'; END IF;
  SELECT * INTO v_ent FROM public.organisation_commercial_entitlements e WHERE e.organisation_id=p_organisation_id LIMIT 1;
  IF FOUND AND v_ent.external_subscription_id IS NOT NULL AND v_ent.status NOT IN('CANCELLED','EXPIRED') THEN RAISE EXCEPTION 'MARKETROUTE_BILLING_EXISTING_SUBSCRIPTION_REQUIRES_PORTAL'; END IF;
  IF EXISTS(SELECT 1 FROM public.marketroute_billing_checkout_attempts a WHERE a.organisation_id=p_organisation_id AND a.status IN('PENDING','REDIRECTED') AND a.created_at>now()-interval '31 minutes') THEN RAISE EXCEPTION 'MARKETROUTE_BILLING_CHECKOUT_ALREADY_IN_PROGRESS'; END IF;
  INSERT INTO public.marketroute_billing_checkout_attempts(organisation_id,user_id,plan_code,status,metadata_json)
  VALUES(p_organisation_id,p_user_id,p_plan_code,'PENDING',jsonb_build_object('source','PRODUCT_BUILD25')) RETURNING id INTO v_attempt;
  RETURN jsonb_build_object('attemptId',v_attempt);
END;$fn$;

CREATE OR REPLACE FUNCTION public.marketroute_attach_billing_checkout_v1(p_attempt_id uuid,p_external_checkout_session_id text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF p_external_checkout_session_id IS NULL OR p_external_checkout_session_id !~ '^cs_' THEN RAISE EXCEPTION 'MARKETROUTE_BILLING_CHECKOUT_ID_INVALID'; END IF;
  UPDATE public.marketroute_billing_checkout_attempts SET external_checkout_session_id=p_external_checkout_session_id,status='REDIRECTED',updated_at=now() WHERE id=p_attempt_id AND status='PENDING';
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_BILLING_CHECKOUT_ATTEMPT_NOT_PENDING'; END IF;
  RETURN true;
END;$fn$;


CREATE OR REPLACE FUNCTION public.marketroute_terminate_billing_checkout_v1(p_attempt_id uuid,p_organisation_id uuid,p_user_id uuid,p_status text,p_reason text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF p_status NOT IN('FAILED','EXPIRED') THEN RAISE EXCEPTION 'MARKETROUTE_BILLING_CHECKOUT_TERMINAL_STATUS_INVALID'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.organisation_memberships m WHERE m.organisation_id=p_organisation_id AND m.user_id=p_user_id AND m.status='ACTIVE' AND m.role='OWNER') THEN RAISE EXCEPTION 'MARKETROUTE_BILLING_OWNER_REQUIRED'; END IF;
  UPDATE public.marketroute_billing_checkout_attempts SET status=p_status,updated_at=now(),metadata_json=metadata_json||jsonb_build_object('terminationReason',left(COALESCE(p_reason,''),300))
  WHERE id=p_attempt_id AND organisation_id=p_organisation_id AND user_id=p_user_id AND status IN('PENDING','REDIRECTED');
  RETURN FOUND;
END;$fn$;

CREATE OR REPLACE FUNCTION public.marketroute_begin_billing_event_v1(p_external_event_id text,p_event_type text,p_payload_sha256 text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_inserted integer:=0;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF p_external_event_id IS NULL OR p_external_event_id !~ '^evt_' THEN RAISE EXCEPTION 'MARKETROUTE_BILLING_EVENT_ID_INVALID'; END IF;
  IF p_payload_sha256 IS NULL OR p_payload_sha256 !~ '^[a-f0-9]{64}$' THEN RAISE EXCEPTION 'MARKETROUTE_BILLING_EVENT_HASH_INVALID'; END IF;
  INSERT INTO public.marketroute_billing_events(external_event_id,event_type,payload_sha256,status)
  VALUES(p_external_event_id,left(COALESCE(p_event_type,''),160),p_payload_sha256,'RECEIVED') ON CONFLICT(external_event_id) DO NOTHING;
  GET DIAGNOSTICS v_inserted=ROW_COUNT;
  IF v_inserted=1 THEN RETURN true; END IF;
  IF EXISTS(SELECT 1 FROM public.marketroute_billing_events e WHERE e.external_event_id=p_external_event_id AND e.payload_sha256<>p_payload_sha256) THEN RAISE EXCEPTION 'MARKETROUTE_BILLING_EVENT_PAYLOAD_MISMATCH'; END IF;
  UPDATE public.marketroute_billing_events SET status='RECEIVED',error_code=NULL,received_at=now(),processed_at=NULL,updated_at=now()
  WHERE external_event_id=p_external_event_id AND (status='FAILED' OR (status='RECEIVED' AND updated_at<now()-interval '5 minutes'));
  GET DIAGNOSTICS v_inserted=ROW_COUNT;
  RETURN v_inserted=1;
END;$fn$;

CREATE OR REPLACE FUNCTION public.marketroute_finish_billing_event_v1(p_external_event_id text,p_status text,p_error_code text DEFAULT NULL,p_metadata_json jsonb DEFAULT '{}'::jsonb)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF p_status NOT IN('PROCESSED','IGNORED','FAILED') THEN RAISE EXCEPTION 'MARKETROUTE_BILLING_EVENT_STATUS_INVALID'; END IF;
  UPDATE public.marketroute_billing_events SET status=p_status,error_code=left(NULLIF(btrim(COALESCE(p_error_code,'')),''),500),metadata_json=COALESCE(p_metadata_json,'{}'::jsonb),processed_at=now(),updated_at=now() WHERE external_event_id=p_external_event_id;
  RETURN FOUND;
END;$fn$;

CREATE OR REPLACE FUNCTION public.marketroute_reconcile_stripe_subscription_v1(
  p_organisation_id uuid,p_plan_code text,p_external_customer_id text,p_external_subscription_id text,p_provider_status text,
  p_current_period_start timestamptz,p_current_period_end timestamptz,p_cancel_at_period_end boolean DEFAULT false,
  p_external_event_id text DEFAULT NULL,p_event_type text DEFAULT NULL,p_external_checkout_session_id text DEFAULT NULL
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_status text;v_provider text:=lower(btrim(COALESCE(p_provider_status,'')));v_existing_org uuid;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF p_plan_code NOT IN('STARTER','GROWTH','SCALE') OR NOT EXISTS(SELECT 1 FROM public.marketroute_plan_catalog p WHERE p.plan_code=p_plan_code AND p.public_visible=true) THEN RAISE EXCEPTION 'MARKETROUTE_BILLING_PLAN_INVALID'; END IF;
  IF p_external_customer_id IS NULL OR p_external_customer_id !~ '^cus_' THEN RAISE EXCEPTION 'MARKETROUTE_BILLING_CUSTOMER_ID_INVALID'; END IF;
  IF p_external_subscription_id IS NULL OR p_external_subscription_id !~ '^sub_' THEN RAISE EXCEPTION 'MARKETROUTE_BILLING_SUBSCRIPTION_ID_INVALID'; END IF;
  IF p_current_period_end IS NOT NULL AND p_current_period_start IS NOT NULL AND p_current_period_end<=p_current_period_start THEN RAISE EXCEPTION 'MARKETROUTE_BILLING_PERIOD_INVALID'; END IF;
  SELECT organisation_id INTO v_existing_org FROM public.organisation_commercial_entitlements WHERE external_subscription_id=p_external_subscription_id AND organisation_id<>p_organisation_id LIMIT 1;
  IF v_existing_org IS NOT NULL THEN RAISE EXCEPTION 'MARKETROUTE_BILLING_SUBSCRIPTION_ALREADY_OWNED'; END IF;
  v_status:=CASE WHEN v_provider IN('active','trialing') THEN 'ACTIVE' WHEN v_provider='incomplete_expired' THEN 'EXPIRED' WHEN v_provider IN('canceled','unpaid') THEN 'CANCELLED' ELSE 'PAST_DUE' END;
  INSERT INTO public.organisation_commercial_entitlements(organisation_id,plan_code,status,source,external_customer_id,external_subscription_id,current_period_start,current_period_end,activated_at,updated_at,metadata_json)
  VALUES(p_organisation_id,p_plan_code,v_status,'BILLING',p_external_customer_id,p_external_subscription_id,p_current_period_start,p_current_period_end,now(),now(),jsonb_build_object('provider','STRIPE','providerStatus',v_provider,'cancelAtPeriodEnd',COALESCE(p_cancel_at_period_end,false),'lastEventId',p_external_event_id,'lastEventType',p_event_type))
  ON CONFLICT(organisation_id) DO UPDATE SET plan_code=EXCLUDED.plan_code,status=EXCLUDED.status,source='BILLING',external_customer_id=EXCLUDED.external_customer_id,external_subscription_id=EXCLUDED.external_subscription_id,current_period_start=EXCLUDED.current_period_start,current_period_end=EXCLUDED.current_period_end,activated_at=CASE WHEN organisation_commercial_entitlements.status<>'ACTIVE' AND EXCLUDED.status='ACTIVE' THEN now() ELSE organisation_commercial_entitlements.activated_at END,updated_at=now(),metadata_json=organisation_commercial_entitlements.metadata_json||EXCLUDED.metadata_json;
  IF p_external_checkout_session_id IS NOT NULL THEN
    UPDATE public.marketroute_billing_checkout_attempts SET status=CASE WHEN v_status='ACTIVE' THEN 'COMPLETED' ELSE status END,updated_at=now(),metadata_json=metadata_json||jsonb_build_object('subscriptionId',p_external_subscription_id,'providerStatus',v_provider) WHERE external_checkout_session_id=p_external_checkout_session_id;
  END IF;
  RETURN true;
END;$fn$;

REVOKE ALL ON FUNCTION public.marketroute_billing_context_v1(uuid) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_begin_billing_checkout_v1(uuid,uuid,text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_attach_billing_checkout_v1(uuid,text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_terminate_billing_checkout_v1(uuid,uuid,uuid,text,text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_begin_billing_event_v1(text,text,text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_finish_billing_event_v1(text,text,text,jsonb) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_reconcile_stripe_subscription_v1(uuid,text,text,text,text,timestamptz,timestamptz,boolean,text,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_billing_context_v1(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_begin_billing_checkout_v1(uuid,uuid,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_attach_billing_checkout_v1(uuid,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_terminate_billing_checkout_v1(uuid,uuid,uuid,text,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_begin_billing_event_v1(text,text,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_finish_billing_event_v1(text,text,text,jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_reconcile_stripe_subscription_v1(uuid,text,text,text,text,timestamptz,timestamptz,boolean,text,text,text) TO service_role;

INSERT INTO public.marketroute_schema_releases(release_key,build_number,constitution_version,metadata_json)
VALUES('MARKETROUTE_V2_PRODUCT_BUILD25_BILLING_INSTANT_UNLOCK',25,'MRV2-CONSTITUTION-1.0.0',jsonb_build_object(
  'migration','0045_product_billing_instant_unlock.sql','new_authority_writer',false,'authority_semantics_unchanged',true,
  'billing_provider','STRIPE','browser_can_grant_entitlement',false,'webhook_signature_required',true,'billing_event_idempotency',true,
  'checkout_price_server_verified',true,'success_reconcile_enabled',true,'customer_portal_enabled',true,'growth_reactivated',false
)) ON CONFLICT(release_key) DO NOTHING;

NOTIFY pgrst,'reload schema';
COMMIT;
