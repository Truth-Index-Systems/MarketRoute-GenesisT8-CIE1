BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

CREATE TABLE public.marketroute_schema_releases (
  release_key text PRIMARY KEY,
  build_number integer NOT NULL CHECK (build_number > 0),
  constitution_version text NOT NULL,
  applied_at timestamptz NOT NULL DEFAULT now(),
  metadata_json jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata_json) = 'object')
);

REVOKE ALL ON public.marketroute_schema_releases FROM anon, authenticated, service_role;
GRANT SELECT ON public.marketroute_schema_releases TO service_role;

CREATE TABLE public.organisations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 160),
  slug text NOT NULL UNIQUE CHECK (slug = lower(slug) AND slug ~ '^[a-z0-9][a-z0-9-]{1,62}$'),
  status text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','SUSPENDED','CLOSED')),
  created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX organisations_created_by_idx ON public.organisations(created_by);

CREATE TABLE public.organisation_memberships (
  organisation_id uuid NOT NULL REFERENCES public.organisations(id) ON DELETE RESTRICT,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role text NOT NULL CHECK (role IN ('OWNER','ADMIN','MEMBER','VIEWER')),
  status text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','INVITED','DISABLED')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (organisation_id, user_id)
);

CREATE INDEX organisation_memberships_user_idx ON public.organisation_memberships(user_id, status);

CREATE TABLE public.seller_businesses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organisation_id uuid NOT NULL REFERENCES public.organisations(id) ON DELETE RESTRICT,
  name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 200),
  canonical_domain text,
  website_url text,
  lifecycle_state text NOT NULL DEFAULT 'ACTIVE' CHECK (lifecycle_state IN ('ACTIVE','ARCHIVED')),
  created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organisation_id, id),
  CHECK (canonical_domain IS NULL OR canonical_domain = lower(canonical_domain))
);

CREATE INDEX seller_businesses_org_idx ON public.seller_businesses(organisation_id, lifecycle_state);

CREATE TABLE public.campaigns (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organisation_id uuid NOT NULL REFERENCES public.organisations(id) ON DELETE RESTRICT,
  seller_business_id uuid NOT NULL,
  name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 200),
  workflow_state text NOT NULL DEFAULT 'DRAFT' CHECK (workflow_state IN ('DRAFT','ACTIVE','PAUSED','ARCHIVED')),
  objective_text text,
  created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organisation_id, id),
  CONSTRAINT campaigns_seller_business_scope_fk
    FOREIGN KEY (organisation_id, seller_business_id)
    REFERENCES public.seller_businesses(organisation_id, id)
    ON DELETE RESTRICT
);

CREATE INDEX campaigns_org_state_idx ON public.campaigns(organisation_id, workflow_state);

CREATE OR REPLACE FUNCTION public.marketroute_touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER organisations_touch_updated_at
BEFORE UPDATE ON public.organisations
FOR EACH ROW EXECUTE FUNCTION public.marketroute_touch_updated_at();

CREATE TRIGGER organisation_memberships_touch_updated_at
BEFORE UPDATE ON public.organisation_memberships
FOR EACH ROW EXECUTE FUNCTION public.marketroute_touch_updated_at();

CREATE TRIGGER seller_businesses_touch_updated_at
BEFORE UPDATE ON public.seller_businesses
FOR EACH ROW EXECUTE FUNCTION public.marketroute_touch_updated_at();

CREATE TRIGGER campaigns_touch_updated_at
BEFORE UPDATE ON public.campaigns
FOR EACH ROW EXECUTE FUNCTION public.marketroute_touch_updated_at();

CREATE OR REPLACE FUNCTION public.marketroute_is_org_member(p_organisation_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.organisation_memberships m
    WHERE m.organisation_id = p_organisation_id
      AND m.user_id = auth.uid()
      AND m.status = 'ACTIVE'
  );
$$;

CREATE OR REPLACE FUNCTION public.marketroute_is_org_admin(p_organisation_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.organisation_memberships m
    WHERE m.organisation_id = p_organisation_id
      AND m.user_id = auth.uid()
      AND m.status = 'ACTIVE'
      AND m.role IN ('OWNER','ADMIN')
  );
$$;

CREATE OR REPLACE FUNCTION public.marketroute_create_organisation(p_name text, p_slug text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_organisation_id uuid;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'MARKETROUTE_AUTH_REQUIRED';
  END IF;

  INSERT INTO public.organisations(name, slug, created_by)
  VALUES (btrim(p_name), lower(btrim(p_slug)), v_user_id)
  RETURNING id INTO v_organisation_id;

  INSERT INTO public.organisation_memberships(organisation_id, user_id, role, status)
  VALUES (v_organisation_id, v_user_id, 'OWNER', 'ACTIVE');

  RETURN v_organisation_id;
END;
$$;

ALTER TABLE public.organisations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.organisation_memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.seller_businesses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.campaigns ENABLE ROW LEVEL SECURITY;

CREATE POLICY organisations_select_member ON public.organisations
FOR SELECT TO authenticated
USING (public.marketroute_is_org_member(id));

CREATE POLICY memberships_select_member ON public.organisation_memberships
FOR SELECT TO authenticated
USING (public.marketroute_is_org_member(organisation_id));

CREATE POLICY seller_businesses_member_select ON public.seller_businesses
FOR SELECT TO authenticated
USING (public.marketroute_is_org_member(organisation_id));

CREATE POLICY campaigns_member_select ON public.campaigns
FOR SELECT TO authenticated
USING (public.marketroute_is_org_member(organisation_id));

REVOKE ALL ON public.organisations FROM anon, authenticated, service_role;
REVOKE ALL ON public.organisation_memberships FROM anon, authenticated, service_role;
GRANT SELECT ON public.organisations TO authenticated;
GRANT SELECT ON public.organisation_memberships TO authenticated;
GRANT SELECT ON public.seller_businesses TO authenticated;
GRANT SELECT ON public.campaigns TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.organisations TO service_role;
GRANT SELECT, INSERT, UPDATE ON public.organisation_memberships TO service_role;
GRANT SELECT, INSERT, UPDATE ON public.seller_businesses TO service_role;
GRANT SELECT, INSERT, UPDATE ON public.campaigns TO service_role;
GRANT EXECUTE ON FUNCTION public.marketroute_is_org_member(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_is_org_admin(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.marketroute_create_organisation(text, text) TO authenticated;

REVOKE ALL ON FUNCTION public.marketroute_touch_updated_at() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_is_org_member(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_is_org_admin(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_create_organisation(text, text) FROM PUBLIC;

COMMIT;
