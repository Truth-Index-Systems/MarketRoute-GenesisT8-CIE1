BEGIN;

-- Production activation is workflow/orchestration only. It does not create a new
-- commercial authority writer and cannot write Truth, R4, R5, R6, opportunity
-- authority, engagement authority, or execution authority.
CREATE TABLE public.workspace_activation_jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organisation_id uuid NOT NULL UNIQUE REFERENCES public.organisations(id) ON DELETE CASCADE,
  seller_business_id uuid NOT NULL,
  objective_text text NOT NULL CHECK (length(btrim(objective_text)) BETWEEN 8 AND 2000),
  target_market_text text NOT NULL CHECK (length(btrim(target_market_text)) BETWEEN 3 AND 2000),
  hard_constraints_text text,
  no_hard_constraints boolean NOT NULL DEFAULT false,
  status text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','RUNNING','FAILED','NEEDS_INPUT','SUCCEEDED')),
  attempt_count integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  available_at timestamptz NOT NULL DEFAULT now(),
  worker_id text,
  lease_expires_at timestamptz,
  last_error_code text,
  result_json jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(result_json)='object'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT workspace_activation_seller_scope_fk FOREIGN KEY (organisation_id,seller_business_id)
    REFERENCES public.seller_businesses(organisation_id,id) ON DELETE CASCADE,
  CHECK (no_hard_constraints OR nullif(btrim(COALESCE(hard_constraints_text,'')),'') IS NOT NULL)
);
CREATE INDEX workspace_activation_claim_idx ON public.workspace_activation_jobs(status,available_at,created_at);
REVOKE ALL ON public.workspace_activation_jobs FROM anon,authenticated,service_role;
GRANT SELECT ON public.workspace_activation_jobs TO service_role;

CREATE TRIGGER workspace_activation_touch_updated_at
BEFORE UPDATE ON public.workspace_activation_jobs
FOR EACH ROW EXECUTE FUNCTION public.marketroute_touch_updated_at();

