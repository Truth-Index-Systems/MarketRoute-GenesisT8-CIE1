-- MarketRoute AWS V0 Build 5
-- External identity mapping: Cognito subject -> canonical internal MarketRoute user UUID.
-- This is an additive migration. Do not modify or replay the frozen Build 3 baseline.

BEGIN;

CREATE TABLE public.marketroute_external_identities (
    provider text NOT NULL,
    issuer text NOT NULL,
    subject text NOT NULL,
    user_id uuid NOT NULL,
    email_snapshot text,
    email_verified boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    last_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT marketroute_external_identities_pkey PRIMARY KEY (provider, issuer, subject),
    CONSTRAINT marketroute_external_identities_provider_check CHECK (provider = 'COGNITO'::text),
    CONSTRAINT marketroute_external_identities_issuer_check CHECK (length(issuer) BETWEEN 16 AND 512),
    CONSTRAINT marketroute_external_identities_subject_check CHECK (length(subject) BETWEEN 1 AND 255),
    CONSTRAINT marketroute_external_identities_email_snapshot_check CHECK (email_snapshot IS NULL OR length(email_snapshot) BETWEEN 3 AND 320),
    CONSTRAINT marketroute_external_identities_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.marketroute_users(id) ON DELETE CASCADE,
    CONSTRAINT marketroute_external_identities_user_provider_unique UNIQUE (provider, issuer, user_id)
);

CREATE INDEX marketroute_external_identities_user_idx
    ON public.marketroute_external_identities (user_id);

COMMENT ON TABLE public.marketroute_external_identities IS
    'Build 5 trusted-server mapping from an external identity provider subject to the canonical internal MarketRoute user UUID.';

CREATE FUNCTION public.marketroute_resolve_external_identity_v1(
    p_provider text,
    p_issuer text,
    p_subject text,
    p_email text DEFAULT NULL,
    p_email_verified boolean DEFAULT false
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_provider text := upper(btrim(COALESCE(p_provider, '')));
    v_issuer text := btrim(COALESCE(p_issuer, ''));
    v_subject text := btrim(COALESCE(p_subject, ''));
    v_email text := NULLIF(lower(btrim(COALESCE(p_email, ''))), '');
    v_user_id uuid;
    v_status text;
BEGIN
    IF v_provider <> 'COGNITO' THEN
        RAISE EXCEPTION 'MARKETROUTE_EXTERNAL_IDENTITY_PROVIDER_INVALID';
    END IF;
    IF length(v_issuer) < 16 OR length(v_issuer) > 512 OR v_issuer !~ '^https://cognito-idp\.[A-Za-z0-9-]+\.amazonaws\.com/[A-Za-z0-9_-]+$' THEN
        RAISE EXCEPTION 'MARKETROUTE_EXTERNAL_IDENTITY_ISSUER_INVALID';
    END IF;
    IF length(v_subject) < 1 OR length(v_subject) > 255 THEN
        RAISE EXCEPTION 'MARKETROUTE_EXTERNAL_IDENTITY_SUBJECT_INVALID';
    END IF;
    IF v_email IS NOT NULL AND length(v_email) > 320 THEN
        RAISE EXCEPTION 'MARKETROUTE_EXTERNAL_IDENTITY_EMAIL_INVALID';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(v_provider || E'\n' || v_issuer || E'\n' || v_subject, 0));

    SELECT e.user_id, u.status
      INTO v_user_id, v_status
      FROM public.marketroute_external_identities e
      JOIN public.marketroute_users u ON u.id = e.user_id
     WHERE e.provider = v_provider
       AND e.issuer = v_issuer
       AND e.subject = v_subject
     FOR UPDATE OF e, u;

    IF FOUND THEN
        IF v_status <> 'ACTIVE' THEN
            RAISE EXCEPTION 'MARKETROUTE_USER_INACTIVE';
        END IF;

        UPDATE public.marketroute_external_identities
           SET email_snapshot = COALESCE(v_email, email_snapshot),
               email_verified = COALESCE(p_email_verified, false),
               last_seen_at = now()
         WHERE provider = v_provider
           AND issuer = v_issuer
           AND subject = v_subject;

        RETURN v_user_id;
    END IF;

    INSERT INTO public.marketroute_users DEFAULT VALUES
    RETURNING id INTO v_user_id;

    INSERT INTO public.marketroute_external_identities (
        provider,
        issuer,
        subject,
        user_id,
        email_snapshot,
        email_verified
    ) VALUES (
        v_provider,
        v_issuer,
        v_subject,
        v_user_id,
        v_email,
        COALESCE(p_email_verified, false)
    );

    RETURN v_user_id;
END;
$$;

COMMENT ON FUNCTION public.marketroute_resolve_external_identity_v1(text, text, text, text, boolean) IS
    'Build 5 trusted-server resolver. Maps a verified Cognito subject to an internal MarketRoute actor UUID and never exposes the external subject as domain identity.';

REVOKE ALL ON TABLE public.marketroute_external_identities FROM PUBLIC;
REVOKE ALL ON FUNCTION public.marketroute_resolve_external_identity_v1(text, text, text, text, boolean) FROM PUBLIC;

COMMIT;
