BEGIN;

-- RC hotfix: engagement strategy currentness must be stable across observation time.
-- evaluatedAt is an observation timestamp, not commercial/authority state.
CREATE OR REPLACE FUNCTION public.marketroute_engagement_generation_context_fingerprint_v1(p_context jsonb)
RETURNS text
LANGUAGE sql IMMUTABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
  SELECT encode(
    extensions.digest(
      'MRV2-ENGAGEMENT-GENERATION-CONTEXT-1.0.1|' ||
      (COALESCE(p_context,'{}'::jsonb) - 'evaluatedAt')::text,
      'sha256'
    ),
    'hex'
  );
$fn$;

REVOKE ALL ON FUNCTION public.marketroute_engagement_generation_context_fingerprint_v1(jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_engagement_generation_context_fingerprint_v1(jsonb) TO service_role;

-- Legacy full access was migration-only. Allow its owner to voluntarily move onto
-- a real Stripe-backed plan without removing/granting access before checkout succeeds.
-- Direct requests cannot select a plan whose active-market allowance is already too small.
CREATE OR REPLACE FUNCTION public.marketroute_begin_billing_checkout_v1(
  p_organisation_id uuid,
  p_user_id uuid,
  p_plan_code text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE
  v_access jsonb;
  v_attempt uuid;
  v_ent public.organisation_commercial_entitlements%ROWTYPE;
  v_plan_limit integer;
  v_active_markets integer;
  v_legacy_full boolean:=false;
BEGIN
  PERFORM public.marketroute_require_service_role();

  IF p_plan_code NOT IN('STARTER','GROWTH','SCALE')
     OR NOT EXISTS(
       SELECT 1
       FROM public.marketroute_plan_catalog p
       WHERE p.plan_code=p_plan_code
         AND p.public_visible=true
     )
  THEN
    RAISE EXCEPTION 'MARKETROUTE_BILLING_PLAN_INVALID';
  END IF;

  IF NOT EXISTS(
    SELECT 1
    FROM public.organisation_memberships m
    WHERE m.organisation_id=p_organisation_id
      AND m.user_id=p_user_id
      AND m.status='ACTIVE'
      AND m.role='OWNER'
  ) THEN
    RAISE EXCEPTION 'MARKETROUTE_BILLING_OWNER_REQUIRED';
  END IF;

  SELECT *
  INTO v_ent
  FROM public.organisation_commercial_entitlements e
  WHERE e.organisation_id=p_organisation_id
  LIMIT 1;

  v_access:=public.marketroute_workspace_commercial_access_v1(p_organisation_id,now());
  v_legacy_full:=FOUND
    AND v_ent.plan_code='LEGACY_FULL'
    AND v_ent.status='ACTIVE'
    AND v_ent.external_subscription_id IS NULL
    AND COALESCE(v_access->>'mode','UNENTITLED')='FULL';

  IF COALESCE(v_access->>'mode','UNENTITLED')<>'DISCOVERY_FREE' AND NOT v_legacy_full THEN
    RAISE EXCEPTION 'MARKETROUTE_BILLING_CHECKOUT_NOT_AVAILABLE';
  END IF;

  IF FOUND
     AND v_ent.external_subscription_id IS NOT NULL
     AND v_ent.status NOT IN('CANCELLED','EXPIRED')
  THEN
    RAISE EXCEPTION 'MARKETROUTE_BILLING_EXISTING_SUBSCRIPTION_REQUIRES_PORTAL';
  END IF;

  SELECT p.active_market_limit
  INTO v_plan_limit
  FROM public.marketroute_plan_catalog p
  WHERE p.plan_code=p_plan_code
    AND p.public_visible=true;

  SELECT count(*)::int
  INTO v_active_markets
  FROM public.campaigns c
  WHERE c.organisation_id=p_organisation_id
    AND c.workflow_state<>'ARCHIVED';

  IF v_plan_limit IS NULL OR v_active_markets>v_plan_limit THEN
    RAISE EXCEPTION 'MARKETROUTE_BILLING_PLAN_CAMPAIGN_LIMIT_TOO_LOW';
  END IF;

  IF EXISTS(
    SELECT 1
    FROM public.marketroute_billing_checkout_attempts a
    WHERE a.organisation_id=p_organisation_id
      AND a.status IN('PENDING','REDIRECTED')
      AND a.created_at>now()-interval '31 minutes'
  ) THEN
    RAISE EXCEPTION 'MARKETROUTE_BILLING_CHECKOUT_ALREADY_IN_PROGRESS';
  END IF;

  INSERT INTO public.marketroute_billing_checkout_attempts(
    organisation_id,user_id,plan_code,status,metadata_json
  )
  VALUES(
    p_organisation_id,p_user_id,p_plan_code,'PENDING',
    jsonb_build_object(
      'source','RC_ENGAGEMENT_CURRENTNESS_BILLING_LEGACY_HOTFIX',
      'replacesLegacyFull',v_legacy_full
    )
  )
  RETURNING id INTO v_attempt;

  RETURN jsonb_build_object('attemptId',v_attempt);
END;$fn$;

REVOKE ALL ON FUNCTION public.marketroute_begin_billing_checkout_v1(uuid,uuid,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_begin_billing_checkout_v1(uuid,uuid,text) TO service_role;

INSERT INTO public.marketroute_schema_releases(
  release_key,build_number,constitution_version,metadata_json
)
VALUES(
  'MARKETROUTE_V2_RC_ENGAGEMENT_CURRENTNESS_BILLING_LEGACY_HOTFIX',
  26,
  'MRV2-CONSTITUTION-1.0.0',
  jsonb_build_object(
    'migration','0054_engagement_currentness_billing_legacy_hotfix.sql',
    'new_authority_writer',false,
    'engagement_evaluated_at_excluded_from_currentness_fingerprint',true,
    'authority_fingerprints_remain_in_strategy_currentness',true,
    'legacy_full_access_preserved_until_successful_checkout',true,
    'legacy_full_can_voluntarily_convert_to_paid_plan',true,
    'billing_plan_cannot_undercut_active_campaign_count',true,
    'autonomous_delivery_enabled',false
  )
)
ON CONFLICT(release_key) DO NOTHING;

NOTIFY pgrst,'reload schema';
COMMIT;
