BEGIN;

-- MarketRoute V2 activation company-domain hotfix 0.18.3.9.
--
-- The Build 18 activation RPC used a double-backslash SQL regex literal for
-- the hostname dot. With standard_conforming_strings enabled, PostgreSQL
-- interpreted it as a literal backslash requirement and rejected valid domains.
-- Character-class dot matching avoids SQL/backslash ambiguity entirely.

CREATE OR REPLACE FUNCTION public.marketroute_ensure_activation_company_v1(
  p_organisation_id uuid,
  p_campaign_id uuid,
  p_name text,
  p_domain text,
  p_website_url text,
  p_country_code text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_domain text := lower(regexp_replace(
    btrim(COALESCE(p_domain, '')),
    '^www[.]',
    '',
    'i'
  ));
  v_name text := left(btrim(COALESCE(p_name, '')), 240);
  v_website_url text := nullif(btrim(COALESCE(p_website_url, '')), '');
  v_country_code text := CASE
    WHEN upper(COALESCE(p_country_code, '')) ~ '^[A-Z]{2}$'
      THEN upper(p_country_code)
    ELSE NULL
  END;
  v_company uuid;
BEGIN
  PERFORM public.marketroute_require_service_role();

  IF NOT EXISTS (
    SELECT 1
    FROM public.campaigns AS c
    WHERE c.id = p_campaign_id
      AND c.organisation_id = p_organisation_id
      AND c.workflow_state = 'ACTIVE'
  ) THEN
    RAISE EXCEPTION 'MARKETROUTE_ACTIVATION_CAMPAIGN_NOT_ACTIVE';
  END IF;

  IF v_domain !~ '^[a-z0-9][a-z0-9.-]*[.][a-z]{2,63}$'
     OR v_domain ~ '[.][.]' THEN
    RAISE EXCEPTION 'MARKETROUTE_ACTIVATION_COMPANY_DOMAIN_INVALID';
  END IF;

  SELECT c.id
  INTO v_company
  FROM public.companies AS c
  WHERE c.canonical_domain = v_domain
  LIMIT 1;

  IF v_company IS NULL THEN
    IF length(v_name) = 0 THEN
      RAISE EXCEPTION 'MARKETROUTE_ACTIVATION_COMPANY_NAME_INVALID';
    END IF;

    INSERT INTO public.companies(
      canonical_name,
      canonical_domain,
      website_url,
      country_code,
      lifecycle_state
    )
    VALUES(
      v_name,
      v_domain,
      COALESCE(v_website_url, 'https://' || v_domain),
      v_country_code,
      'ACTIVE'
    )
    RETURNING id INTO v_company;
  END IF;

  INSERT INTO public.organisation_company_scopes(
    organisation_id,
    company_id,
    campaign_id,
    scope_kind
  )
  VALUES(
    p_organisation_id,
    v_company,
    p_campaign_id,
    'CAMPAIGN'
  )
  ON CONFLICT DO NOTHING;

  RETURN v_company;
END;
$fn$;

REVOKE ALL ON FUNCTION public.marketroute_ensure_activation_company_v1(
  uuid,uuid,text,text,text,text
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.marketroute_ensure_activation_company_v1(
  uuid,uuid,text,text,text,text
) TO service_role;

INSERT INTO public.marketroute_schema_releases(
  release_key,
  build_number,
  constitution_version,
  metadata_json
)
VALUES(
  'MARKETROUTE_V2_ACTIVATION_COMPANY_DOMAIN_HOTFIX_0_18_3_9',
  18,
  'MRV2-CONSTITUTION-1.0.0',
  jsonb_build_object(
    'migration','0029_activation_company_domain_hotfix.sql',
    'new_authority_writer',false,
    'activation_company_domain_regex_fix',true,
    'valid_domain_regression','example.com'
  )
)
ON CONFLICT(release_key) DO NOTHING;

NOTIFY pgrst,'reload schema';
COMMIT;

