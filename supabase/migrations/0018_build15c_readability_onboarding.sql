BEGIN;

-- MarketRoute V2 Build 15C: Value-first onboarding identity capture.
-- Creates the organisation boundary and the seller-business identity together.
-- This is onboarding/application persistence only. It does not create or mutate
-- Truth, R4, R5, R6, opportunity, research, engagement or execution authority.

CREATE OR REPLACE FUNCTION public.marketroute_create_workspace_with_seller_v1(
  p_name text,
  p_website_url text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_user_id uuid := auth.uid();
  v_name text := btrim(COALESCE(p_name, ''));
  v_website_url text := btrim(COALESCE(p_website_url, ''));
  v_host text;
  v_base_slug text;
  v_slug text;
  v_suffix text;
  v_organisation_id uuid;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'MARKETROUTE_AUTH_REQUIRED';
  END IF;

  IF length(v_name) < 1 OR length(v_name) > 160 THEN
    RAISE EXCEPTION 'MARKETROUTE_WORKSPACE_NAME_WEBSITE_REQUIRED';
  END IF;

  IF v_website_url !~* '^https?://[^[:space:]]+$' THEN
    RAISE EXCEPTION 'MARKETROUTE_WORKSPACE_WEBSITE_INVALID';
  END IF;

  v_host := lower(split_part(regexp_replace(v_website_url, '^https?://', '', 'i'), '/', 1));
  v_host := split_part(v_host, ':', 1);
  v_host := regexp_replace(v_host, '^www\.', '', 'i');

  IF v_host !~ '^[a-z0-9][a-z0-9.-]*\.[a-z]{2,63}$' THEN
    RAISE EXCEPTION 'MARKETROUTE_WORKSPACE_WEBSITE_INVALID';
  END IF;

  -- Slugs are internal implementation details in V2. Generate one from the
  -- organisation name and add a short suffix only when the natural slug exists.
  v_base_slug := lower(regexp_replace(v_name, '[^a-zA-Z0-9]+', '-', 'g'));
  v_base_slug := btrim(v_base_slug, '-');
  IF length(v_base_slug) < 2 THEN
    v_base_slug := 'workspace';
  END IF;
  v_base_slug := left(v_base_slug, 56);
  v_slug := v_base_slug;

  IF EXISTS (SELECT 1 FROM public.organisations o WHERE o.slug = v_slug) THEN
    LOOP
      v_suffix := '-' || left(replace(gen_random_uuid()::text, '-', ''), 6);
      v_slug := left(v_base_slug, 63 - length(v_suffix)) || v_suffix;
      EXIT WHEN NOT EXISTS (SELECT 1 FROM public.organisations o WHERE o.slug = v_slug);
    END LOOP;
  END IF;

  INSERT INTO public.organisations(name, slug, created_by)
  VALUES (v_name, v_slug, v_user_id)
  RETURNING id INTO v_organisation_id;

  INSERT INTO public.organisation_memberships(organisation_id, user_id, role, status)
  VALUES (v_organisation_id, v_user_id, 'OWNER', 'ACTIVE');

  INSERT INTO public.seller_businesses(
    organisation_id,
    name,
    canonical_domain,
    website_url,
    lifecycle_state,
    created_by
  )
  VALUES (
    v_organisation_id,
    v_name,
    v_host,
    v_website_url,
    'ACTIVE',
    v_user_id
  );

  RETURN v_organisation_id;
END;
$fn$;

REVOKE ALL ON FUNCTION public.marketroute_create_workspace_with_seller_v1(text, text) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_create_workspace_with_seller_v1(text, text) TO authenticated;

INSERT INTO public.marketroute_schema_releases(release_key, build_number, constitution_version, metadata_json)
VALUES(
  'MARKETROUTE_V2_BUILD15C_READABILITY_ONBOARDING',
  15,
  'MRV2-CONSTITUTION-1.0.0',
  jsonb_build_object(
    'migration', '0018_build15c_readability_onboarding.sql',
    'new_authority_writer', false,
    'onboarding_identity_capture', true,
    'seller_business_created_with_workspace', true,
    'workspace_slug_user_visible', false
  )
) ON CONFLICT(release_key) DO NOTHING;

NOTIFY pgrst, 'reload schema';
COMMIT;
