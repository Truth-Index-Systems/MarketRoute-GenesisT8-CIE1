BEGIN;

-- MarketRoute V2 Product Build 19: Demand-Driven Genesis.
--
-- Product policy:
--   * speculative/background Genesis database growth is paused;
--   * existing global Genesis intelligence remains fully reusable;
--   * customer campaign activation/research remains active and budget-governed;
--   * autonomous growth can only be intentionally re-enabled later.
--
-- This migration creates no authority writer and changes no Truth/R4/R5/R6/opportunity mathematics.

UPDATE public.genesis_growth_settings
SET enabled = false,
    updated_at = now()
WHERE singleton = true;

-- If a growth run was active during deployment, terminate its lease/run cleanly so
-- no previously scheduled invocation can continue selecting speculative work.
UPDATE public.scheduler_runs
SET status = 'CANCELLED',
    completed_at = COALESCE(completed_at, now()),
    metadata_json = COALESCE(metadata_json, '{}'::jsonb)
      || jsonb_build_object('cancelReason','PRODUCT_BUILD_19_DEMAND_DRIVEN_GENESIS','growthPaused',true)
WHERE runner_key = 'GENESIS_DATABASE_GROWTH_V1'
  AND status = 'RUNNING';

DELETE FROM public.scheduler_leases
WHERE lease_key = 'GENESIS_DATABASE_GROWTH_V1';

-- Fail closed at the database scheduler boundary as well. A service-role caller
-- may only start Growth after the mutable genesis_growth_settings.enabled flag has
-- been deliberately re-enabled. The application adds an additional two-key gate.
CREATE OR REPLACE FUNCTION public.marketroute_start_growth_scheduler_run_v1(
  p_at timestamptz DEFAULT now()
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $fn$
DECLARE
  v_id uuid;
  v_owner uuid;
  v_enabled boolean := false;
BEGIN
  PERFORM public.marketroute_require_service_role();
  SELECT enabled INTO v_enabled
  FROM public.genesis_growth_settings
  WHERE singleton=true;
  IF COALESCE(v_enabled,false)=false THEN
    RAISE EXCEPTION 'MARKETROUTE_GROWTH_PAUSED';
  END IF;
  IF abs(extract(epoch from (p_at-now())))>300 THEN
    RAISE EXCEPTION 'MARKETROUTE_GROWTH_SCHEDULER_TIME_NOT_CURRENT';
  END IF;
  INSERT INTO public.scheduler_runs(runner_key,status,started_at,metadata_json)
  VALUES(
    'GENESIS_DATABASE_GROWTH_V1','RUNNING',p_at,
    jsonb_build_object('growthEngine','MRV2-GENESIS-GROWTH-1.0.0','productPolicy','DEMAND_DRIVEN')
  ) RETURNING id INTO v_id;
  INSERT INTO public.scheduler_leases(lease_key,owner_run_id,acquired_at,expires_at,heartbeat_at)
  VALUES('GENESIS_DATABASE_GROWTH_V1',v_id,p_at,p_at+interval '10 minutes',p_at)
  ON CONFLICT(lease_key) DO UPDATE
    SET owner_run_id=EXCLUDED.owner_run_id,
        acquired_at=EXCLUDED.acquired_at,
        expires_at=EXCLUDED.expires_at,
        heartbeat_at=EXCLUDED.heartbeat_at
    WHERE public.scheduler_leases.expires_at<=p_at
  RETURNING owner_run_id INTO v_owner;
  IF v_owner IS DISTINCT FROM v_id THEN
    UPDATE public.scheduler_runs
    SET status='CANCELLED',completed_at=p_at,
        metadata_json=metadata_json||jsonb_build_object('leaseHeld',true)
    WHERE id=v_id;
    RAISE EXCEPTION 'MARKETROUTE_GROWTH_SCHEDULER_LEASE_HELD';
  END IF;
  RETURN v_id;
END;
$fn$;

REVOKE ALL ON FUNCTION public.marketroute_start_growth_scheduler_run_v1(timestamptz)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_start_growth_scheduler_run_v1(timestamptz)
TO service_role;

INSERT INTO public.marketroute_schema_releases(
  release_key,build_number,constitution_version,metadata_json
) VALUES(
  'MARKETROUTE_V2_PRODUCT_BUILD19_DEMAND_DRIVEN_GENESIS',
  19,
  'MRV2-CONSTITUTION-1.0.0',
  jsonb_build_object(
    'migration','0039_product_demand_driven_genesis.sql',
    'new_authority_writer',false,
    'speculative_growth_paused',true,
    'existing_genesis_bank_preserved',true,
    'customer_campaign_research_preserved',true,
    'growth_scheduler_fail_closed',true,
    'product_policy','DEMAND_DRIVEN_GENESIS'
  )
) ON CONFLICT(release_key) DO NOTHING;

NOTIFY pgrst,'reload schema';
COMMIT;
