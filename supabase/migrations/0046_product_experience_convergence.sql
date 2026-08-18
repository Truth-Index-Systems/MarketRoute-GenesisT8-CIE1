BEGIN;

-- MarketRoute V2 Product Build 26: Full Product Experience.
-- Extends the non-authoritative conversational cache for opportunity Q&A and
-- adds founder-only product economics readout. No commercial authority is written here.

ALTER TABLE public.marketroute_conversation_narration_cache
  DROP CONSTRAINT IF EXISTS marketroute_conversation_narration_cache_scope_kind_check;
ALTER TABLE public.marketroute_conversation_narration_cache
  ADD CONSTRAINT marketroute_conversation_narration_cache_scope_kind_check
  CHECK (scope_kind IN ('DISCOVERY_PROGRESS','COMMAND_CENTRE','CAMPAIGN_OVERVIEW','OPPORTUNITY_SUMMARY','OPPORTUNITY_QA'));

CREATE OR REPLACE FUNCTION public.marketroute_conversation_cache_put_v1(
  p_scope_kind text,
  p_scope_key text,
  p_input_fingerprint text,
  p_contract_version text,
  p_payload_json jsonb,
  p_model text,
  p_organisation_id uuid DEFAULT NULL,
  p_campaign_id uuid DEFAULT NULL,
  p_company_id uuid DEFAULT NULL,
  p_ttl_hours integer DEFAULT 72
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF p_scope_kind NOT IN ('DISCOVERY_PROGRESS','COMMAND_CENTRE','CAMPAIGN_OVERVIEW','OPPORTUNITY_SUMMARY','OPPORTUNITY_QA') THEN RAISE EXCEPTION 'MARKETROUTE_CONVERSATION_SCOPE_INVALID'; END IF;
  IF length(btrim(COALESCE(p_scope_key,''))) NOT BETWEEN 1 AND 240 THEN RAISE EXCEPTION 'MARKETROUTE_CONVERSATION_SCOPE_KEY_INVALID'; END IF;
  IF COALESCE(p_input_fingerprint,'') !~ '^[a-f0-9]{64}$' THEN RAISE EXCEPTION 'MARKETROUTE_CONVERSATION_FINGERPRINT_INVALID'; END IF;
  IF COALESCE(p_payload_json->>'contractVersion','')<>p_contract_version OR COALESCE(p_payload_json->>'scope','')<>p_scope_kind OR COALESCE(p_payload_json->>'sourceFingerprint','')<>p_input_fingerprint THEN RAISE EXCEPTION 'MARKETROUTE_CONVERSATION_PAYLOAD_LINEAGE_INVALID'; END IF;
  IF jsonb_typeof(p_payload_json->'known') IS DISTINCT FROM 'array' OR jsonb_typeof(p_payload_json->'uncertainties') IS DISTINCT FROM 'array' OR jsonb_typeof(p_payload_json->'evidenceReferences') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'MARKETROUTE_CONVERSATION_PAYLOAD_SHAPE_INVALID'; END IF;
  IF pg_column_size(p_payload_json)>32768 THEN RAISE EXCEPTION 'MARKETROUTE_CONVERSATION_PAYLOAD_TOO_LARGE'; END IF;
  IF p_ttl_hours<1 OR p_ttl_hours>720 THEN RAISE EXCEPTION 'MARKETROUTE_CONVERSATION_TTL_INVALID'; END IF;
  INSERT INTO public.marketroute_conversation_narration_cache(
    scope_kind,scope_key,input_fingerprint,contract_version,payload_json,model,organisation_id,campaign_id,company_id,created_at,expires_at
  ) VALUES(
    p_scope_kind,btrim(p_scope_key),p_input_fingerprint,p_contract_version,p_payload_json,btrim(p_model),p_organisation_id,p_campaign_id,p_company_id,now(),now()+make_interval(hours=>p_ttl_hours)
  )
  ON CONFLICT(scope_kind,scope_key,input_fingerprint,contract_version) DO UPDATE
  SET payload_json=EXCLUDED.payload_json,
      model=EXCLUDED.model,
      organisation_id=EXCLUDED.organisation_id,
      campaign_id=EXCLUDED.campaign_id,
      company_id=EXCLUDED.company_id,
      created_at=now(),
      expires_at=EXCLUDED.expires_at;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.marketroute_product_economics_snapshot_v1(p_at timestamptz DEFAULT now())
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
DECLARE
  v_30d timestamptz:=p_at-interval '30 days';
  v_runs integer:=0; v_claimed integer:=0; v_checkouts integer:=0; v_checkout_completed integer:=0;
  v_paid integer:=0; v_mrr numeric:=0; v_anon_spend numeric:=0; v_ai_30d numeric:=0; v_paid_ai_30d numeric:=0;
  v_plan_counts jsonb:='{}'::jsonb;
BEGIN
  PERFORM public.marketroute_require_service_role();

  SELECT count(*)::int, count(*) FILTER (WHERE status='CLAIMED')::int
  INTO v_runs,v_claimed FROM public.anonymous_discovery_runs;

  SELECT count(*)::int, count(*) FILTER (WHERE status='COMPLETED')::int
  INTO v_checkouts,v_checkout_completed FROM public.marketroute_billing_checkout_attempts;

  SELECT count(*)::int,
         COALESCE(sum(p.monthly_price_gbp),0),
         COALESCE((SELECT jsonb_object_agg(plan_code,cnt) FROM (
           SELECT e.plan_code,count(*)::int cnt
           FROM public.organisation_commercial_entitlements e
           WHERE e.status='ACTIVE' AND e.plan_code IN('STARTER','GROWTH','SCALE')
             AND (e.current_period_start IS NULL OR e.current_period_start<=p_at)
             AND (e.current_period_end IS NULL OR e.current_period_end>p_at)
           GROUP BY e.plan_code
         ) q),'{}'::jsonb)
  INTO v_paid,v_mrr,v_plan_counts
  FROM public.organisation_commercial_entitlements e
  JOIN public.marketroute_plan_catalog p ON p.plan_code=e.plan_code
  WHERE e.status='ACTIVE' AND e.plan_code IN('STARTER','GROWTH','SCALE')
    AND (e.current_period_start IS NULL OR e.current_period_start<=p_at)
    AND (e.current_period_end IS NULL OR e.current_period_end>p_at);

  SELECT COALESCE(sum(a.cost_usd),0) INTO v_anon_spend
  FROM public.ai_usage_events a
  JOIN public.anonymous_discovery_runs d ON d.organisation_id=a.organisation_id;

  SELECT COALESCE(sum(cost_usd),0) INTO v_ai_30d
  FROM public.ai_usage_events WHERE created_at>=v_30d AND created_at<=p_at;

  SELECT COALESCE(sum(a.cost_usd),0) INTO v_paid_ai_30d
  FROM public.ai_usage_events a
  JOIN public.organisation_commercial_entitlements e ON e.organisation_id=a.organisation_id
  WHERE a.created_at>=v_30d AND a.created_at<=p_at
    AND e.status='ACTIVE' AND e.plan_code IN('STARTER','GROWTH','SCALE')
    AND (e.current_period_start IS NULL OR e.current_period_start<=p_at)
    AND (e.current_period_end IS NULL OR e.current_period_end>p_at);

  RETURN jsonb_build_object(
    'generatedAt',p_at,
    'anonymousRuns',v_runs,
    'claimedRuns',v_claimed,
    'claimRatePct',CASE WHEN v_runs=0 THEN 0 ELSE round((v_claimed::numeric/v_runs::numeric)*100,1) END,
    'checkoutAttempts',v_checkouts,
    'checkoutCompleted',v_checkout_completed,
    'checkoutCompletionPct',CASE WHEN v_checkouts=0 THEN 0 ELSE round((v_checkout_completed::numeric/v_checkouts::numeric)*100,1) END,
    'activePaidWorkspaces',v_paid,
    'mrrGbp',v_mrr,
    'activePlanCounts',v_plan_counts,
    'anonymousAiSpendUsd',v_anon_spend,
    'averageAnonymousRunCostUsd',CASE WHEN v_runs=0 THEN 0 ELSE round(v_anon_spend/v_runs,4) END,
    'aiSpend30dUsd',v_ai_30d,
    'paidWorkspaceAiSpend30dUsd',v_paid_ai_30d
  );
END;
$fn$;

REVOKE ALL ON FUNCTION public.marketroute_product_economics_snapshot_v1(timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_product_economics_snapshot_v1(timestamptz) TO service_role;

INSERT INTO public.marketroute_schema_releases(release_key,build_number,constitution_version,metadata_json)
VALUES('MARKETROUTE_V2_PRODUCT_BUILD26_FULL_PRODUCT_EXPERIENCE',26,'MRV2-CONSTITUTION-1.0.0',jsonb_build_object(
  'migration','0046_product_experience_convergence.sql','new_authority_writer',false,'authority_semantics_unchanged',true,
  'opportunity_qa_non_authoritative',true,'founder_economics_read_only',true,'growth_reactivated',false,'delivery_enabled',false
)) ON CONFLICT(release_key) DO NOTHING;

NOTIFY pgrst,'reload schema';
COMMIT;
