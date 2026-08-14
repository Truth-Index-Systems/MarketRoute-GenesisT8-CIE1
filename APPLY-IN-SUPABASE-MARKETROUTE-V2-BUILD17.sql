BEGIN;

-- MarketRoute V2 Build 17: V1 -> V2 factual/evidence migration.
-- This is an ETL boundary only. V1 authority, scores, READY state and workflow decisions are not admissible input.

CREATE TABLE public.marketroute_v1_migration_batches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  target_organisation_id uuid NOT NULL REFERENCES public.organisations(id) ON DELETE RESTRICT,
  created_by_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  source_system text NOT NULL DEFAULT 'MARKETROUTE_V1' CHECK (source_system = 'MARKETROUTE_V1'),
  contract_version text NOT NULL CHECK (contract_version = 'MRV2-V1-FACTUAL-EXPORT-1.0.0'),
  source_export_fingerprint text NOT NULL CHECK (source_export_fingerprint ~ '^[a-f0-9]{64}$'),
  status text NOT NULL DEFAULT 'IMPORTING' CHECK (status IN ('IMPORTING','COMPLETED','FAILED','ABORTED')),
  metadata_json jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata_json)='object'),
  started_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz
);

CREATE UNIQUE INDEX marketroute_v1_migration_batch_export_unique
ON public.marketroute_v1_migration_batches(target_organisation_id, source_system, source_export_fingerprint);

CREATE TABLE public.marketroute_v1_migration_id_map (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  batch_id uuid NOT NULL REFERENCES public.marketroute_v1_migration_batches(id) ON DELETE RESTRICT,
  target_organisation_id uuid NOT NULL REFERENCES public.organisations(id) ON DELETE RESTRICT,
  source_system text NOT NULL CHECK (source_system='MARKETROUTE_V1'),
  entity_kind text NOT NULL CHECK (entity_kind IN (
    'COMPANY','PERSON','ACCESS_POINT','SELLER_BUSINESS','SELLER_SOURCE_MATERIAL',
    'CAMPAIGN','CAMPAIGN_SCOPE','SOURCE','EVIDENCE','CLAIM','HISTORICAL_RESEARCH'
  )),
  source_table text NOT NULL CHECK (length(btrim(source_table)) BETWEEN 1 AND 160),
  v1_id text NOT NULL CHECK (length(btrim(v1_id)) BETWEEN 1 AND 512),
  v2_id uuid NOT NULL,
  record_fingerprint text NOT NULL CHECK (record_fingerprint ~ '^[a-f0-9]{64}$'),
  migrated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (target_organisation_id, source_system, entity_kind, source_table, v1_id)
);

CREATE INDEX marketroute_v1_migration_map_batch_idx
ON public.marketroute_v1_migration_id_map(batch_id, entity_kind, migrated_at);

CREATE TABLE public.marketroute_v1_migration_rejections (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  batch_id uuid NOT NULL REFERENCES public.marketroute_v1_migration_batches(id) ON DELETE RESTRICT,
  entity_kind text NOT NULL,
  source_table text NOT NULL,
  v1_id text NOT NULL,
  reason_code text NOT NULL CHECK (length(btrim(reason_code)) BETWEEN 1 AND 160),
  rejected_field_keys text[] NOT NULL DEFAULT '{}',
  payload_fingerprint text NOT NULL CHECK (payload_fingerprint ~ '^[a-f0-9]{64}$'),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX marketroute_v1_migration_rejections_batch_idx
ON public.marketroute_v1_migration_rejections(batch_id, created_at);

CREATE TABLE public.marketroute_v1_migration_audit_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  batch_id uuid NOT NULL REFERENCES public.marketroute_v1_migration_batches(id) ON DELETE RESTRICT,
  event_type text NOT NULL CHECK (length(btrim(event_type)) BETWEEN 1 AND 160),
  entity_kind text,
  source_table text,
  v1_id text,
  v2_id uuid,
  record_fingerprint text CHECK (record_fingerprint IS NULL OR record_fingerprint ~ '^[a-f0-9]{64}$'),
  metadata_json jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata_json)='object'),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX marketroute_v1_migration_audit_batch_idx
ON public.marketroute_v1_migration_audit_events(batch_id, created_at);

CREATE TRIGGER marketroute_v1_migration_id_map_append_only
BEFORE UPDATE OR DELETE ON public.marketroute_v1_migration_id_map
FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

CREATE TRIGGER marketroute_v1_migration_rejections_append_only
BEFORE UPDATE OR DELETE ON public.marketroute_v1_migration_rejections
FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

CREATE TRIGGER marketroute_v1_migration_audit_append_only
BEFORE UPDATE OR DELETE ON public.marketroute_v1_migration_audit_events
FOR EACH ROW EXECUTE FUNCTION public.marketroute_reject_mutation();

ALTER TABLE public.marketroute_v1_migration_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketroute_v1_migration_id_map ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketroute_v1_migration_rejections ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketroute_v1_migration_audit_events ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.marketroute_v1_migration_batches FROM anon, authenticated, service_role;
REVOKE ALL ON public.marketroute_v1_migration_id_map FROM anon, authenticated, service_role;
REVOKE ALL ON public.marketroute_v1_migration_rejections FROM anon, authenticated, service_role;
REVOKE ALL ON public.marketroute_v1_migration_audit_events FROM anon, authenticated, service_role;
GRANT SELECT ON public.marketroute_v1_migration_batches TO service_role;
GRANT SELECT ON public.marketroute_v1_migration_id_map TO service_role;
GRANT SELECT ON public.marketroute_v1_migration_rejections TO service_role;
GRANT SELECT ON public.marketroute_v1_migration_audit_events TO service_role;

CREATE OR REPLACE FUNCTION public.marketroute_v1_payload_forbidden_keys_v1(p_payload jsonb)
RETURNS text[]
LANGUAGE sql
IMMUTABLE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
  WITH RECURSIVE walk(value) AS (
    SELECT COALESCE(p_payload,'{}'::jsonb)
    UNION ALL
    SELECT child
    FROM walk w
    CROSS JOIN LATERAL (
      SELECT value child FROM jsonb_each(CASE WHEN jsonb_typeof(w.value)='object' THEN w.value ELSE '{}'::jsonb END)
      UNION ALL
      SELECT value child FROM jsonb_array_elements(CASE WHEN jsonb_typeof(w.value)='array' THEN w.value ELSE '[]'::jsonb END)
    ) x
  ), keys AS (
    SELECT DISTINCT lower(regexp_replace(k.key,'[^a-zA-Z0-9]+','','g')) normalised_key
    FROM walk w
    CROSS JOIN LATERAL jsonb_object_keys(CASE WHEN jsonb_typeof(w.value)='object' THEN w.value ELSE '{}'::jsonb END) k(key)
  )
  SELECT COALESCE(array_agg(normalised_key ORDER BY normalised_key),'{}'::text[])
  FROM keys
  WHERE normalised_key = ANY(ARRAY[
    'authority','authorityrecord','authorityrecordid','authorityfingerprint','authoritystate',
    'commercialreality','routeauthority','contactauthority','approvalauthority',
    'opportunityscore','fitscore','score','weightedscore','rankingscore','rank',
    'confidence','overallconfidence','routeconfidence','routequality','evidencesufficiency',
    'viability','isviable','ready','readystatus','workflowstate','approvalstate',
    'truthindex','truthprobability','probability','r4','r5','r6','oldr4','oldr5','oldr6'
  ]);
$$;

