BEGIN;

-- MarketRoute V2 R6 reasoning-kind hotfix 0.18.3.19.
-- R6 must use the existing finite CONTACT_TRUTH reasoning kind.

DO $patch$
DECLARE
  v_signature regprocedure := to_regprocedure(
    'public.marketroute_persist_contact_authority_r6_v1(uuid,uuid,uuid,timestamptz,text,text,jsonb,text,text,text,jsonb,jsonb,jsonb,jsonb,integer,timestamptz)'
  );
  v_definition text;
  v_patched_definition text;
  v_old text := 'VALUES(p_organisation_id,p_campaign_id,''CONTACT_TRUTH_AUTHORITY'',p_engine_version';
  v_new text := 'VALUES(p_organisation_id,p_campaign_id,''CONTACT_TRUTH'',p_engine_version';
  v_old_occurrences integer;
  v_new_occurrences integer;
BEGIN
  IF v_signature IS NULL THEN
    RAISE EXCEPTION 'MARKETROUTE_R6_PERSIST_FUNCTION_NOT_FOUND';
  END IF;

  SELECT pg_get_functiondef(v_signature) INTO v_definition;
  v_old_occurrences := (length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  v_new_occurrences := (length(v_definition)-length(replace(v_definition,v_new,'')))/length(v_new);
  IF v_old_occurrences=1 AND v_new_occurrences=0 THEN
    v_patched_definition := replace(v_definition,v_old,v_new);
    EXECUTE v_patched_definition;
  ELSIF NOT (v_old_occurrences=0 AND v_new_occurrences=1) THEN
    RAISE EXCEPTION 'MARKETROUTE_R6_REASONING_KIND_PATCH_SOURCE_DRIFT:%:%',v_old_occurrences,v_new_occurrences;
  END IF;
END;
$patch$;

REVOKE ALL ON FUNCTION public.marketroute_persist_contact_authority_r6_v1(
  uuid,uuid,uuid,timestamptz,text,text,jsonb,text,text,text,jsonb,jsonb,jsonb,jsonb,integer,timestamptz
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_persist_contact_authority_r6_v1(
  uuid,uuid,uuid,timestamptz,text,text,jsonb,text,text,text,jsonb,jsonb,jsonb,jsonb,integer,timestamptz
) TO service_role;

-- Preserve the finite reasoning-kind constraint. Repair the writer, not the law.
DO $constraint$
DECLARE
  v_definition text;
BEGIN
  SELECT pg_get_constraintdef(c.oid)
  INTO v_definition
  FROM pg_constraint AS c
  WHERE c.conrelid='public.reasoning_runs'::regclass
    AND c.conname='reasoning_runs_reasoning_kind_check';

  IF v_definition IS NULL
    OR position('CONTACT_TRUTH' in v_definition)=0
    OR position('CONTACT_TRUTH_AUTHORITY' in v_definition)>0 THEN
    RAISE EXCEPTION 'MARKETROUTE_REASONING_KIND_CONSTRAINT_DRIFT';
  END IF;
END;
$constraint$;

WITH affected AS (
  SELECT w.background_job_id
  FROM public.research_work_units AS w
  JOIN public.background_jobs AS j ON j.id=w.background_job_id
  WHERE w.layer='R6'
    AND w.action='REVALIDATE_R6'
    AND j.status IN ('PENDING','FAILED')
    AND j.last_error_code='new row for relation "reasoning_runs" violates check constraint "reasoning_runs_reasoning_kind_check"'
)
UPDATE public.background_jobs AS j
SET status='PENDING',
    available_at=now(),
    reserved_by_run_id=NULL,
    reserved_at=NULL,
    max_attempts=least(50,greatest(j.max_attempts,j.attempt_count+1)),
    updated_at=now()
FROM affected AS a
WHERE j.id=a.background_job_id;

INSERT INTO public.marketroute_schema_releases(
  release_key,
  build_number,
  constitution_version,
  metadata_json
)
VALUES(
  'MARKETROUTE_V2_R6_REASONING_KIND_HOTFIX_0_18_3_19',
  18,
  'MRV2-CONSTITUTION-1.0.0',
  jsonb_build_object(
    'migration','0038_r6_reasoning_kind_hotfix.sql',
    'new_authority_writer',false,
    'authority_semantics_unchanged',true,
    'canonical_reasoning_kind','CONTACT_TRUTH',
    'reasoning_kind_constraint_unchanged',true,
    'requeued_exact_failed_work',true
  )
)
ON CONFLICT(release_key) DO NOTHING;

NOTIFY pgrst,'reload schema';
COMMIT;