CREATE OR REPLACE FUNCTION public.marketroute_submit_workspace_activation_v1(
  p_organisation_id uuid,
  p_objective_text text,
  p_target_market_text text,
  p_hard_constraints_text text,
  p_no_hard_constraints boolean
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_user uuid:=auth.uid();v_seller uuid;v_job uuid;BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_AUTH_REQUIRED';END IF;
  IF NOT public.marketroute_is_org_admin(p_organisation_id) THEN RAISE EXCEPTION 'MARKETROUTE_WORKSPACE_ADMIN_REQUIRED';END IF;
  IF length(btrim(COALESCE(p_objective_text,'')))<8 THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_OBJECTIVE_REQUIRED';END IF;
  IF length(btrim(COALESCE(p_target_market_text,'')))<3 THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_TARGET_REQUIRED';END IF;
  IF NOT COALESCE(p_no_hard_constraints,false) AND length(btrim(COALESCE(p_hard_constraints_text,'')))<3 THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_CONSTRAINT_DECLARATION_REQUIRED';END IF;
  SELECT id INTO v_seller FROM public.seller_businesses WHERE organisation_id=p_organisation_id AND lifecycle_state='ACTIVE' ORDER BY created_at ASC LIMIT 1;
  IF v_seller IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_SETUP_SELLER_NOT_FOUND';END IF;
  INSERT INTO public.workspace_activation_jobs(organisation_id,seller_business_id,objective_text,target_market_text,hard_constraints_text,no_hard_constraints,status,available_at,worker_id,lease_expires_at,last_error_code,result_json)
  VALUES(p_organisation_id,v_seller,btrim(p_objective_text),btrim(p_target_market_text),nullif(btrim(COALESCE(p_hard_constraints_text,'')),''),COALESCE(p_no_hard_constraints,false),'PENDING',now(),NULL,NULL,NULL,'{}'::jsonb)
  ON CONFLICT(organisation_id) DO UPDATE SET objective_text=EXCLUDED.objective_text,target_market_text=EXCLUDED.target_market_text,hard_constraints_text=EXCLUDED.hard_constraints_text,no_hard_constraints=EXCLUDED.no_hard_constraints,status='PENDING',available_at=now(),worker_id=NULL,lease_expires_at=NULL,last_error_code=NULL,result_json='{}'::jsonb
  RETURNING id INTO v_job;RETURN v_job;
END;$fn$;
REVOKE ALL ON FUNCTION public.marketroute_submit_workspace_activation_v1(uuid,text,text,text,boolean) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_submit_workspace_activation_v1(uuid,text,text,text,boolean) TO authenticated;

CREATE OR REPLACE FUNCTION public.marketroute_workspace_activation_status_v1(p_organisation_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_status text;v_error text;BEGIN
  IF auth.uid() IS NULL OR NOT public.marketroute_is_org_member(p_organisation_id) THEN RAISE EXCEPTION 'MARKETROUTE_WORKSPACE_ACCESS_DENIED';END IF;
  SELECT status,last_error_code INTO v_status,v_error FROM public.workspace_activation_jobs WHERE organisation_id=p_organisation_id;
  IF v_status IS NULL THEN
    IF EXISTS(SELECT 1 FROM public.campaigns WHERE organisation_id=p_organisation_id AND workflow_state<>'ARCHIVED') THEN RETURN jsonb_build_object('status','NOT_REQUIRED','lastErrorCode',NULL);END IF;
    RETURN jsonb_build_object('status','NOT_SUBMITTED','lastErrorCode',NULL);
  END IF;
  RETURN jsonb_build_object('status',v_status,'lastErrorCode',v_error);
END;$fn$;
REVOKE ALL ON FUNCTION public.marketroute_workspace_activation_status_v1(uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_workspace_activation_status_v1(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.marketroute_claim_workspace_activation_v1(p_worker_id text,p_at timestamptz DEFAULT now())
RETURNS TABLE(job_id uuid,organisation_id uuid,seller_business_id uuid,seller_name text,canonical_domain text,website_url text,created_by_user_id uuid,objective_text text,target_market_text text,hard_constraints_text text,no_hard_constraints boolean,attempt_count integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_id uuid;BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT j.id INTO v_id FROM public.workspace_activation_jobs j
  WHERE ((j.status IN ('PENDING','FAILED') AND j.available_at<=p_at) OR (j.status='RUNNING' AND j.lease_expires_at<p_at))
    AND j.attempt_count<5 ORDER BY j.available_at,j.created_at FOR UPDATE SKIP LOCKED LIMIT 1;
  IF v_id IS NULL THEN RETURN;END IF;
  UPDATE public.workspace_activation_jobs SET status='RUNNING',attempt_count=attempt_count+1,worker_id=left(btrim(p_worker_id),200),lease_expires_at=p_at+interval '10 minutes',last_error_code=NULL WHERE id=v_id;
  RETURN QUERY SELECT j.id,j.organisation_id,j.seller_business_id,s.name,s.canonical_domain,s.website_url,o.created_by,j.objective_text,j.target_market_text,j.hard_constraints_text,j.no_hard_constraints,j.attempt_count
    FROM public.workspace_activation_jobs j JOIN public.seller_businesses s ON s.id=j.seller_business_id AND s.organisation_id=j.organisation_id JOIN public.organisations o ON o.id=j.organisation_id WHERE j.id=v_id;
END;$fn$;

CREATE OR REPLACE FUNCTION public.marketroute_complete_workspace_activation_v1(p_job_id uuid,p_worker_id text,p_result_json jsonb,p_at timestamptz DEFAULT now()) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$ BEGIN PERFORM public.marketroute_require_service_role();UPDATE public.workspace_activation_jobs SET status='SUCCEEDED',worker_id=NULL,lease_expires_at=NULL,result_json=COALESCE(p_result_json,'{}'::jsonb),last_error_code=NULL WHERE id=p_job_id AND status='RUNNING' AND worker_id=p_worker_id;IF NOT FOUND THEN RAISE EXCEPTION 'MARKETROUTE_ACTIVATION_LEASE_MISMATCH';END IF;END;$fn$;
CREATE OR REPLACE FUNCTION public.marketroute_fail_workspace_activation_v1(p_job_id uuid,p_worker_id text,p_error_code text,p_retryable boolean,p_at timestamptz DEFAULT now()) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$ DECLARE v_attempt integer;BEGIN PERFORM public.marketroute_require_service_role();SELECT attempt_count INTO v_attempt FROM public.workspace_activation_jobs WHERE id=p_job_id AND status='RUNNING' AND worker_id=p_worker_id FOR UPDATE;IF v_attempt IS NULL THEN RAISE EXCEPTION 'MARKETROUTE_ACTIVATION_LEASE_MISMATCH';END IF;UPDATE public.workspace_activation_jobs SET status=CASE WHEN p_retryable AND v_attempt<5 THEN 'FAILED' ELSE 'NEEDS_INPUT' END,available_at=CASE WHEN p_retryable AND v_attempt<5 THEN p_at+interval '10 minutes' ELSE available_at END,worker_id=NULL,lease_expires_at=NULL,last_error_code=left(COALESCE(p_error_code,'MARKETROUTE_ACTIVATION_FAILED'),500) WHERE id=p_job_id;END;$fn$;

CREATE OR REPLACE FUNCTION public.marketroute_create_activation_campaign_v1(p_organisation_id uuid,p_seller_business_id uuid,p_objective_text text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$ DECLARE v_id uuid;v_user uuid;BEGIN PERFORM public.marketroute_require_service_role();SELECT created_by INTO v_user FROM public.organisations WHERE id=p_organisation_id;IF v_user IS NULL OR NOT EXISTS(SELECT 1 FROM public.seller_businesses WHERE id=p_seller_business_id AND organisation_id=p_organisation_id AND lifecycle_state='ACTIVE') THEN RAISE EXCEPTION 'MARKETROUTE_ACTIVATION_SCOPE_INVALID';END IF;SELECT id INTO v_id FROM public.campaigns WHERE organisation_id=p_organisation_id AND seller_business_id=p_seller_business_id AND name='Initial market research' AND workflow_state<>'ARCHIVED' ORDER BY created_at LIMIT 1;IF v_id IS NULL THEN INSERT INTO public.campaigns(organisation_id,seller_business_id,name,workflow_state,objective_text,created_by) VALUES(p_organisation_id,p_seller_business_id,'Initial market research','ACTIVE',btrim(p_objective_text),v_user) RETURNING id INTO v_id;ELSE UPDATE public.campaigns SET workflow_state='ACTIVE',objective_text=btrim(p_objective_text) WHERE id=v_id;END IF;RETURN v_id;END;$fn$;

CREATE OR REPLACE FUNCTION public.marketroute_ensure_activation_company_v1(p_organisation_id uuid,p_campaign_id uuid,p_name text,p_domain text,p_website_url text,p_country_code text DEFAULT NULL) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$ DECLARE v_domain text:=lower(regexp_replace(btrim(COALESCE(p_domain,'')),'^www\\.','','i'));v_company uuid;BEGIN PERFORM public.marketroute_require_service_role();IF NOT EXISTS(SELECT 1 FROM public.campaigns WHERE id=p_campaign_id AND organisation_id=p_organisation_id AND workflow_state='ACTIVE') THEN RAISE EXCEPTION 'MARKETROUTE_ACTIVATION_CAMPAIGN_NOT_ACTIVE';END IF;IF v_domain !~ '^[a-z0-9][a-z0-9.-]*\\.[a-z]{2,63}$' THEN RAISE EXCEPTION 'MARKETROUTE_ACTIVATION_COMPANY_DOMAIN_INVALID';END IF;SELECT id INTO v_company FROM public.companies WHERE canonical_domain=v_domain LIMIT 1;IF v_company IS NULL THEN INSERT INTO public.companies(canonical_name,canonical_domain,website_url,country_code) VALUES(btrim(p_name),v_domain,COALESCE(nullif(btrim(COALESCE(p_website_url,'')),''),'https://'||v_domain),CASE WHEN upper(COALESCE(p_country_code,''))~'^[A-Z]{2}$' THEN upper(p_country_code) ELSE NULL END) RETURNING id INTO v_company;END IF;INSERT INTO public.organisation_company_scopes(organisation_id,company_id,campaign_id,scope_kind) VALUES(p_organisation_id,v_company,p_campaign_id,'CAMPAIGN') ON CONFLICT DO NOTHING;RETURN v_company;END;$fn$;

REVOKE ALL ON FUNCTION public.marketroute_claim_workspace_activation_v1(text,timestamptz),public.marketroute_complete_workspace_activation_v1(uuid,text,jsonb,timestamptz),public.marketroute_fail_workspace_activation_v1(uuid,text,text,boolean,timestamptz),public.marketroute_create_activation_campaign_v1(uuid,uuid,text),public.marketroute_ensure_activation_company_v1(uuid,uuid,text,text,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_claim_workspace_activation_v1(text,timestamptz),public.marketroute_complete_workspace_activation_v1(uuid,text,jsonb,timestamptz),public.marketroute_fail_workspace_activation_v1(uuid,text,text,boolean,timestamptz),public.marketroute_create_activation_campaign_v1(uuid,uuid,text),public.marketroute_ensure_activation_company_v1(uuid,uuid,text,text,text,text) TO service_role;

INSERT INTO public.marketroute_schema_releases(release_key,build_number,constitution_version,metadata_json) VALUES('MARKETROUTE_V2_BUILD18_PRODUCTION_ACTIVATION',18,'MRV2-CONSTITUTION-1.0.0',jsonb_build_object('migration','0020_production_activation_runtime.sql','new_authority_writer',false,'production_activation',true,'openai_provider_boundary',true,'cron_runtime',true)) ON CONFLICT(release_key) DO NOTHING;
NOTIFY pgrst,'reload schema';
COMMIT;