CREATE OR REPLACE FUNCTION public.marketroute_v1_assert_factual_payload_v1(p_payload jsonb)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_forbidden text[];
BEGIN
  IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object' THEN
    RAISE EXCEPTION 'MARKETROUTE_V1_MIGRATION_PAYLOAD_OBJECT_REQUIRED';
  END IF;
  v_forbidden:=public.marketroute_v1_payload_forbidden_keys_v1(p_payload);
  IF cardinality(v_forbidden)>0 THEN
    RAISE EXCEPTION 'MARKETROUTE_V1_AUTHORITY_FIELD_REJECTED:%', array_to_string(v_forbidden,',');
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.marketroute_v1_assert_allowed_keys_v1(p_payload jsonb,p_allowed text[])
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_key text;
BEGIN
  IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object' THEN RAISE EXCEPTION 'MARKETROUTE_V1_MIGRATION_PAYLOAD_OBJECT_REQUIRED'; END IF;
  FOR v_key IN SELECT jsonb_object_keys(p_payload) LOOP
    IF NOT (v_key=ANY(p_allowed)) THEN RAISE EXCEPTION 'MARKETROUTE_V1_FIELD_NOT_WHITELISTED:%',v_key; END IF;
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION public.marketroute_v1_record_fingerprint_v1(p_entity_kind text,p_source_table text,p_v1_id text,p_payload jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
SECURITY DEFINER
SET search_path=public,pg_temp,extensions
AS $$
  SELECT encode(extensions.digest(concat_ws('|','MRV2-V1-IMPORT-RECORD-1.0.0',upper(btrim(p_entity_kind)),lower(btrim(p_source_table)),btrim(p_v1_id),COALESCE(p_payload,'{}'::jsonb)::text),'sha256'),'hex');
$$;

CREATE OR REPLACE FUNCTION public.marketroute_v1_assert_claim_key_factual_v1(p_claim_key text)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_key text:=lower(regexp_replace(COALESCE(p_claim_key,''),'[^a-zA-Z0-9]+','','g'));
BEGIN
  IF length(v_key)=0 THEN RAISE EXCEPTION 'MARKETROUTE_V1_CLAIM_KEY_REQUIRED'; END IF;
  IF v_key ~ '(authority|opportunityscore|fitscore|score|confidence|routequality|routeconfidence|viability|ready|truthindex|truthprobability|probability|(^|old)r[456])' THEN
    RAISE EXCEPTION 'MARKETROUTE_V1_NONFACTUAL_CLAIM_REJECTED:%',p_claim_key;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.marketroute_v1_batch_open_v1(p_batch_id uuid)
RETURNS public.marketroute_v1_migration_batches
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_batch public.marketroute_v1_migration_batches%ROWTYPE;
BEGIN
  SELECT * INTO v_batch FROM public.marketroute_v1_migration_batches WHERE id=p_batch_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_V1_MIGRATION_BATCH_NOT_FOUND'; END IF;
  IF v_batch.status<>'IMPORTING' THEN RAISE EXCEPTION 'MARKETROUTE_V1_MIGRATION_BATCH_NOT_OPEN:%',v_batch.status; END IF;
  RETURN v_batch;
END;
$$;

CREATE OR REPLACE FUNCTION public.marketroute_v1_mapping_v1(p_batch_id uuid,p_entity_kind text,p_source_table text,p_v1_id text)
RETURNS public.marketroute_v1_migration_id_map
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_batch public.marketroute_v1_migration_batches%ROWTYPE; v_map public.marketroute_v1_migration_id_map%ROWTYPE;
BEGIN
  SELECT * INTO v_batch FROM public.marketroute_v1_migration_batches WHERE id=p_batch_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_V1_MIGRATION_BATCH_NOT_FOUND'; END IF;
  SELECT * INTO v_map FROM public.marketroute_v1_migration_id_map
  WHERE target_organisation_id=v_batch.target_organisation_id AND source_system=v_batch.source_system
    AND entity_kind=upper(btrim(p_entity_kind)) AND source_table=lower(btrim(p_source_table)) AND v1_id=btrim(p_v1_id);
  RETURN v_map;
END;
$$;

CREATE OR REPLACE FUNCTION public.marketroute_v1_record_mapping_v1(
  p_batch_id uuid,p_entity_kind text,p_source_table text,p_v1_id text,p_v2_id uuid,p_record_fingerprint text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_batch public.marketroute_v1_migration_batches%ROWTYPE; v_existing public.marketroute_v1_migration_id_map%ROWTYPE;
BEGIN
  v_batch:=public.marketroute_v1_batch_open_v1(p_batch_id);
  SELECT * INTO v_existing FROM public.marketroute_v1_migration_id_map
  WHERE target_organisation_id=v_batch.target_organisation_id AND source_system=v_batch.source_system
    AND entity_kind=upper(btrim(p_entity_kind)) AND source_table=lower(btrim(p_source_table)) AND v1_id=btrim(p_v1_id);
  IF FOUND THEN
    IF v_existing.v2_id IS DISTINCT FROM p_v2_id OR v_existing.record_fingerprint IS DISTINCT FROM p_record_fingerprint THEN
      RAISE EXCEPTION 'MARKETROUTE_V1_MIGRATION_MAPPING_COLLISION';
    END IF;
    RETURN false;
  END IF;
  INSERT INTO public.marketroute_v1_migration_id_map(batch_id,target_organisation_id,source_system,entity_kind,source_table,v1_id,v2_id,record_fingerprint)
  VALUES(p_batch_id,v_batch.target_organisation_id,v_batch.source_system,upper(btrim(p_entity_kind)),lower(btrim(p_source_table)),btrim(p_v1_id),p_v2_id,p_record_fingerprint);
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.marketroute_v1_audit_v1(
  p_batch_id uuid,p_event_type text,p_entity_kind text,p_source_table text,p_v1_id text,p_v2_id uuid,p_record_fingerprint text,p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.marketroute_v1_migration_audit_events(batch_id,event_type,entity_kind,source_table,v1_id,v2_id,record_fingerprint,metadata_json)
  VALUES(p_batch_id,p_event_type,NULLIF(upper(btrim(p_entity_kind)),''),NULLIF(lower(btrim(p_source_table)),''),NULLIF(btrim(p_v1_id),''),p_v2_id,p_record_fingerprint,COALESCE(p_metadata,'{}'::jsonb))
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.marketroute_begin_v1_migration_v1(
  p_target_organisation_id uuid,p_created_by_user_id uuid,p_source_export_fingerprint text,p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_batch public.marketroute_v1_migration_batches%ROWTYPE;
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF p_source_export_fingerprint !~ '^[a-f0-9]{64}$' THEN RAISE EXCEPTION 'MARKETROUTE_V1_EXPORT_FINGERPRINT_INVALID'; END IF;
  IF jsonb_typeof(COALESCE(p_metadata,'{}'::jsonb))<>'object' THEN RAISE EXCEPTION 'MARKETROUTE_V1_BATCH_METADATA_INVALID'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.organisation_memberships WHERE organisation_id=p_target_organisation_id AND user_id=p_created_by_user_id AND status='ACTIVE' AND role IN('OWNER','ADMIN')) THEN
    RAISE EXCEPTION 'MARKETROUTE_V1_MIGRATION_CREATOR_NOT_ADMIN';
  END IF;
  SELECT * INTO v_batch FROM public.marketroute_v1_migration_batches
  WHERE target_organisation_id=p_target_organisation_id AND source_system='MARKETROUTE_V1' AND source_export_fingerprint=p_source_export_fingerprint;
  IF FOUND THEN RETURN jsonb_build_object('batchId',v_batch.id,'status',v_batch.status,'deduplicated',true); END IF;
  INSERT INTO public.marketroute_v1_migration_batches(target_organisation_id,created_by_user_id,contract_version,source_export_fingerprint,metadata_json)
  VALUES(p_target_organisation_id,p_created_by_user_id,'MRV2-V1-FACTUAL-EXPORT-1.0.0',p_source_export_fingerprint,COALESCE(p_metadata,'{}'::jsonb))
  RETURNING * INTO v_batch;
  PERFORM public.marketroute_v1_audit_v1(v_batch.id,'BATCH_STARTED',NULL,NULL,NULL,NULL,NULL,jsonb_build_object('contractVersion',v_batch.contract_version));
  RETURN jsonb_build_object('batchId',v_batch.id,'status',v_batch.status,'deduplicated',false);
END;
$$;

CREATE OR REPLACE FUNCTION public.marketroute_import_v1_company_v1(p_batch_id uuid,p_source_table text,p_v1_id text,p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp,extensions
AS $$
DECLARE v_batch public.marketroute_v1_migration_batches%ROWTYPE; v_map public.marketroute_v1_migration_id_map%ROWTYPE; v_id uuid; v_domain text; v_url text; v_name text; v_country text; v_fp text; v_node jsonb; v_new boolean;
BEGIN
  PERFORM public.marketroute_require_service_role(); v_batch:=public.marketroute_v1_batch_open_v1(p_batch_id);
  PERFORM public.marketroute_v1_assert_factual_payload_v1(p_payload);
  PERFORM public.marketroute_v1_assert_allowed_keys_v1(p_payload,ARRAY['canonicalName','canonicalDomain','websiteUrl','countryCode']);
  v_fp:=public.marketroute_v1_record_fingerprint_v1('COMPANY',p_source_table,p_v1_id,p_payload);
  v_map:=public.marketroute_v1_mapping_v1(p_batch_id,'COMPANY',p_source_table,p_v1_id);
  IF v_map.id IS NOT NULL THEN IF v_map.record_fingerprint<>v_fp THEN RAISE EXCEPTION 'MARKETROUTE_V1_COMPANY_SOURCE_CHANGED_AFTER_MAPPING'; END IF; RETURN jsonb_build_object('companyId',v_map.v2_id,'recordFingerprint',v_fp,'deduplicated',true); END IF;
  v_name:=btrim(COALESCE(p_payload->>'canonicalName','')); IF length(v_name)=0 THEN RAISE EXCEPTION 'MARKETROUTE_V1_COMPANY_NAME_REQUIRED'; END IF;
  v_domain:=NULLIF(lower(btrim(p_payload->>'canonicalDomain')),''); v_url:=NULLIF(btrim(p_payload->>'websiteUrl'),''); v_country:=NULLIF(upper(btrim(p_payload->>'countryCode')),'');
  IF v_domain IS NOT NULL AND (v_domain ~ '[/:[:space:]]' OR v_domain !~ '^[a-z0-9.-]+\.[a-z]{2,}$') THEN RAISE EXCEPTION 'MARKETROUTE_V1_COMPANY_DOMAIN_INVALID'; END IF;
  IF v_url IS NOT NULL AND v_url !~* '^https?://[^[:space:]]+$' THEN RAISE EXCEPTION 'MARKETROUTE_V1_COMPANY_WEBSITE_INVALID'; END IF;
  IF v_country IS NOT NULL AND v_country !~ '^[A-Z]{2}$' THEN RAISE EXCEPTION 'MARKETROUTE_V1_COMPANY_COUNTRY_INVALID'; END IF;
  IF v_domain IS NOT NULL THEN SELECT id INTO v_id FROM public.companies WHERE canonical_domain=v_domain; END IF;
  IF v_id IS NULL THEN INSERT INTO public.companies(canonical_name,canonical_domain,website_url,country_code,lifecycle_state) VALUES(v_name,v_domain,v_url,v_country,'ACTIVE') RETURNING id INTO v_id; END IF;
  INSERT INTO public.organisation_company_scopes(organisation_id,company_id,campaign_id,scope_kind) VALUES(v_batch.target_organisation_id,v_id,NULL,'MIGRATION') ON CONFLICT DO NOTHING;
  SELECT jsonb_build_object('nodeId',x.node_id,'nodeFingerprint',x.node_fingerprint,'deduplicated',x.deduplicated) INTO v_node FROM public.marketroute_ensure_graph_node_v1(NULL,'COMPANY',v_id,NULL,NULL,v_name,NULL,NULL,'MRV2-RELATIONSHIP-CANON-1.0.0') x;
  v_new:=public.marketroute_v1_record_mapping_v1(p_batch_id,'COMPANY',p_source_table,p_v1_id,v_id,v_fp);
  PERFORM public.marketroute_v1_audit_v1(p_batch_id,'FACTUAL_IDENTITY_IMPORTED','COMPANY',p_source_table,p_v1_id,v_id,v_fp,jsonb_build_object('graphNode',v_node));
  RETURN jsonb_build_object('companyId',v_id,'recordFingerprint',v_fp,'deduplicated',NOT v_new,'graphNode',v_node);
END;
$$;

CREATE OR REPLACE FUNCTION public.marketroute_import_v1_person_v1(p_batch_id uuid,p_source_table text,p_v1_id text,p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_batch public.marketroute_v1_migration_batches%ROWTYPE; v_map public.marketroute_v1_migration_id_map%ROWTYPE; v_id uuid; v_name text; v_canonical text; v_fp text; v_node jsonb; v_new boolean;
BEGIN
  PERFORM public.marketroute_require_service_role(); v_batch:=public.marketroute_v1_batch_open_v1(p_batch_id);
  PERFORM public.marketroute_v1_assert_factual_payload_v1(p_payload);
  PERFORM public.marketroute_v1_assert_allowed_keys_v1(p_payload,ARRAY['displayName','canonicalName']);
  v_fp:=public.marketroute_v1_record_fingerprint_v1('PERSON',p_source_table,p_v1_id,p_payload);
  v_map:=public.marketroute_v1_mapping_v1(p_batch_id,'PERSON',p_source_table,p_v1_id);
  IF v_map.id IS NOT NULL THEN IF v_map.record_fingerprint<>v_fp THEN RAISE EXCEPTION 'MARKETROUTE_V1_PERSON_SOURCE_CHANGED_AFTER_MAPPING'; END IF; RETURN jsonb_build_object('personId',v_map.v2_id,'recordFingerprint',v_fp,'deduplicated',true); END IF;
  v_name:=btrim(COALESCE(p_payload->>'displayName','')); IF length(v_name)=0 THEN RAISE EXCEPTION 'MARKETROUTE_V1_PERSON_NAME_REQUIRED'; END IF; v_canonical:=NULLIF(btrim(p_payload->>'canonicalName'),'');
  INSERT INTO public.people(display_name,canonical_name,lifecycle_state) VALUES(v_name,v_canonical,'ACTIVE') RETURNING id INTO v_id;
  SELECT jsonb_build_object('nodeId',x.node_id,'nodeFingerprint',x.node_fingerprint,'deduplicated',x.deduplicated) INTO v_node FROM public.marketroute_ensure_graph_node_v1(NULL,'PERSON',NULL,v_id,NULL,COALESCE(v_canonical,v_name),NULL,NULL,'MRV2-RELATIONSHIP-CANON-1.0.0') x;
  v_new:=public.marketroute_v1_record_mapping_v1(p_batch_id,'PERSON',p_source_table,p_v1_id,v_id,v_fp);
  PERFORM public.marketroute_v1_audit_v1(p_batch_id,'FACTUAL_IDENTITY_IMPORTED','PERSON',p_source_table,p_v1_id,v_id,v_fp,jsonb_build_object('graphNode',v_node));
  RETURN jsonb_build_object('personId',v_id,'recordFingerprint',v_fp,'deduplicated',NOT v_new,'graphNode',v_node);
END;
$$;

CREATE OR REPLACE FUNCTION public.marketroute_import_v1_access_point_v1(p_batch_id uuid,p_source_table text,p_v1_id text,p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_batch public.marketroute_v1_migration_batches%ROWTYPE; v_map public.marketroute_v1_migration_id_map%ROWTYPE; v_fp text; v_kind text; v_value text; v_stable text; v_label text; v_node record; v_new boolean;
BEGIN
  PERFORM public.marketroute_require_service_role(); v_batch:=public.marketroute_v1_batch_open_v1(p_batch_id);
  PERFORM public.marketroute_v1_assert_factual_payload_v1(p_payload);
  PERFORM public.marketroute_v1_assert_allowed_keys_v1(p_payload,ARRAY['accessPointKind','canonicalValue','stableKey','label']);
  v_fp:=public.marketroute_v1_record_fingerprint_v1('ACCESS_POINT',p_source_table,p_v1_id,p_payload); v_map:=public.marketroute_v1_mapping_v1(p_batch_id,'ACCESS_POINT',p_source_table,p_v1_id);
  IF v_map.id IS NOT NULL THEN IF v_map.record_fingerprint<>v_fp THEN RAISE EXCEPTION 'MARKETROUTE_V1_ACCESS_POINT_SOURCE_CHANGED_AFTER_MAPPING'; END IF; RETURN jsonb_build_object('accessPointId',v_map.v2_id,'recordFingerprint',v_fp,'deduplicated',true); END IF;
  v_kind:=upper(btrim(COALESCE(p_payload->>'accessPointKind',''))); v_value:=btrim(COALESCE(p_payload->>'canonicalValue','')); v_stable:=lower(btrim(COALESCE(p_payload->>'stableKey',''))); v_label:=NULLIF(btrim(p_payload->>'label'),'');
  IF v_kind NOT IN('CONTACT_FORM','GENERIC_EMAIL','SWITCHBOARD','DEPARTMENT_EMAIL','DEPARTMENT_FORM','PERSONAL_EMAIL','LINKEDIN','PERSONAL_PHONE','OTHER') THEN RAISE EXCEPTION 'MARKETROUTE_V1_ACCESS_POINT_KIND_INVALID'; END IF;
  IF length(v_value)=0 OR length(v_stable)=0 THEN RAISE EXCEPTION 'MARKETROUTE_V1_ACCESS_POINT_VALUE_REQUIRED'; END IF;
  SELECT * INTO v_node FROM public.marketroute_ensure_graph_node_v1(v_batch.target_organisation_id,'ACCESS_POINT',NULL,NULL,v_stable,v_label,v_kind,v_value,'MRV2-RELATIONSHIP-CANON-1.0.0');
  v_new:=public.marketroute_v1_record_mapping_v1(p_batch_id,'ACCESS_POINT',p_source_table,p_v1_id,v_node.node_id,v_fp);
  PERFORM public.marketroute_v1_audit_v1(p_batch_id,'FACTUAL_CONTACT_CHANNEL_IMPORTED','ACCESS_POINT',p_source_table,p_v1_id,v_node.node_id,v_fp,jsonb_build_object('accessPointKind',v_kind));
  RETURN jsonb_build_object('accessPointId',v_node.node_id,'recordFingerprint',v_fp,'deduplicated',NOT v_new);
END;
$$;

CREATE OR REPLACE FUNCTION public.marketroute_import_v1_seller_business_v1(p_batch_id uuid,p_source_table text,p_v1_id text,p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_batch public.marketroute_v1_migration_batches%ROWTYPE; v_map public.marketroute_v1_migration_id_map%ROWTYPE; v_id uuid; v_name text; v_domain text; v_url text; v_fp text; v_new boolean;
BEGIN
  PERFORM public.marketroute_require_service_role(); v_batch:=public.marketroute_v1_batch_open_v1(p_batch_id);
  PERFORM public.marketroute_v1_assert_factual_payload_v1(p_payload); PERFORM public.marketroute_v1_assert_allowed_keys_v1(p_payload,ARRAY['name','canonicalDomain','websiteUrl']);
  v_fp:=public.marketroute_v1_record_fingerprint_v1('SELLER_BUSINESS',p_source_table,p_v1_id,p_payload); v_map:=public.marketroute_v1_mapping_v1(p_batch_id,'SELLER_BUSINESS',p_source_table,p_v1_id);
  IF v_map.id IS NOT NULL THEN IF v_map.record_fingerprint<>v_fp THEN RAISE EXCEPTION 'MARKETROUTE_V1_SELLER_SOURCE_CHANGED_AFTER_MAPPING'; END IF; RETURN jsonb_build_object('sellerBusinessId',v_map.v2_id,'recordFingerprint',v_fp,'deduplicated',true); END IF;
  v_name:=btrim(COALESCE(p_payload->>'name','')); v_domain:=NULLIF(lower(btrim(p_payload->>'canonicalDomain')),''); v_url:=NULLIF(btrim(p_payload->>'websiteUrl'),''); IF length(v_name)=0 THEN RAISE EXCEPTION 'MARKETROUTE_V1_SELLER_NAME_REQUIRED'; END IF;
  IF v_domain IS NOT NULL AND (v_domain ~ '[/:[:space:]]' OR v_domain !~ '^[a-z0-9.-]+\.[a-z]{2,}$') THEN RAISE EXCEPTION 'MARKETROUTE_V1_SELLER_DOMAIN_INVALID'; END IF; IF v_url IS NOT NULL AND v_url !~* '^https?://[^[:space:]]+$' THEN RAISE EXCEPTION 'MARKETROUTE_V1_SELLER_WEBSITE_INVALID'; END IF;
  IF v_domain IS NOT NULL THEN SELECT id INTO v_id FROM public.seller_businesses WHERE organisation_id=v_batch.target_organisation_id AND canonical_domain=v_domain; END IF;
  IF v_id IS NULL THEN INSERT INTO public.seller_businesses(organisation_id,name,canonical_domain,website_url,lifecycle_state,created_by) VALUES(v_batch.target_organisation_id,v_name,v_domain,v_url,'ACTIVE',v_batch.created_by_user_id) RETURNING id INTO v_id; END IF;
  v_new:=public.marketroute_v1_record_mapping_v1(p_batch_id,'SELLER_BUSINESS',p_source_table,p_v1_id,v_id,v_fp); PERFORM public.marketroute_v1_audit_v1(p_batch_id,'SELLER_IDENTITY_IMPORTED','SELLER_BUSINESS',p_source_table,p_v1_id,v_id,v_fp,'{}'::jsonb);
  RETURN jsonb_build_object('sellerBusinessId',v_id,'recordFingerprint',v_fp,'deduplicated',NOT v_new);
END;
$$;

CREATE OR REPLACE FUNCTION public.marketroute_import_v1_seller_source_v1(p_batch_id uuid,p_source_table text,p_v1_id text,p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_batch public.marketroute_v1_migration_batches%ROWTYPE; v_map public.marketroute_v1_migration_id_map%ROWTYPE; v_seller public.marketroute_v1_migration_id_map%ROWTYPE; v_result jsonb; v_id uuid; v_fp text; v_new boolean;
BEGIN
  PERFORM public.marketroute_require_service_role(); v_batch:=public.marketroute_v1_batch_open_v1(p_batch_id); PERFORM public.marketroute_v1_assert_factual_payload_v1(p_payload);
  PERFORM public.marketroute_v1_assert_allowed_keys_v1(p_payload,ARRAY['sellerBusinessSourceTable','sellerBusinessV1Id','content']);
  v_fp:=public.marketroute_v1_record_fingerprint_v1('SELLER_SOURCE_MATERIAL',p_source_table,p_v1_id,p_payload); v_map:=public.marketroute_v1_mapping_v1(p_batch_id,'SELLER_SOURCE_MATERIAL',p_source_table,p_v1_id);
  IF v_map.id IS NOT NULL THEN IF v_map.record_fingerprint<>v_fp THEN RAISE EXCEPTION 'MARKETROUTE_V1_SELLER_MATERIAL_CHANGED_AFTER_MAPPING'; END IF; RETURN jsonb_build_object('sourceMaterialId',v_map.v2_id,'recordFingerprint',v_fp,'deduplicated',true); END IF;
  v_seller:=public.marketroute_v1_mapping_v1(p_batch_id,'SELLER_BUSINESS',p_payload->>'sellerBusinessSourceTable',p_payload->>'sellerBusinessV1Id'); IF v_seller.id IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_V1_SELLER_MAPPING_REQUIRED'; END IF;
  v_result:=public.marketroute_record_seller_genome_source_v1(v_batch.target_organisation_id,v_seller.v2_id,'IMPORT',p_payload->'content',v_batch.created_by_user_id); v_id:=(v_result->>'sourceMaterialId')::uuid;
  v_new:=public.marketroute_v1_record_mapping_v1(p_batch_id,'SELLER_SOURCE_MATERIAL',p_source_table,p_v1_id,v_id,v_fp); PERFORM public.marketroute_v1_audit_v1(p_batch_id,'SELLER_SOURCE_MATERIAL_IMPORTED','SELLER_SOURCE_MATERIAL',p_source_table,p_v1_id,v_id,v_fp,jsonb_build_object('sellerBusinessId',v_seller.v2_id));
  RETURN jsonb_build_object('sourceMaterialId',v_id,'recordFingerprint',v_fp,'deduplicated',NOT v_new);
END;
$$;

CREATE OR REPLACE FUNCTION public.marketroute_import_v1_campaign_v1(p_batch_id uuid,p_source_table text,p_v1_id text,p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_batch public.marketroute_v1_migration_batches%ROWTYPE; v_map public.marketroute_v1_migration_id_map%ROWTYPE; v_seller public.marketroute_v1_migration_id_map%ROWTYPE; v_id uuid; v_fp text; v_new boolean; v_name text;
BEGIN
  PERFORM public.marketroute_require_service_role(); v_batch:=public.marketroute_v1_batch_open_v1(p_batch_id); PERFORM public.marketroute_v1_assert_factual_payload_v1(p_payload);
  PERFORM public.marketroute_v1_assert_allowed_keys_v1(p_payload,ARRAY['sellerBusinessSourceTable','sellerBusinessV1Id','name','objectiveText']);
  v_fp:=public.marketroute_v1_record_fingerprint_v1('CAMPAIGN',p_source_table,p_v1_id,p_payload); v_map:=public.marketroute_v1_mapping_v1(p_batch_id,'CAMPAIGN',p_source_table,p_v1_id);
  IF v_map.id IS NOT NULL THEN IF v_map.record_fingerprint<>v_fp THEN RAISE EXCEPTION 'MARKETROUTE_V1_CAMPAIGN_CHANGED_AFTER_MAPPING'; END IF; RETURN jsonb_build_object('campaignId',v_map.v2_id,'recordFingerprint',v_fp,'deduplicated',true); END IF;
  v_seller:=public.marketroute_v1_mapping_v1(p_batch_id,'SELLER_BUSINESS',p_payload->>'sellerBusinessSourceTable',p_payload->>'sellerBusinessV1Id'); IF v_seller.id IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_V1_CAMPAIGN_SELLER_MAPPING_REQUIRED'; END IF;
  v_name:=btrim(COALESCE(p_payload->>'name','')); IF length(v_name)=0 THEN RAISE EXCEPTION 'MARKETROUTE_V1_CAMPAIGN_NAME_REQUIRED'; END IF;
  INSERT INTO public.campaigns(organisation_id,seller_business_id,name,workflow_state,objective_text,created_by) VALUES(v_batch.target_organisation_id,v_seller.v2_id,v_name,'DRAFT',NULLIF(btrim(p_payload->>'objectiveText'),''),v_batch.created_by_user_id) RETURNING id INTO v_id;
  v_new:=public.marketroute_v1_record_mapping_v1(p_batch_id,'CAMPAIGN',p_source_table,p_v1_id,v_id,v_fp); PERFORM public.marketroute_v1_audit_v1(p_batch_id,'CAMPAIGN_DEFINITION_IMPORTED_AS_DRAFT','CAMPAIGN',p_source_table,p_v1_id,v_id,v_fp,jsonb_build_object('workflowState','DRAFT'));
  RETURN jsonb_build_object('campaignId',v_id,'recordFingerprint',v_fp,'deduplicated',NOT v_new,'workflowState','DRAFT');
END;
$$;

CREATE OR REPLACE FUNCTION public.marketroute_import_v1_campaign_scope_v1(p_batch_id uuid,p_source_table text,p_v1_id text,p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_batch public.marketroute_v1_migration_batches%ROWTYPE; v_map public.marketroute_v1_migration_id_map%ROWTYPE; v_campaign public.marketroute_v1_migration_id_map%ROWTYPE; v_company public.marketroute_v1_migration_id_map%ROWTYPE; v_id uuid; v_fp text; v_new boolean;
BEGIN
  PERFORM public.marketroute_require_service_role(); v_batch:=public.marketroute_v1_batch_open_v1(p_batch_id); PERFORM public.marketroute_v1_assert_factual_payload_v1(p_payload);
  PERFORM public.marketroute_v1_assert_allowed_keys_v1(p_payload,ARRAY['campaignSourceTable','campaignV1Id','companySourceTable','companyV1Id']);
  v_fp:=public.marketroute_v1_record_fingerprint_v1('CAMPAIGN_SCOPE',p_source_table,p_v1_id,p_payload); v_map:=public.marketroute_v1_mapping_v1(p_batch_id,'CAMPAIGN_SCOPE',p_source_table,p_v1_id);
  IF v_map.id IS NOT NULL THEN IF v_map.record_fingerprint<>v_fp THEN RAISE EXCEPTION 'MARKETROUTE_V1_CAMPAIGN_SCOPE_CHANGED_AFTER_MAPPING'; END IF; RETURN jsonb_build_object('scopeId',v_map.v2_id,'recordFingerprint',v_fp,'deduplicated',true); END IF;
  v_campaign:=public.marketroute_v1_mapping_v1(p_batch_id,'CAMPAIGN',p_payload->>'campaignSourceTable',p_payload->>'campaignV1Id'); v_company:=public.marketroute_v1_mapping_v1(p_batch_id,'COMPANY',p_payload->>'companySourceTable',p_payload->>'companyV1Id');
  IF v_campaign.id IS NULL OR v_company.id IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_V1_CAMPAIGN_SCOPE_PARENT_MAPPING_REQUIRED'; END IF;
  SELECT id INTO v_id FROM public.organisation_company_scopes WHERE organisation_id=v_batch.target_organisation_id AND campaign_id=v_campaign.v2_id AND company_id=v_company.v2_id AND scope_kind='CAMPAIGN';
  IF v_id IS NULL THEN INSERT INTO public.organisation_company_scopes(organisation_id,company_id,campaign_id,scope_kind) VALUES(v_batch.target_organisation_id,v_company.v2_id,v_campaign.v2_id,'CAMPAIGN') RETURNING id INTO v_id; END IF;
  v_new:=public.marketroute_v1_record_mapping_v1(p_batch_id,'CAMPAIGN_SCOPE',p_source_table,p_v1_id,v_id,v_fp); PERFORM public.marketroute_v1_audit_v1(p_batch_id,'CAMPAIGN_SCOPE_IMPORTED','CAMPAIGN_SCOPE',p_source_table,p_v1_id,v_id,v_fp,jsonb_build_object('campaignId',v_campaign.v2_id,'companyId',v_company.v2_id));
  RETURN jsonb_build_object('scopeId',v_id,'recordFingerprint',v_fp,'deduplicated',NOT v_new);
END;
$$;

CREATE OR REPLACE FUNCTION public.marketroute_v1_resolve_subject_v1(p_batch_id uuid,p_subject jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_kind text:=upper(btrim(COALESCE(p_subject->>'entityKind',''))); v_map public.marketroute_v1_migration_id_map%ROWTYPE; v_subject_type text;
BEGIN
  IF jsonb_typeof(p_subject)<>'object' THEN RAISE EXCEPTION 'MARKETROUTE_V1_EVIDENCE_SUBJECT_INVALID'; END IF;
  IF v_kind='ACCESS_POINT' THEN v_subject_type:='CHANNEL'; ELSE v_subject_type:=v_kind; END IF;
  IF v_subject_type NOT IN('COMPANY','PERSON','SELLER_BUSINESS','CAMPAIGN','CHANNEL') THEN RAISE EXCEPTION 'MARKETROUTE_V1_EVIDENCE_SUBJECT_KIND_INVALID'; END IF;
  v_map:=public.marketroute_v1_mapping_v1(p_batch_id,v_kind,p_subject->>'sourceTable',p_subject->>'v1Id'); IF v_map.id IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_V1_EVIDENCE_SUBJECT_MAPPING_REQUIRED'; END IF;
  RETURN jsonb_build_object('subjectType',v_subject_type,'subjectId',v_map.v2_id,'entityKind',v_kind);
END;
$$;

CREATE OR REPLACE FUNCTION public.marketroute_v1_resolve_claim_object_refs_v1(p_batch_id uuid,p_object jsonb,p_refs jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_out jsonb:=COALESCE(p_object,'{}'::jsonb); v_ref jsonb; v_map public.marketroute_v1_migration_id_map%ROWTYPE; v_path text;
BEGIN
  IF jsonb_typeof(v_out)<>'object' THEN RAISE EXCEPTION 'MARKETROUTE_V1_CLAIM_OBJECT_MUST_BE_OBJECT'; END IF;
  IF p_refs IS NULL THEN RETURN v_out; END IF; IF jsonb_typeof(p_refs)<>'array' THEN RAISE EXCEPTION 'MARKETROUTE_V1_CLAIM_OBJECT_REFS_ARRAY_REQUIRED'; END IF;
  FOR v_ref IN SELECT value FROM jsonb_array_elements(p_refs) LOOP
    PERFORM public.marketroute_v1_assert_allowed_keys_v1(v_ref,ARRAY['key','entityKind','sourceTable','v1Id']); v_path:=btrim(COALESCE(v_ref->>'key','')); IF v_path !~ '^[A-Za-z][A-Za-z0-9_]{0,79}$' THEN RAISE EXCEPTION 'MARKETROUTE_V1_CLAIM_REF_KEY_INVALID'; END IF;
    v_map:=public.marketroute_v1_mapping_v1(p_batch_id,upper(v_ref->>'entityKind'),v_ref->>'sourceTable',v_ref->>'v1Id'); IF v_map.id IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_V1_CLAIM_OBJECT_REF_MAPPING_REQUIRED:%',v_path; END IF;
    v_out:=jsonb_set(v_out,ARRAY[v_path],to_jsonb(v_map.v2_id::text),true);
  END LOOP;
  RETURN v_out;
END;
$$;

CREATE OR REPLACE FUNCTION public.marketroute_import_v1_evidence_v1(p_batch_id uuid,p_source_table text,p_v1_id text,p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp,extensions
AS $$
DECLARE
  v_batch public.marketroute_v1_migration_batches%ROWTYPE; v_map public.marketroute_v1_migration_id_map%ROWTYPE; v_subject jsonb; v_source jsonb; v_acq jsonb; v_evidence jsonb; v_claim jsonb;
  v_fp text; v_source_fp text; v_evidence_fp text; v_claim_fp text; v_stable text; v_family text; v_domain text; v_source_result record; v_claim_result record; v_claim_id uuid; v_claim_object jsonb; v_source_map_new boolean; v_evidence_map_new boolean; v_claim_map_new boolean; v_claim_source_table text; v_claim_v1_id text;
BEGIN
  PERFORM public.marketroute_require_service_role(); v_batch:=public.marketroute_v1_batch_open_v1(p_batch_id); PERFORM public.marketroute_v1_assert_factual_payload_v1(p_payload);
  PERFORM public.marketroute_v1_assert_allowed_keys_v1(p_payload,ARRAY['subject','source','acquisition','evidence','claim']);
  v_fp:=public.marketroute_v1_record_fingerprint_v1('EVIDENCE',p_source_table,p_v1_id,p_payload); v_map:=public.marketroute_v1_mapping_v1(p_batch_id,'EVIDENCE',p_source_table,p_v1_id);
  IF v_map.id IS NOT NULL THEN IF v_map.record_fingerprint<>v_fp THEN RAISE EXCEPTION 'MARKETROUTE_V1_EVIDENCE_CHANGED_AFTER_MAPPING'; END IF; RETURN jsonb_build_object('evidenceItemId',v_map.v2_id,'recordFingerprint',v_fp,'deduplicated',true); END IF;
  v_subject:=public.marketroute_v1_resolve_subject_v1(p_batch_id,p_payload->'subject'); v_source:=p_payload->'source'; v_acq:=COALESCE(p_payload->'acquisition','{}'::jsonb); v_evidence:=p_payload->'evidence'; v_claim:=p_payload->'claim';
  PERFORM public.marketroute_v1_assert_allowed_keys_v1(v_source,ARRAY['sourceTable','v1Id','sourceKind','canonicalUrl','publisherDomain','title','publishedAt','stableLocator','dependenceFamilyKey','metadata']);
  PERFORM public.marketroute_v1_assert_allowed_keys_v1(v_acq,ARRAY['acquiredAt','observedContentFingerprint','httpStatus','rawLocator','parserVersion','requestId','metadata']);
  PERFORM public.marketroute_v1_assert_allowed_keys_v1(v_evidence,ARRAY['evidenceKind','excerptText','structuredValue','observedAt','originPublishedAt','extractionVersion']);
  IF v_claim IS NOT NULL THEN PERFORM public.marketroute_v1_assert_allowed_keys_v1(v_claim,ARRAY['sourceTable','v1Id','claimKey','predicate','object','objectRefs','canonicalValueText','polarity']); PERFORM public.marketroute_v1_assert_claim_key_factual_v1(v_claim->>'claimKey'); END IF;
  IF COALESCE(v_source->>'sourceKind','') NOT IN('WEB','DOCUMENT','API','REGISTRY','USER_PROVIDED','INTERNAL','OTHER') THEN RAISE EXCEPTION 'MARKETROUTE_V1_SOURCE_KIND_INVALID'; END IF;
  IF COALESCE(v_evidence->>'evidenceKind','') NOT IN('QUOTE','STRUCTURED_FIELD','OBSERVATION','DOCUMENT_SECTION','REGISTRY_RECORD','USER_ASSERTION','OTHER') THEN RAISE EXCEPTION 'MARKETROUTE_V1_EVIDENCE_KIND_INVALID'; END IF;
  IF NULLIF(btrim(v_evidence->>'excerptText'),'') IS NULL AND (NOT (v_evidence ? 'structuredValue') OR v_evidence->'structuredValue'='null'::jsonb) THEN RAISE EXCEPTION 'MARKETROUTE_V1_EVIDENCE_CONTENT_REQUIRED'; END IF;
  v_stable:=btrim(COALESCE(v_source->>'stableLocator',v_source->>'canonicalUrl','v1:'||(v_source->>'sourceTable')||':'||(v_source->>'v1Id'))); v_family:=btrim(COALESCE(v_source->>'dependenceFamilyKey','v1-source:'||(v_source->>'sourceTable')||':'||(v_source->>'v1Id'))); v_domain:=NULLIF(lower(btrim(v_source->>'publisherDomain')),'');
  v_source_fp:=encode(extensions.digest(concat_ws('|','MRV2-V1-MIGRATED-SOURCE-1.0.0',v_source->>'sourceKind',COALESCE(v_source->>'canonicalUrl','-'),COALESCE(v_domain,'-'),v_stable,v_family),'sha256'),'hex');
  v_evidence_fp:=encode(extensions.digest(concat_ws('|','MRV2-V1-MIGRATED-EVIDENCE-1.0.0',v_source_fp,v_subject->>'subjectType',v_subject->>'subjectId',v_evidence->>'evidenceKind',COALESCE(v_evidence->>'excerptText','-'),COALESCE((v_evidence->'structuredValue')::text,'-'),COALESCE(v_evidence->>'observedAt','-'),COALESCE(v_evidence->>'originPublishedAt','-'),v_family),'sha256'),'hex');
  SELECT * INTO v_source_result FROM public.marketroute_ingest_evidence_v1(
    v_source->>'sourceKind',NULLIF(v_source->>'canonicalUrl',''),v_domain,NULLIF(v_source->>'title',''),NULLIF(v_source->>'publishedAt','')::timestamptz,
    v_stable,v_source_fp,v_family,'MRV2-V1-MIGRATION-NORM-1.0.0',COALESCE(v_source->'metadata','{}'::jsonb)||jsonb_build_object('migrationBatchId',p_batch_id,'v1SourceTable',v_source->>'sourceTable','v1SourceId',v_source->>'v1Id'),
    COALESCE(NULLIF(v_acq->>'acquiredAt','')::timestamptz,now()),'IMPORT',NULLIF(v_acq->>'observedContentFingerprint',''),NULLIF(v_acq->>'httpStatus','')::integer,NULLIF(v_acq->>'rawLocator',''),COALESCE(NULLIF(v_acq->>'parserVersion',''),'MRV2-V1-MIGRATION-1.0.0'),NULLIF(v_acq->>'requestId',''),COALESCE(v_acq->'metadata','{}'::jsonb),
    v_batch.target_organisation_id,v_subject->>'subjectType',(v_subject->>'subjectId')::uuid,v_evidence->>'evidenceKind',NULLIF(v_evidence->>'excerptText',''),v_evidence->'structuredValue',COALESCE(NULLIF(v_evidence->>'observedAt','')::timestamptz,COALESCE(NULLIF(v_acq->>'acquiredAt','')::timestamptz,now())),NULLIF(v_evidence->>'originPublishedAt','')::timestamptz,
    'MIGRATED',COALESCE(NULLIF(v_evidence->>'extractionVersion',''),'MRV2-V1-MIGRATION-1.0.0'),v_evidence_fp,'MRV2-V1-MIGRATED-EVIDENCE-FP-1.0.0'
  );
  v_evidence_map_new:=public.marketroute_v1_record_mapping_v1(p_batch_id,'EVIDENCE',p_source_table,p_v1_id,v_source_result.evidence_item_id,v_fp);
  v_source_map_new:=public.marketroute_v1_record_mapping_v1(p_batch_id,'SOURCE',v_source->>'sourceTable',v_source->>'v1Id',v_source_result.source_id,public.marketroute_v1_record_fingerprint_v1('SOURCE',v_source->>'sourceTable',v_source->>'v1Id',v_source));
  IF v_claim IS NOT NULL THEN
    v_claim_object:=public.marketroute_v1_resolve_claim_object_refs_v1(p_batch_id,COALESCE(v_claim->'object','{}'::jsonb),v_claim->'objectRefs');
    v_claim_fp:=encode(extensions.digest(concat_ws('|','MRV2-V1-MIGRATED-CLAIM-1.0.0',v_batch.target_organisation_id::text,v_subject->>'subjectType',v_subject->>'subjectId',v_claim->>'claimKey',v_claim->>'predicate',v_claim_object::text,COALESCE(v_claim->>'canonicalValueText','-')),'sha256'),'hex');
    SELECT * INTO v_claim_result FROM public.marketroute_record_claim_evidence_v1(v_batch.target_organisation_id,v_subject->>'subjectType',(v_subject->>'subjectId')::uuid,v_claim->>'claimKey',v_claim->>'predicate',v_claim_object,NULLIF(v_claim->>'canonicalValueText',''),v_claim_fp,'MRV2-V1-MIGRATED-CLAIM-FP-1.0.0',v_source_result.evidence_item_id,COALESCE(v_claim->>'polarity','SUPPORTS'),'MIGRATED','MRV2-V1-MIGRATION-1.0.0');
    v_claim_source_table:=COALESCE(NULLIF(v_claim->>'sourceTable',''),p_source_table); v_claim_v1_id:=COALESCE(NULLIF(v_claim->>'v1Id',''),p_v1_id||':claim');
    v_claim_id:=v_claim_result.claim_id;
    v_claim_map_new:=public.marketroute_v1_record_mapping_v1(p_batch_id,'CLAIM',v_claim_source_table,v_claim_v1_id,v_claim_id,public.marketroute_v1_record_fingerprint_v1('CLAIM',v_claim_source_table,v_claim_v1_id,v_claim));
  END IF;
  PERFORM public.marketroute_v1_audit_v1(p_batch_id,'EVIDENCE_IMPORTED','EVIDENCE',p_source_table,p_v1_id,v_source_result.evidence_item_id,v_fp,jsonb_build_object('sourceId',v_source_result.source_id,'claimId',v_claim_id,'extractionMethod','MIGRATED'));
  RETURN jsonb_build_object('sourceId',v_source_result.source_id,'evidenceItemId',v_source_result.evidence_item_id,'claimId',v_claim_id,'recordFingerprint',v_fp,'deduplicated',NOT v_evidence_map_new);
END;
$$;

CREATE OR REPLACE FUNCTION public.marketroute_import_v1_historical_research_v1(p_batch_id uuid,p_source_table text,p_v1_id text,p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp,extensions
AS $$
DECLARE v_batch public.marketroute_v1_migration_batches%ROWTYPE; v_map public.marketroute_v1_migration_id_map%ROWTYPE; v_subject jsonb; v_fp text; v_source_fp text; v_evidence_fp text; v_result record; v_new boolean;
BEGIN
  PERFORM public.marketroute_require_service_role(); v_batch:=public.marketroute_v1_batch_open_v1(p_batch_id); PERFORM public.marketroute_v1_assert_factual_payload_v1(p_payload);
  PERFORM public.marketroute_v1_assert_allowed_keys_v1(p_payload,ARRAY['subject','text','observedAt','sourceLabel','metadata']);
  v_fp:=public.marketroute_v1_record_fingerprint_v1('HISTORICAL_RESEARCH',p_source_table,p_v1_id,p_payload); v_map:=public.marketroute_v1_mapping_v1(p_batch_id,'HISTORICAL_RESEARCH',p_source_table,p_v1_id);
  IF v_map.id IS NOT NULL THEN IF v_map.record_fingerprint<>v_fp THEN RAISE EXCEPTION 'MARKETROUTE_V1_HISTORICAL_RESEARCH_CHANGED_AFTER_MAPPING'; END IF; RETURN jsonb_build_object('evidenceItemId',v_map.v2_id,'recordFingerprint',v_fp,'deduplicated',true); END IF;
  v_subject:=public.marketroute_v1_resolve_subject_v1(p_batch_id,p_payload->'subject'); IF length(btrim(COALESCE(p_payload->>'text','')))=0 THEN RAISE EXCEPTION 'MARKETROUTE_V1_HISTORICAL_RESEARCH_TEXT_REQUIRED'; END IF;
  v_source_fp:=encode(extensions.digest(concat_ws('|','MRV2-V1-HISTORICAL-SOURCE-1.0.0',lower(btrim(p_source_table)),btrim(p_v1_id)),'sha256'),'hex');
  v_evidence_fp:=encode(extensions.digest(concat_ws('|','MRV2-V1-HISTORICAL-EVIDENCE-1.0.0',v_source_fp,v_subject->>'subjectType',v_subject->>'subjectId',p_payload->>'text',COALESCE(p_payload->>'observedAt','-')),'sha256'),'hex');
  SELECT * INTO v_result FROM public.marketroute_ingest_evidence_v1('INTERNAL',NULL,NULL,COALESCE(NULLIF(p_payload->>'sourceLabel',''),'MarketRoute V1 historical research'),NULL,'v1-historical:'||lower(btrim(p_source_table))||':'||btrim(p_v1_id),v_source_fp,'v1-historical:'||lower(btrim(p_source_table))||':'||btrim(p_v1_id),'MRV2-V1-MIGRATION-NORM-1.0.0',COALESCE(p_payload->'metadata','{}'::jsonb)||jsonb_build_object('migrationBatchId',p_batch_id,'v1SourceTable',p_source_table,'v1SourceId',p_v1_id),COALESCE(NULLIF(p_payload->>'observedAt','')::timestamptz,now()),'IMPORT',NULL,NULL,'v1-historical:'||btrim(p_v1_id),'MRV2-V1-MIGRATION-1.0.0',NULL,'{}'::jsonb,v_batch.target_organisation_id,v_subject->>'subjectType',(v_subject->>'subjectId')::uuid,'DOCUMENT_SECTION',p_payload->>'text',NULL,COALESCE(NULLIF(p_payload->>'observedAt','')::timestamptz,now()),NULL,'MIGRATED','MRV2-V1-MIGRATION-1.0.0',v_evidence_fp,'MRV2-V1-MIGRATED-EVIDENCE-FP-1.0.0');
  v_new:=public.marketroute_v1_record_mapping_v1(p_batch_id,'HISTORICAL_RESEARCH',p_source_table,p_v1_id,v_result.evidence_item_id,v_fp); PERFORM public.marketroute_v1_audit_v1(p_batch_id,'HISTORICAL_RESEARCH_IMPORTED_AS_EVIDENCE','HISTORICAL_RESEARCH',p_source_table,p_v1_id,v_result.evidence_item_id,v_fp,jsonb_build_object('sourceId',v_result.source_id));
  RETURN jsonb_build_object('evidenceItemId',v_result.evidence_item_id,'recordFingerprint',v_fp,'deduplicated',NOT v_new);
END;
$$;

CREATE OR REPLACE FUNCTION public.marketroute_reject_v1_migration_record_v1(p_batch_id uuid,p_entity_kind text,p_source_table text,p_v1_id text,p_reason_code text,p_payload jsonb,p_rejected_field_keys text[] DEFAULT '{}')
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_id uuid; v_fp text;
BEGIN
  PERFORM public.marketroute_require_service_role(); PERFORM public.marketroute_v1_batch_open_v1(p_batch_id);
  v_fp:=public.marketroute_v1_record_fingerprint_v1(p_entity_kind,p_source_table,p_v1_id,COALESCE(p_payload,'{}'::jsonb));
  INSERT INTO public.marketroute_v1_migration_rejections(batch_id,entity_kind,source_table,v1_id,reason_code,rejected_field_keys,payload_fingerprint)
  VALUES(p_batch_id,upper(btrim(p_entity_kind)),lower(btrim(p_source_table)),btrim(p_v1_id),btrim(p_reason_code),COALESCE(p_rejected_field_keys,'{}'),v_fp) RETURNING id INTO v_id;
  PERFORM public.marketroute_v1_audit_v1(p_batch_id,'RECORD_REJECTED',p_entity_kind,p_source_table,p_v1_id,NULL,v_fp,jsonb_build_object('reasonCode',p_reason_code,'rejectedFieldKeys',COALESCE(p_rejected_field_keys,'{}')));
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.marketroute_complete_v1_migration_v1(p_batch_id uuid,p_metadata jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_batch public.marketroute_v1_migration_batches%ROWTYPE; v_maps int; v_rejections int; v_companies int; v_evidence int;
BEGIN
  PERFORM public.marketroute_require_service_role(); v_batch:=public.marketroute_v1_batch_open_v1(p_batch_id);
  SELECT count(*) INTO v_maps FROM public.marketroute_v1_migration_id_map WHERE batch_id=p_batch_id; SELECT count(*) INTO v_rejections FROM public.marketroute_v1_migration_rejections WHERE batch_id=p_batch_id; SELECT count(*) INTO v_companies FROM public.marketroute_v1_migration_id_map WHERE batch_id=p_batch_id AND entity_kind='COMPANY'; SELECT count(*) INTO v_evidence FROM public.marketroute_v1_migration_id_map WHERE batch_id=p_batch_id AND entity_kind IN('EVIDENCE','HISTORICAL_RESEARCH');
  UPDATE public.marketroute_v1_migration_batches SET status='COMPLETED',completed_at=now(),metadata_json=metadata_json||COALESCE(p_metadata,'{}'::jsonb)||jsonb_build_object('mappingCount',v_maps,'rejectionCount',v_rejections,'companyCount',v_companies,'evidenceCount',v_evidence) WHERE id=p_batch_id;
  PERFORM public.marketroute_v1_audit_v1(p_batch_id,'BATCH_COMPLETED',NULL,NULL,NULL,NULL,NULL,jsonb_build_object('mappingCount',v_maps,'rejectionCount',v_rejections,'companyCount',v_companies,'evidenceCount',v_evidence,'authorityImported',false,'truthImported',false,'workflowImported',false));
  RETURN jsonb_build_object('batchId',p_batch_id,'status','COMPLETED','mappingCount',v_maps,'rejectionCount',v_rejections,'companyCount',v_companies,'evidenceCount',v_evidence,'nextStep','RECOMPUTE_V2_TRUTH_R4_R5_R6');
END;
$$;

CREATE OR REPLACE FUNCTION public.marketroute_v1_migration_report_v1(p_batch_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_batch public.marketroute_v1_migration_batches%ROWTYPE; v_counts jsonb; v_rejections jsonb;
BEGIN
  PERFORM public.marketroute_require_service_role(); SELECT * INTO v_batch FROM public.marketroute_v1_migration_batches WHERE id=p_batch_id; IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_V1_MIGRATION_BATCH_NOT_FOUND'; END IF;
  SELECT COALESCE(jsonb_object_agg(entity_kind,cnt ORDER BY entity_kind),'{}'::jsonb) INTO v_counts FROM (SELECT entity_kind,count(*) cnt FROM public.marketroute_v1_migration_id_map WHERE batch_id=p_batch_id GROUP BY entity_kind) x;
  SELECT COALESCE(jsonb_object_agg(reason_code,cnt ORDER BY reason_code),'{}'::jsonb) INTO v_rejections FROM (SELECT reason_code,count(*) cnt FROM public.marketroute_v1_migration_rejections WHERE batch_id=p_batch_id GROUP BY reason_code) x;
  RETURN jsonb_build_object('batchId',v_batch.id,'status',v_batch.status,'targetOrganisationId',v_batch.target_organisation_id,'contractVersion',v_batch.contract_version,'sourceExportFingerprint',v_batch.source_export_fingerprint,'startedAt',v_batch.started_at,'completedAt',v_batch.completed_at,'mappingCounts',v_counts,'rejections',v_rejections,'authorityImported',false,'truthImported',false,'workflowImported',false);
END;
$$;

REVOKE ALL ON FUNCTION public.marketroute_v1_payload_forbidden_keys_v1(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_v1_assert_factual_payload_v1(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_v1_assert_allowed_keys_v1(jsonb,text[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_v1_record_fingerprint_v1(text,text,text,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_v1_assert_claim_key_factual_v1(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_v1_batch_open_v1(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_v1_mapping_v1(uuid,text,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_v1_record_mapping_v1(uuid,text,text,text,uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_v1_audit_v1(uuid,text,text,text,text,uuid,text,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_begin_v1_migration_v1(uuid,uuid,text,jsonb) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_import_v1_company_v1(uuid,text,text,jsonb) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_import_v1_person_v1(uuid,text,text,jsonb) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_import_v1_access_point_v1(uuid,text,text,jsonb) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_import_v1_seller_business_v1(uuid,text,text,jsonb) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_import_v1_seller_source_v1(uuid,text,text,jsonb) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_import_v1_campaign_v1(uuid,text,text,jsonb) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_import_v1_campaign_scope_v1(uuid,text,text,jsonb) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_v1_resolve_subject_v1(uuid,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_v1_resolve_claim_object_refs_v1(uuid,jsonb,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_import_v1_evidence_v1(uuid,text,text,jsonb) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_import_v1_historical_research_v1(uuid,text,text,jsonb) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_reject_v1_migration_record_v1(uuid,text,text,text,text,jsonb,text[]) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_complete_v1_migration_v1(uuid,jsonb) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.marketroute_v1_migration_report_v1(uuid) FROM PUBLIC,anon,authenticated;

GRANT EXECUTE ON FUNCTION public.marketroute_begin_v1_migration_v1(uuid,uuid,text,jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_import_v1_company_v1(uuid,text,text,jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_import_v1_person_v1(uuid,text,text,jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_import_v1_access_point_v1(uuid,text,text,jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_import_v1_seller_business_v1(uuid,text,text,jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_import_v1_seller_source_v1(uuid,text,text,jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_import_v1_campaign_v1(uuid,text,text,jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_import_v1_campaign_scope_v1(uuid,text,text,jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_import_v1_evidence_v1(uuid,text,text,jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_import_v1_historical_research_v1(uuid,text,text,jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_reject_v1_migration_record_v1(uuid,text,text,text,text,jsonb,text[]) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_complete_v1_migration_v1(uuid,jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_v1_migration_report_v1(uuid) TO service_role;

INSERT INTO public.marketroute_schema_releases(release_key,build_number,constitution_version,metadata_json)
VALUES('MARKETROUTE_V2_BUILD17_V1_EVIDENCE_MIGRATION',17,'MRV2-CONSTITUTION-1.0.0',jsonb_build_object(
  'migration','0019_v1_evidence_migration.sql',
  'new_authority_writer',false,
  'v1_runtime_dependency',false,
  'factual_whitelist_only',true,
  'authority_import_forbidden',true,
  'truth_import_forbidden',true,
  'workflow_import_forbidden',true,
  'immutable_v1_to_v2_mapping',true,
  'campaigns_import_as_draft',true,
  'migrated_evidence_extraction_method','MIGRATED',
  'post_import_recomputation','V2_TRUTH_THEN_R4_THEN_R5_THEN_R6'
))
ON CONFLICT(release_key) DO NOTHING;

COMMIT;
