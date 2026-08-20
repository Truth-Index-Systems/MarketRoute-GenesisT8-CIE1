# AWS V0 Build 5 — Cognito identity foundation

Status: FOUNDATION IMPLEMENTED, NOT YET LIVE-WIRED OR DEPLOYED

## Identity law

Cognito authenticates the human. Aurora identifies the MarketRoute actor.

The Cognito `sub` is an external identity key only. It must never become an organisation, campaign, opportunity, seller, entitlement, or other commercial-domain UUID. The trusted server resolves `(provider, issuer, subject)` through `public.marketroute_external_identities` to `public.marketroute_users.id` before invoking any actor-sensitive database routine.

## Cognito resources

`MrAwsV0CognitoStack` owns exactly one user pool and one public app client.

- email sign-in and self-service signup;
- verified email;
- MFA disabled for the initial V0 foundation;
- minimum password length 8 with lower/upper/numeric requirements and no symbol requirement;
- email-only account recovery;
- no app client secret;
- USER_PASSWORD_AUTH and REFRESH_TOKEN_AUTH enabled;
- access and ID token lifetime: 1 hour;
- refresh token lifetime: 30 days;
- token revocation enabled;
- Cognito deletion protection plus CloudFormation retain policy;
- no Cognito Hosted UI/domain.

The existing MarketRoute login/signup pages remain the product UI. Browser code does not receive AWS credentials.

## Server environment

The server-side Cognito boundary requires:

- `AWS_REGION`
- `MARKETROUTE_COGNITO_USER_POOL_ID`
- `MARKETROUTE_COGNITO_USER_POOL_CLIENT_ID`

There is intentionally no Cognito app client secret environment variable.

## Token verification

`platform/auth/cognito-auth.ts` verifies Cognito JWTs server-side using the user-pool JWKS and rejects:

- non-RS256 tokens;
- unknown signing keys;
- invalid signatures;
- issuer mismatch;
- token-use mismatch;
- expired tokens;
- app-client audience/client-id mismatch.

`GetUser` is then used to retrieve the canonical Cognito `sub`, email and email-verification state for the authenticated access token.

## Aurora binding

`database/aws/0002_marketroute_cognito_identity_mapping.sql` is additive and must never be folded back into or overwrite the frozen Build 3 `0001` baseline.

`public.marketroute_resolve_external_identity_v1(...)` serializes first-bind races, creates a new internal `marketroute_users` row only when an external identity has never been seen, and returns the internal actor UUID. Disabled/suspended internal users are not accepted.

The Build 4 Data API allowlist is extended by Build 5 with the named WRITE operation `identity.resolveActor`. It remains parameterized and therefore retains Build 4's no-arbitrary-SQL boundary and no-write-auto-retry rule.

## Not yet done

This foundation does not yet replace the live Supabase session service, existing session cookies, authenticated PostgREST calls, password-reset UI, or discovery-claim wiring. Those are subsequent Build 5 gates after the Cognito stack and migration have been synthesized, deployed and live-proven.

`AWS_V0_AUTODEPLOY_ENABLED=false` remains the deployment safety position. The infrastructure workflow validates and synthesizes the Cognito stack but the existing automated deploy job still deploys only the database stack when the safety latch is intentionally enabled.
