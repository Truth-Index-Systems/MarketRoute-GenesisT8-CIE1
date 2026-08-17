BEGIN;

-- MarketRoute V2 Product Build 21: Conversational Intelligence.
-- Adds a server-only cache for customer-facing explanations over canonical read state.
-- AI narration is non-authoritative: it cannot create or mutate Truth/R4/R5/R6/opportunity authority.

CREATE TABLE IF NOT EXISTS public.marketroute_conversation_narration_cache (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  scope_kind text NOT NULL CHECK (scope_kind IN ('DISCOVERY_PROGRESS','COMMAND_CENTRE','CAMPAIGN_OVERVIEW','OPPORTUNITY_SUMMARY')),
  scope_key text NOT NULL CHECK (length(btrim(scope_key)) BETWEEN 1 AND 240),
  input_fingerprint text NOT NULL CHECK (input_fingerprint ~ '^[a-f0-9]{64}$'),
  contract_version text NOT NULL CHECK (length(btrim(contract_version)) BETWEEN 3 AND 80),
  payload_json jsonb NOT NULL,
  model text NOT NULL CHECK (length(btrim(model)) BETWEEN 1 AND 160),
  organisation_id uuid REFERENCES public.organisations(id) ON DELETE CASCADE,
  campaign_id uuid REFERENCES public.campaigns(id) ON DELETE CASCADE,
  company_id uuid REFERENCES public.companies(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  UNIQUE(scope_kind,scope_key,input_fingerprint,contract_version),
  CHECK (expires_at > created_at)
);
CREATE INDEX IF NOT EXISTS marketroute_conversation_narration_scope_idx
  ON public.marketroute_conversation_narration_cache(scope_kind,scope_key,created_at DESC);
CREATE INDEX IF NOT EXISTS marketroute_conversation_narration_expiry_idx
  ON public.marketroute_conversation_narration_cache(expires_at);

ALTER TABLE public.marketroute_conversation_narration_cache ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.marketroute_conversation_narration_cache FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT,INSERT,UPDATE,DELETE ON public.marketroute_conversation_narration_cache TO service_role;

CREATE OR REPLACE FUNCTION public.marketroute_conversation_cache_get_v1(
  p_scope_kind text,
  p_scope_key text,
  p_input_fingerprint text,
  p_contract_version text
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
DECLARE v_row public.marketroute_conversation_narration_cache%ROWTYPE;
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT * INTO v_row
  FROM public.marketroute_conversation_narration_cache
  WHERE scope_kind=p_scope_kind
    AND scope_key=p_scope_key
    AND input_fingerprint=p_input_fingerprint
    AND contract_version=p_contract_version
    AND expires_at>now()
  ORDER BY created_at DESC
  LIMIT 1;
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN jsonb_build_object(
    'payload',v_row.payload_json,
    'model',v_row.model,
    'createdAt',v_row.created_at,
    'expiresAt',v_row.expires_at
  );
END;
$fn$;

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
  IF p_scope_kind NOT IN ('DISCOVERY_PROGRESS','COMMAND_CENTRE','CAMPAIGN_OVERVIEW','OPPORTUNITY_SUMMARY') THEN RAISE EXCEPTION 'MARKETROUTE_CONVERSATION_SCOPE_INVALID'; END IF;
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

REVOKE ALL ON FUNCTION public.marketroute_conversation_cache_get_v1(text,text,text,text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_conversation_cache_put_v1(text,text,text,text,jsonb,text,uuid,uuid,uuid,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_conversation_cache_get_v1(text,text,text,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_conversation_cache_put_v1(text,text,text,text,jsonb,text,uuid,uuid,uuid,integer) TO service_role;

INSERT INTO public.marketroute_schema_releases(
  release_key,build_number,constitution_version,metadata_json
) VALUES(
  'MARKETROUTE_V2_PRODUCT_BUILD21_CONVERSATIONAL_INTELLIGENCE',
  21,
  'MRV2-CONSTITUTION-1.0.0',
  jsonb_build_object(
    'migration','0041_product_conversational_intelligence.sql',
    'new_authority_writer',false,
    'ai_authority_granted',false,
    'canonical_read_model_grounded',true,
    'narration_cache_server_only',true,
    'anonymous_database_access',false,
    'web_search_for_narration',false,
    'conversation_contract','MRV2-CONVERSATION-1.0.0'
  )
) ON CONFLICT(release_key) DO NOTHING;

NOTIFY pgrst,'reload schema';
COMMIT;
