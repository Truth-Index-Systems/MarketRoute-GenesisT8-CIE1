BEGIN;

-- MarketRoute V2 Product Build 22: Opportunities, Routes & Contacts
-- Read-only product projection. No commercial/contact authority is created or modified here.

CREATE OR REPLACE FUNCTION public.marketroute_application_route_display_read_v1(
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
AS $fn$
DECLARE
  v_env jsonb;
  v_r5 public.route_authority_r5_records%ROWTYPE;
  v_r6 public.contact_authority_r6_records%ROWTYPE;
  v_company public.companies%ROWTYPE;
  v_paths jsonb:='[]'::jsonb;
BEGIN
  PERFORM public.marketroute_require_service_role();
  PERFORM public.marketroute_application_require_current_read_time_v1(p_at);

  SELECT * INTO v_company FROM public.companies WHERE id=p_company_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_APPLICATION_COMPANY_NOT_FOUND'; END IF;

  v_env:=public.marketroute_authority_envelope_v1(p_organisation_id,p_campaign_id,p_company_id,p_at);
  IF NULLIF(v_env->'r5'->>'authorityRecordId','') IS NOT NULL THEN
    SELECT * INTO v_r5 FROM public.route_authority_r5_records WHERE authority_record_id=(v_env->'r5'->>'authorityRecordId')::uuid;
  END IF;
  IF NULLIF(v_env->'r6'->>'authorityRecordId','') IS NOT NULL THEN
    SELECT * INTO v_r6 FROM public.contact_authority_r6_records WHERE authority_record_id=(v_env->'r6'->>'authorityRecordId')::uuid;
  END IF;

  IF v_r5.id IS NOT NULL THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'ordinal',p.ordinality,
      'pathFingerprint',p.path->>'pathFingerprint',
      'pathState',p.path->>'pathState',
      'knowledgeState',p.path->>'knowledgeState',
      'terminalAccessPointId',p.path->>'terminalAccessPointId',
      'authorised',COALESCE(v_r6.authorised_path_fingerprints,'[]'::jsonb) ? (p.path->>'pathFingerprint'),
      'mode',COALESCE(rb.binding->>'mode',CASE WHEN p.path->>'pathState'='ORGANISATIONAL_OPEN' THEN 'ORGANISATIONAL_ROUTE' ELSE 'NAMED_CONTACT' END),
      'authorityState',COALESCE(rb.binding->>'authorityState',CASE WHEN COALESCE(v_r6.authorised_path_fingerprints,'[]'::jsonb) ? (p.path->>'pathFingerprint') THEN 'AUTHORISED' ELSE 'CONTACT_TRUTH_REQUIRED' END),
      'authorityReasonCode',rb.binding->>'reasonCode',
      'personId',rp.person_id,
      'personName',CASE WHEN rp.person_id IS NULL THEN NULL ELSE COALESCE(pe.canonical_name,pe.display_name) END,
      'roleTitles',COALESCE(ev.role_titles,'[]'::jsonb),
      'terminalAccessPoint',CASE WHEN ap.id IS NULL THEN NULL ELSE jsonb_build_object(
        'accessPointId',ap.id,'accessPointKind',ap.access_point_kind,'canonicalValue',ap.canonical_value
      ) END,
      'routeNextRevalidationAt',v_r5.next_revalidation_at,
      'contactNextRevalidationAt',CASE WHEN v_r6.id IS NULL THEN NULL ELSE v_r6.next_revalidation_at END,
      'evidence',jsonb_build_object(
        'identitySnapshotIds',COALESCE(ev.identity_snapshot_ids,'[]'::jsonb),
        'employmentSnapshotIds',COALESCE(ev.employment_snapshot_ids,'[]'::jsonb),
        'roleSnapshotIds',COALESCE(ev.role_snapshot_ids,'[]'::jsonb),
        'channelSnapshotIds',COALESCE(ev.channel_snapshot_ids,'[]'::jsonb)
      ),
      'nodes',COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'nodeId',n.id,'kind',n.node_kind,
        'label',COALESCE(n.label,co.canonical_name,pn.display_name,n.canonical_value,n.stable_key),
        'meta',CASE n.node_kind WHEN 'COMPANY' THEN co.canonical_domain WHEN 'PERSON' THEN pn.canonical_name WHEN 'ACCESS_POINT' THEN n.access_point_kind ELSE n.node_kind END,
        'canonicalValue',n.canonical_value,'accessPointKind',n.access_point_kind
      ) ORDER BY ids.ordinality)
      FROM jsonb_array_elements_text(p.path->'nodeIds') WITH ORDINALITY ids(node_id,ordinality)
      JOIN public.commercial_graph_nodes n ON n.id=ids.node_id::uuid
      LEFT JOIN public.companies co ON co.id=n.company_id
      LEFT JOIN public.people pn ON pn.id=n.person_id),'[]'::jsonb)
    ) ORDER BY p.ordinality),'[]'::jsonb) INTO v_paths
    FROM jsonb_array_elements(v_r5.paths_json) WITH ORDINALITY p(path,ordinality)
    LEFT JOIN LATERAL (
      SELECT b.value AS binding
      FROM jsonb_array_elements(COALESCE(v_r6.bindings_json,'[]'::jsonb)) b(value)
      WHERE b.value->>'pathFingerprint'=p.path->>'pathFingerprint'
      LIMIT 1
    ) rb ON true
    LEFT JOIN LATERAL (
      SELECT COALESCE(
        NULLIF(rb.binding->>'personId','')::uuid,
        (SELECT n.person_id
         FROM jsonb_array_elements_text(p.path->'nodeIds') WITH ORDINALITY ids(node_id,ordinality)
         JOIN public.commercial_graph_nodes n ON n.id=ids.node_id::uuid
         WHERE n.node_kind='PERSON' AND n.person_id IS NOT NULL
         ORDER BY ids.ordinality
         LIMIT 1)
      ) AS person_id
    ) rp ON true
    LEFT JOIN public.people pe ON pe.id=rp.person_id
    LEFT JOIN public.commercial_graph_nodes ap ON ap.id=NULLIF(p.path->>'terminalAccessPointId','')::uuid
    LEFT JOIN LATERAL (
      SELECT
        to_jsonb(COALESCE(array_agg(DISTINCT NULLIF(btrim(c.object_json->>'roleTitle'),'') ORDER BY NULLIF(btrim(c.object_json->>'roleTitle'),'')) FILTER (
          WHERE c.subject_type='PERSON' AND c.subject_id=rp.person_id AND c.claim_key='role.current' AND ts.truth_state IN('KNOWN','SUPPORTED') AND ts.next_revalidation_at>p_at AND NULLIF(btrim(c.object_json->>'roleTitle'),'') IS NOT NULL
        ),ARRAY[]::text[])) AS role_titles,
        to_jsonb(COALESCE(array_agg(ts.id::text ORDER BY ts.id::text) FILTER (WHERE c.subject_type='PERSON' AND c.subject_id=rp.person_id AND c.claim_key='identity.canonical_name'),ARRAY[]::text[])) AS identity_snapshot_ids,
        to_jsonb(COALESCE(array_agg(ts.id::text ORDER BY ts.id::text) FILTER (WHERE c.subject_type='PERSON' AND c.subject_id=rp.person_id AND c.claim_key='employment.current'),ARRAY[]::text[])) AS employment_snapshot_ids,
        to_jsonb(COALESCE(array_agg(ts.id::text ORDER BY ts.id::text) FILTER (WHERE c.subject_type='PERSON' AND c.subject_id=rp.person_id AND c.claim_key='role.current'),ARRAY[]::text[])) AS role_snapshot_ids,
        to_jsonb(COALESCE(array_agg(ts.id::text ORDER BY ts.id::text) FILTER (WHERE c.subject_type='CHANNEL' AND c.subject_id=ap.id AND c.claim_key='ownership.current'),ARRAY[]::text[])) AS channel_snapshot_ids
      FROM public.claims c
      JOIN public.truth_claim_snapshots ts ON ts.id=NULLIF(COALESCE(v_r6.contact_truth_snapshot_map,'{}'::jsonb)->>c.id::text,'')::uuid
      WHERE (c.subject_type='PERSON' AND c.subject_id=rp.person_id AND c.claim_key IN('identity.canonical_name','employment.current','role.current'))
         OR (c.subject_type='CHANNEL' AND c.subject_id=ap.id AND c.claim_key='ownership.current')
    ) ev ON true;
  END IF;

  RETURN jsonb_build_object(
    'contractVersion','MRV2-APPLICATION-READ-1.0.0',
    'resourceType','ROUTE_DISPLAY',
    'evaluatedAt',to_jsonb(p_at),
    'organisationId',p_organisation_id,
    'campaignId',p_campaign_id,
    'companyId',p_company_id,
    'company',jsonb_build_object(
      'companyName',v_company.canonical_name,
      'canonicalDomain',v_company.canonical_domain,
      'websiteUrl',v_company.website_url
    ),
    'r5Decision',COALESCE(v_r5.decision_code,'NO_CURRENT_R5'),
    'r6Decision',COALESCE(v_r6.decision_code,'NO_CURRENT_R6'),
    'paths',v_paths
  );
END $fn$;

REVOKE ALL ON FUNCTION public.marketroute_application_route_display_read_v1(uuid,uuid,uuid,timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_application_route_display_read_v1(uuid,uuid,uuid,timestamptz) TO service_role;

INSERT INTO public.marketroute_schema_releases(release_key,build_number,constitution_version,metadata_json)
VALUES('MARKETROUTE_V2_PRODUCT_BUILD22_OPPORTUNITY_ROUTES_CONTACTS',22,'MRV2-CONSTITUTION-1.0.0',jsonb_build_object(
  'migration','0042_product_opportunity_routes_contacts.sql',
  'new_authority_writer',false,
  'authority_semantics_unchanged',true,
  'read_only_projection',true,
  'contact_authority_source','R6',
  'route_authority_source','R5',
  'browser_direct_database_forbidden',true
)) ON CONFLICT(release_key) DO NOTHING;

NOTIFY pgrst,'reload schema';
COMMIT;
