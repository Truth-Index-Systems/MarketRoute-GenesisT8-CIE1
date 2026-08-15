BEGIN;

-- MarketRoute V2 R4 ISO timestamp-format hotfix 0.18.3.14.
-- PostgreSQL to_char() treats the previous backslashes as literal characters,
-- so boundary timestamps contained quoted T/Z tokens instead of canonical ISO.

CREATE OR REPLACE FUNCTION public.marketroute_r4_iso_v1(p_value timestamptz)
RETURNS text
LANGUAGE sql
IMMUTABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT CASE WHEN p_value IS NULL THEN NULL ELSE to_char(p_value AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') END;
$$;

REVOKE ALL ON FUNCTION public.marketroute_r4_iso_v1(timestamptz)
FROM PUBLIC, anon, authenticated;

INSERT INTO public.marketroute_schema_releases(
  release_key,
  build_number,
  constitution_version,
  metadata_json
)
VALUES(
  'MARKETROUTE_V2_R4_ISO_TIMESTAMP_FORMAT_HOTFIX_0_18_3_14',
  18,
  'MRV2-CONSTITUTION-1.0.0',
  jsonb_build_object(
    'migration','0034_r4_iso_timestamp_format_hotfix.sql',
    'new_authority_writer',false,
    'authority_semantics_unchanged',true,
    'replaced_internal_helper','marketroute_r4_iso_v1',
    'typescript_database_boundary_parity',true,
    'root_error','MARKETROUTE_R4_BOUNDARIES_MISMATCH',
    'production_diff_fields',2
  )
)
ON CONFLICT(release_key) DO NOTHING;

NOTIFY pgrst,'reload schema';
COMMIT;
