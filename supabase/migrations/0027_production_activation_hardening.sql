BEGIN;

-- MarketRoute V2 production activation hardening 0.18.3.7.
-- This migration adds first-party seller-offering context, canonical retry reset,
-- fail-closed constraint consistency and a read-only Genesis-bank candidate surface.
-- It creates no Truth, R4, R5, R6, opportunity, engagement or execution authority writer.

ALTER TABLE public.workspace_activation_jobs
  ADD COLUMN IF NOT EXISTS seller_offering_text text;

DO $do$
BEGIN
  IF NOT EXISTS(
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.workspace_activation_jobs'::regclass
      AND conname='workspace_activation_seller_offering_length'
  ) THEN
    ALTER TABLE public.workspace_activation_jobs
      ADD CONSTRAINT workspace_activation_seller_offering_length
      CHECK (seller_offering_text IS NULL OR length(btrim(seller_offering_text)) BETWEEN 8 AND 2000);
  END IF;
END;
$do$;

-- Retain V1 for deployment-order compatibility, while repairing retry exhaustion
-- and impossible constraint states for any old application instance still live.
CREATE OR REPLACE FUNCTION public.marketroute_submit_workspace_activation_v1(
  p_organisation_id uuid,
  p_objective_text text,
  p_target_market_text text,
  p_hard_constraints_text text,
  p_no_hard_constraints boolean
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_user uuid:=auth.uid();v_seller uuid;v_job uuid;v_no_hard boolean:=COALESCE(p_no_hard_constraints,false);v_hard text:=nullif(btrim(COALESCE(p_hard_constraints_text,'')),'');
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_AUTH_REQUIRED';END IF;
  IF NOT public.marketroute_is_org_admin(p_organisation_id) THEN RAISE EXCEPTION 'MARKETROUTE_WORKSPACE_ADMIN_REQUIRED';END IF;
  IF length(btrim(COALESCE(p_objective_text,'')))<8 THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_OBJECTIVE_REQUIRED';END IF;
  IF length(btrim(COALESCE(p_target_market_text,'')))<3 THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_TARGET_REQUIRED';END IF;
  IF v_no_hard AND v_hard IS NOT NULL THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_CONSTRAINT_CONFLICT';END IF;
  IF NOT v_no_hard AND v_hard IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_CONSTRAINT_DECLARATION_REQUIRED';END IF;
  SELECT id INTO v_seller FROM public.seller_businesses WHERE organisation_id=p_organisation_id AND lifecycle_state='ACTIVE' ORDER BY created_at ASC LIMIT 1;
  IF v_seller IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_SELLER_NOT_FOUND';END IF;
  INSERT INTO public.workspace_activation_jobs(organisation_id,seller_business_id,objective_text,target_market_text,hard_constraints_text,no_hard_constraints,status,attempt_count,available_at,worker_id,lease_expires_at,last_error_code,result_json)
  VALUES(p_organisation_id,v_seller,btrim(p_objective_text),btrim(p_target_market_text),CASE WHEN v_no_hard THEN NULL ELSE v_hard END,v_no_hard,'PENDING',0,now(),NULL,NULL,NULL,'{}'::jsonb)
  ON CONFLICT(organisation_id) DO UPDATE SET objective_text=EXCLUDED.objective_text,target_market_text=EXCLUDED.target_market_text,hard_constraints_text=EXCLUDED.hard_constraints_text,no_hard_constraints=EXCLUDED.no_hard_constraints,status='PENDING',attempt_count=0,available_at=now(),worker_id=NULL,lease_expires_at=NULL,last_error_code=NULL,result_json='{}'::jsonb
  RETURNING id INTO v_job;
  RETURN v_job;
END;$fn$;

REVOKE ALL ON FUNCTION public.marketroute_submit_workspace_activation_v1(uuid,text,text,text,boolean) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_submit_workspace_activation_v1(uuid,text,text,text,boolean) TO authenticated;

CREATE OR REPLACE FUNCTION public.marketroute_submit_workspace_activation_v2(
  p_organisation_id uuid,
  p_seller_offering_text text,
  p_objective_text text,
  p_target_market_text text,
  p_hard_constraints_text text,
  p_no_hard_constraints boolean
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_user uuid:=auth.uid();v_seller uuid;v_job uuid;v_offering text:=nullif(btrim(COALESCE(p_seller_offering_text,'')),'');v_no_hard boolean:=COALESCE(p_no_hard_constraints,false);v_hard text:=nullif(btrim(COALESCE(p_hard_constraints_text,'')),'');
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_AUTH_REQUIRED';END IF;
  IF NOT public.marketroute_is_org_admin(p_organisation_id) THEN RAISE EXCEPTION 'MARKETROUTE_WORKSPACE_ADMIN_REQUIRED';END IF;
  IF v_offering IS NULL OR length(v_offering)<8 THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_OFFERING_REQUIRED';END IF;
  IF length(btrim(COALESCE(p_objective_text,'')))<8 THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_OBJECTIVE_REQUIRED';END IF;
  IF length(btrim(COALESCE(p_target_market_text,'')))<3 THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_TARGET_REQUIRED';END IF;
  IF v_no_hard AND v_hard IS NOT NULL THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_CONSTRAINT_CONFLICT';END IF;
  IF NOT v_no_hard AND v_hard IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_CONSTRAINT_DECLARATION_REQUIRED';END IF;
  SELECT id INTO v_seller FROM public.seller_businesses WHERE organisation_id=p_organisation_id AND lifecycle_state='ACTIVE' ORDER BY created_at ASC LIMIT 1;
  IF v_seller IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_SELLER_NOT_FOUND';END IF;
  INSERT INTO public.workspace_activation_jobs(organisation_id,seller_business_id,seller_offering_text,objective_text,target_market_text,hard_constraints_text,no_hard_constraints,status,attempt_count,available_at,worker_id,lease_expires_at,last_error_code,result_json)
  VALUES(p_organisation_id,v_seller,v_offering,btrim(p_objective_text),btrim(p_target_market_text),CASE WHEN v_no_hard THEN NULL ELSE v_hard END,v_no_hard,'PENDING',0,now(),NULL,NULL,NULL,'{}'::jsonb)
  ON CONFLICT(organisation_id) DO UPDATE SET seller_offering_text=EXCLUDED.seller_offering_text,objective_text=EXCLUDED.objective_text,target_market_text=EXCLUDED.target_market_text,hard_constraints_text=EXCLUDED.hard_constraints_text,no_hard_constraints=EXCLUDED.no_hard_constraints,status='PENDING',attempt_count=0,available_at=now(),worker_id=NULL,lease_expires_at=NULL,last_error_code=NULL,result_json='{}'::jsonb
  RETURNING id INTO v_job;
  RETURN v_job;
END;$fn$;

REVOKE ALL ON FUNCTION public.marketroute_submit_workspace_activation_v2(uuid,text,text,text,text,boolean) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_submit_workspace_activation_v2(uuid,text,text,text,text,boolean) TO authenticated;

-- V2 adds the explicit seller offering without changing the V1 claim signature.
CREATE OR REPLACE FUNCTION public.marketroute_claim_workspace_activation_v2(p_worker_id text,p_at timestamptz DEFAULT now())
RETURNS TABLE(job_id uuid,organisation_id uuid,seller_business_id uuid,seller_name text,canonical_domain text,website_url text,created_by_user_id uuid,seller_offering_text text,objective_text text,target_market_text text,hard_constraints_text text,no_hard_constraints boolean,attempt_count integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_id uuid;
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT j.id INTO v_id FROM public.workspace_activation_jobs AS j
  WHERE ((j.status IN ('PENDING','FAILED') AND j.available_at<=p_at) OR (j.status='RUNNING' AND j.lease_expires_at<p_at))
    AND j.attempt_count<5
    AND j.seller_offering_text IS NOT NULL
  ORDER BY j.available_at,j.created_at FOR UPDATE SKIP LOCKED LIMIT 1;
  IF v_id IS NULL THEN RETURN;END IF;
  UPDATE public.workspace_activation_jobs AS j SET status='RUNNING',attempt_count=j.attempt_count+1,worker_id=left(btrim(p_worker_id),200),lease_expires_at=p_at+interval '10 minutes',last_error_code=NULL WHERE j.id=v_id;
  RETURN QUERY SELECT j.id,j.organisation_id,j.seller_business_id,s.name,s.canonical_domain,s.website_url,o.created_by,j.seller_offering_text,j.objective_text,j.target_market_text,j.hard_constraints_text,j.no_hard_constraints,j.attempt_count
    FROM public.workspace_activation_jobs AS j JOIN public.seller_businesses AS s ON s.id=j.seller_business_id AND s.organisation_id=j.organisation_id JOIN public.organisations AS o ON o.id=j.organisation_id WHERE j.id=v_id;
END;$fn$;

REVOKE ALL ON FUNCTION public.marketroute_claim_workspace_activation_v2(text,timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_claim_workspace_activation_v2(text,timestamptz) TO service_role;

-- Deterministic identity retrieval only: explicit industries/countries in,
-- reusable bank companies out. Research density orders work reuse; it is not fit.
CREATE OR REPLACE FUNCTION public.marketroute_activation_bank_candidates_v1(
  p_industry_keys text[],
  p_country_codes text[] DEFAULT '{}'::text[],
  p_limit integer DEFAULT 12
) RETURNS TABLE(company_id uuid,name text,canonical_domain text,website_url text,country_code text,industry_key text,core_complete boolean,profile_complete boolean,routes_complete boolean,contacts_complete boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
BEGIN
  PERFORM public.marketroute_require_service_role();
  IF COALESCE(cardinality(p_industry_keys),0)=0 THEN RETURN;END IF;
  RETURN QUERY
  WITH eligible AS (
    SELECT c.id AS company_id,c.canonical_name AS company_name,c.canonical_domain,
      COALESCE(c.website_url,'https://'||c.canonical_domain) AS website_url,c.country_code,
      min(m.industry_key) AS industry_key,
      bool_or(p.core_complete_at IS NOT NULL) AS core_complete,
      bool_or(p.profile_complete_at IS NOT NULL) AS profile_complete,
      bool_or(p.routes_complete_at IS NOT NULL) AS routes_complete,
      bool_or(p.contacts_complete_at IS NOT NULL) AS contacts_complete,
      max(p.last_researched_at) AS last_researched_at
    FROM public.genesis_growth_company_memberships AS m
    JOIN public.genesis_growth_industries AS i ON i.industry_key=m.industry_key AND i.enabled
    JOIN public.companies AS c ON c.id=m.company_id
    JOIN public.genesis_growth_company_progress AS p ON p.company_id=c.id AND p.core_complete_at IS NOT NULL
    WHERE m.industry_key=ANY(p_industry_keys)
      AND c.canonical_domain IS NOT NULL
      AND (COALESCE(cardinality(p_country_codes),0)=0 OR upper(COALESCE(c.country_code,''))=ANY(ARRAY(SELECT upper(x) FROM unnest(p_country_codes) AS x)))
    GROUP BY c.id,c.canonical_name,c.canonical_domain,c.website_url,c.country_code
  )
  SELECT e.company_id,e.company_name,e.canonical_domain,e.website_url,e.country_code,e.industry_key,e.core_complete,e.profile_complete,e.routes_complete,e.contacts_complete
  FROM eligible AS e
  ORDER BY e.contacts_complete DESC,e.routes_complete DESC,e.profile_complete DESC,e.last_researched_at DESC NULLS LAST,e.canonical_domain,e.company_id
  LIMIT greatest(1,least(COALESCE(p_limit,12),25));
END;$fn$;

REVOKE ALL ON FUNCTION public.marketroute_activation_bank_candidates_v1(text[],text[],integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_activation_bank_candidates_v1(text[],text[],integer) TO service_role;

UPDATE public.workspace_activation_jobs
SET status='NEEDS_INPUT',worker_id=NULL,lease_expires_at=NULL,last_error_code='MARKETROUTE_SETUP_OFFERING_REQUIRED',updated_at=now()
WHERE seller_offering_text IS NULL
  AND (status IN ('PENDING','FAILED') OR (status='RUNNING' AND lease_expires_at<now()));

INSERT INTO public.marketroute_schema_releases(release_key,build_number,constitution_version,metadata_json)
VALUES('MARKETROUTE_V2_PRODUCTION_ACTIVATION_HARDENING_0_18_3_7',18,'MRV2-CONSTITUTION-1.0.0',jsonb_build_object('migration','0027_production_activation_hardening.sql','new_authority_writer',false,'first_party_offering',true,'constraint_conflict_fail_closed',true,'attempt_reset',true,'genesis_bank_first',true,'truthful_bootstrap_status',true))
ON CONFLICT(release_key) DO NOTHING;

NOTIFY pgrst,'reload schema';
COMMIT;
