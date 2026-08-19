BEGIN;

-- MarketRoute RC 0.68 — Human Discovery + Demand-Fed Genesis Bank.
-- This migration changes reusable identity/catalogue behaviour only.
-- It creates no Truth/R4/R5/R6/opportunity/execution authority writer and does
-- not promote organisation-private customer evidence into the global bank.

CREATE OR REPLACE FUNCTION public.marketroute_register_company_in_genesis_bank_v1(
  p_company_id uuid,
  p_industry_keys text[],
  p_discovery_reason text DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
DECLARE
  v_inserted integer:=0;
BEGIN
  PERFORM public.marketroute_require_service_role();

  IF NOT EXISTS (
    SELECT 1 FROM public.companies c
    WHERE c.id=p_company_id AND c.lifecycle_state='ACTIVE'
  ) THEN
    RAISE EXCEPTION 'MARKETROUTE_GENESIS_BANK_COMPANY_INVALID';
  END IF;

  INSERT INTO public.genesis_growth_company_memberships(industry_key,company_id,discovery_reason)
  SELECT DISTINCT i.industry_key,p_company_id,left(nullif(btrim(COALESCE(p_discovery_reason,'')),''),500)
  FROM public.genesis_growth_industries i
  WHERE i.enabled=true
    AND i.industry_key=ANY(COALESCE(p_industry_keys,'{}'::text[]))
  ON CONFLICT(industry_key,company_id) DO NOTHING;

  GET DIAGNOSTICS v_inserted=ROW_COUNT;

  IF EXISTS(SELECT 1 FROM public.genesis_growth_company_memberships m WHERE m.company_id=p_company_id) THEN
    -- Identity-known state only. Customer-private campaign evidence is never
    -- copied into global Genesis completion fields by this function.
    INSERT INTO public.genesis_growth_company_progress(company_id)
    VALUES(p_company_id)
    ON CONFLICT(company_id) DO NOTHING;
  END IF;

  RETURN v_inserted;
END;
$fn$;

REVOKE ALL ON FUNCTION public.marketroute_register_company_in_genesis_bank_v1(uuid,text[],text)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_register_company_in_genesis_bank_v1(uuid,text[],text)
TO service_role;

-- Bank lookup is identity-first and density-ordered. A company may be reused as
-- a research candidate from the moment its identity is known, while globally
-- completed Genesis research still sorts ahead of identity-only rows.
CREATE OR REPLACE FUNCTION public.marketroute_activation_bank_candidates_v1(
  p_industry_keys text[],
  p_country_codes text[] DEFAULT '{}'::text[],
  p_limit integer DEFAULT 12
) RETURNS TABLE(company_id uuid,name text,canonical_domain text,website_url text,country_code text,industry_key text,core_complete boolean,profile_complete boolean,routes_complete boolean,contacts_complete boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF COALESCE(cardinality(p_industry_keys),0)=0 THEN RETURN; END IF;

  RETURN QUERY
  WITH eligible AS (
    SELECT
      c.id AS company_id,
      c.canonical_name AS company_name,
      c.canonical_domain,
      COALESCE(c.website_url,'https://'||c.canonical_domain) AS website_url,
      c.country_code,
      min(m.industry_key) AS industry_key,
      bool_or(COALESCE(p.core_complete_at IS NOT NULL,false)) AS core_complete,
      bool_or(COALESCE(p.profile_complete_at IS NOT NULL,false)) AS profile_complete,
      bool_or(COALESCE(p.routes_complete_at IS NOT NULL,false)) AS routes_complete,
      bool_or(COALESCE(p.contacts_complete_at IS NOT NULL,false)) AS contacts_complete,
      max(p.last_researched_at) AS last_researched_at,
      max(
        20
        + CASE WHEN p.core_complete_at IS NOT NULL THEN 20 ELSE 0 END
        + CASE WHEN p.profile_complete_at IS NOT NULL THEN 20 ELSE 0 END
        + CASE WHEN p.routes_complete_at IS NOT NULL THEN 20 ELSE 0 END
        + CASE WHEN p.contacts_complete_at IS NOT NULL THEN 20 ELSE 0 END
      ) AS density_percent
    FROM public.genesis_growth_company_memberships m
    JOIN public.genesis_growth_industries i ON i.industry_key=m.industry_key AND i.enabled=true
    JOIN public.companies c ON c.id=m.company_id AND c.lifecycle_state='ACTIVE'
    LEFT JOIN public.genesis_growth_company_progress p ON p.company_id=c.id
    WHERE m.industry_key=ANY(p_industry_keys)
      AND c.canonical_domain IS NOT NULL
      AND (
        COALESCE(cardinality(p_country_codes),0)=0
        OR upper(COALESCE(c.country_code,''))=ANY(ARRAY(SELECT upper(x) FROM unnest(p_country_codes) x))
      )
    GROUP BY c.id,c.canonical_name,c.canonical_domain,c.website_url,c.country_code
  )
  SELECT e.company_id,e.company_name,e.canonical_domain,e.website_url,e.country_code,e.industry_key,
         e.core_complete,e.profile_complete,e.routes_complete,e.contacts_complete
  FROM eligible e
  ORDER BY e.density_percent DESC,e.last_researched_at DESC NULLS LAST,e.canonical_domain,e.company_id
  LIMIT greatest(1,least(COALESCE(p_limit,12),25));
END;
$fn$;

REVOKE ALL ON FUNCTION public.marketroute_activation_bank_candidates_v1(text[],text[],integer)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_activation_bank_candidates_v1(text[],text[],integer)
TO service_role;

-- Bounded repair path. Bootstrap calls this on every cycle so a transient
-- bank-write failure cannot permanently exclude a customer-discovered company.
CREATE OR REPLACE FUNCTION public.marketroute_backfill_demand_fed_genesis_bank_v1(p_limit integer DEFAULT 250)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
DECLARE
  v_inserted integer:=0;
BEGIN
  PERFORM public.marketroute_require_service_role();

  WITH company_batch AS (
    SELECT DISTINCT s.company_id,c.activation_job_id
    FROM public.organisation_company_scopes s
    JOIN public.campaigns c ON c.id=s.campaign_id AND c.organisation_id=s.organisation_id
    JOIN public.workspace_activation_jobs j ON j.id=c.activation_job_id AND j.organisation_id=c.organisation_id
    WHERE s.scope_kind='CAMPAIGN' AND s.campaign_id IS NOT NULL
      AND jsonb_typeof(j.result_json #> '{discovery,industryKeys}')='array'
      AND EXISTS (
        SELECT 1
        FROM jsonb_array_elements_text(j.result_json #> '{discovery,industryKeys}') k(industry_key)
        JOIN public.genesis_growth_industries i ON i.industry_key=k.industry_key AND i.enabled=true
        WHERE NOT EXISTS (
          SELECT 1 FROM public.genesis_growth_company_memberships m
          WHERE m.company_id=s.company_id AND m.industry_key=i.industry_key
        )
      )
    ORDER BY s.company_id,c.activation_job_id
    LIMIT greatest(1,least(COALESCE(p_limit,250),5000))
  ), classified AS (
    SELECT DISTINCT b.company_id,i.industry_key
    FROM company_batch b
    JOIN public.workspace_activation_jobs j ON j.id=b.activation_job_id
    CROSS JOIN LATERAL jsonb_array_elements_text(j.result_json #> '{discovery,industryKeys}') k(industry_key)
    JOIN public.genesis_growth_industries i ON i.industry_key=k.industry_key AND i.enabled=true
  ), inserted AS (
    INSERT INTO public.genesis_growth_company_memberships(industry_key,company_id,discovery_reason)
    SELECT c.industry_key,c.company_id,'DEMAND_FED_BOOTSTRAP_REPAIR'
    FROM classified c
    ON CONFLICT(industry_key,company_id) DO NOTHING
    RETURNING company_id
  )
  SELECT count(*)::int INTO v_inserted FROM inserted;

  INSERT INTO public.genesis_growth_company_progress(company_id)
  SELECT DISTINCT c.company_id
  FROM public.organisation_company_scopes c
  WHERE EXISTS(SELECT 1 FROM public.genesis_growth_company_memberships m WHERE m.company_id=c.company_id)
  ON CONFLICT(company_id) DO NOTHING;

  RETURN v_inserted;
END;
$fn$;

REVOKE ALL ON FUNCTION public.marketroute_backfill_demand_fed_genesis_bank_v1(integer)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_backfill_demand_fed_genesis_bank_v1(integer)
TO service_role;

-- Backfill companies already found through modern campaign activation lineage.
-- The industry keys come from the deterministic activation result; no new
-- industry inference is guessed in SQL.
WITH classified AS (
  SELECT DISTINCT s.company_id,i.industry_key
  FROM public.organisation_company_scopes s
  JOIN public.campaigns c
    ON c.id=s.campaign_id AND c.organisation_id=s.organisation_id
  JOIN public.workspace_activation_jobs j
    ON j.id=c.activation_job_id AND j.organisation_id=c.organisation_id
  CROSS JOIN LATERAL jsonb_array_elements_text(
    CASE
      WHEN jsonb_typeof(j.result_json #> '{discovery,industryKeys}')='array'
        THEN j.result_json #> '{discovery,industryKeys}'
      ELSE '[]'::jsonb
    END
  ) AS k(industry_key)
  JOIN public.genesis_growth_industries i
    ON i.industry_key=k.industry_key AND i.enabled=true
  WHERE s.scope_kind='CAMPAIGN' AND s.campaign_id IS NOT NULL
)
INSERT INTO public.genesis_growth_company_memberships(industry_key,company_id,discovery_reason)
SELECT c.industry_key,c.company_id,'DEMAND_FED_BACKFILL'
FROM classified c
ON CONFLICT(industry_key,company_id) DO NOTHING;

INSERT INTO public.genesis_growth_company_progress(company_id)
SELECT DISTINCT m.company_id
FROM public.genesis_growth_company_memberships m
ON CONFLICT(company_id) DO NOTHING;

INSERT INTO public.marketroute_schema_releases(release_key,build_number,constitution_version,metadata_json)
VALUES(
  'MARKETROUTE_RC_068_HUMAN_DISCOVERY_DEMAND_FED_GENESIS_BANK',
  18,
  'MRV2-CONSTITUTION-1.0.0',
  jsonb_build_object(
    'migration','0065_human_discovery_demand_fed_genesis_bank.sql',
    'new_authority_writer',false,
    'authority_semantics_unchanged',true,
    'demand_fed_genesis_bank',true,
    'identity_only_candidates_allowed',true,
    'density_ordered_bank_reuse',true,
    'customer_private_evidence_promoted',false,
    'activation_lineage_backfill',true,
    'bootstrap_repair_backfill',true
  )
)
ON CONFLICT(release_key) DO NOTHING;

NOTIFY pgrst,'reload schema';
COMMIT;
