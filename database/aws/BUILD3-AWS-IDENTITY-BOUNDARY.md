# AWS V0 Build 3 — Internal Identity Boundary

Status: FROZEN FOR BUILD 3 DISPOSITION

This boundary replaces Supabase-specific database identity assumptions without changing MarketRoute tenancy, ownership, entitlement, or commercial semantics.

## Canonical internal identity

- The canonical database user key is an internal MarketRoute UUID.
- The AWS baseline will expose `public.marketroute_users` as the internal user relation.
- Organisation ownership, membership, seller ownership, campaign ownership, entitlement ownership, and claim/workspace attachment continue to reference internal UUIDs.
- External identity providers do not become canonical database identity.

## Build 5 binding boundary

Build 5 maps an external identity (Cognito subject) to an internal MarketRoute user UUID. Build 3 does not embed Cognito token claims, Cognito subjects, or provider-specific session state into commercial or Truth logic.

The server-side application resolves the external identity before database execution and passes the internal actor UUID explicitly to database routines that need user context.

## Supabase constructs removed from the canonical baseline

The AWS baseline must not depend on:

- `auth.users`;
- `auth.uid()`;
- `auth.role()`;
- `auth.jwt()`;
- `current_setting('request.jwt.*')`;
- PostgreSQL roles `anon`, `authenticated`, or `service_role`;
- RLS policies whose authorization model is tied to those roles;
- browser-to-database credentials.

## Rewrite rules

1. `REFERENCES auth.users(id)` becomes a foreign key to `public.marketroute_users(id)` while preserving delete/restrict semantics unless a later authoritative schema definition changes them.
2. Routines using `auth.uid()` are rewritten to receive the internal actor UUID explicitly. The actor UUID is supplied by the trusted server-side boundary.
3. Supabase `service_role` / request-JWT assertions are replaced by trusted backend execution. Build 4's Data API adapter is server-side only and allowlists database operations; Build 3 records this as a required transform rather than inventing a PostgreSQL session role.
4. Supabase role-bound RLS policies are excluded. Tenant and actor scope remain explicit in canonical table relationships and server-invoked routine contracts; browser SQL access is forbidden.
5. Cognito-specific mapping remains Build 5 work and does not alter frozen Truth/CIE/R4/R5/R6 semantics.

## Security invariant

Excluding Supabase RLS does not authorize untrusted direct database access. The AWS contract is server-side Data API execution only. IAM, secret access, adapter allowlists, parameterized database calls, organisation membership checks, and explicit internal actor UUIDs form the runtime boundary.

## Build 3 compiler meaning of “resolved”

A disposition may be decision-resolved while still requiring a transform. `decision_resolved=true` means the canonical treatment is known. It does not mean the SQL rewrite has already been emitted or validated. Required transforms must be applied by final-object resolution before the canonical baseline can be generated.
