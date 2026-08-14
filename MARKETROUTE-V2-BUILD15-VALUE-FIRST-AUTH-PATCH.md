# MarketRoute V2 — Build 15 Value-First Auth Patch

## Purpose

Correct the public entry journey without changing Genesis T8 commercial authority or application intelligence.

## User journey

Previous:

Home → `/app` → authentication wall

New:

Home → `/preview` → product-value walkthrough → `/signup` → workspace creation → `/app`

Existing users retain a quiet `/login` route from the public navigation.

## Changes

- Replaced the misleading "Open application preview" CTA with "See MarketRoute in action".
- Added a public illustrative opportunity walkthrough at `/preview` using the existing MarketRoute UI language.
- Clearly labels example data as illustrative; no fabricated live research is presented as factual intelligence.
- Added `/signup` and server-mediated Supabase password account creation.
- Added password confirmation and minimum 8-character validation.
- Supports both Supabase signup modes:
  - immediate authenticated session → `/onboarding`;
  - email confirmation required → notice on `/login`.
- Existing login remains available but is no longer the primary public CTA.
- Added explicit links between preview, signup and login.

## Constitutional boundary

No changes to:

- Truth Engine;
- R4 Commercial Reality;
- R5 Route Authority;
- R6 Contact Authority;
- opportunity mathematics;
- engagement execution authority;
- authority writers;
- database schema or migrations.

## Validation

- `npm run constitution:check` — PASS
- Build 15 live UI gate — 29/29 PASS
- Build 15 adversarial UI gate — 18/18 PASS
- Architecture gate — 252/252 PASS

## Supabase

No new SQL is required.
