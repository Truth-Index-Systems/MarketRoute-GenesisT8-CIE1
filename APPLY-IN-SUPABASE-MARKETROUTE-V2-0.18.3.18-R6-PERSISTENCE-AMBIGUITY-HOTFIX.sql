BEGIN;

-- MarketRoute V2 R6 persistence ambiguity hotfix 0.18.3.18.
-- The TABLE return column authority_record_id was also a PL/pgSQL variable.
-- Qualify the one R5 lookup that used the same unqualified column name.

DO $patch$
DECLARE
  v_signature regprocedure := to_regprocedure(
    'public.marketroute_persist_contact_authority_r6_v1(uuid,uuid,uuid,timestamptz,text,text,jsonb,text,text,text,jsonb,jsonb,jsonb,jsonb,integer,timestamptz)'
  );
  v_definition text;
  v_patched_definition text;
  v_old text := 'FROM public.route_authority_r5_records WHERE authority_record_id=v_r5_id';
  v_new text := 'FROM public.route_authority_r5_records AS r WHERE r.authority_record_id=v_r5_id';
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
    RAISE EXCEPTION 'MARKETROUTE_R6_PERSIST_PATCH_SOURCE_DRIFT:%:%',v_old_occurrences,v_new_occurrences;
  END IF;
END;
$patch$;

REVOKE ALL ON FUNCTION public.marketroute_persist_contact_authority_r6_v1(
  uuid,uuid,uuid,timestamptz,text,text,jsonb,text,text,text,jsonb,jsonb,jsonb,jsonb,integer,timestamptz
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_persist_contact_authority_r6_v1(
  uuid,uuid,uuid,timestamptz,text,text,jsonb,text,text,text,jsonb,jsonb,jsonb,jsonb,integer,timestamptz
) TO service_role;

-- Retry only research jobs that stopped on this exact deterministic defect.
WITH affected AS (
  SELECT w.background_job_id
  FROM public.research_work_units AS w
  JOIN public.background_jobs AS j ON j.id=w.background_job_id
  WHERE w.layer='R6'
    AND w.action='REVALIDATE_R6'
    AND j.status IN ('PENDING','FAILED')
    AND j.last_error_code='column reference "authority_record_id" is ambiguous'
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
  'MARKETROUTE_V2_R6_PERSISTENCE_AMBIGUITY_HOTFIX_0_18_3_18',
  18,
  'MRV2-CONSTITUTION-1.0.0',
  jsonb_build_object(
    'migration','0037_r6_persistence_ambiguity_hotfix.sql',
    'new_authority_writer',false,
    'replaced_existing_authority_writer','marketroute.r6.contact-truth',
    'authority_semantics_unchanged',true,
    'qualified_authority_record_lookup',true,
    'requeued_exact_failed_work',true
  )
)
ON CONFLICT(release_key) DO NOTHING;

NOTIFY pgrst,'reload schema';
COMMIT;
