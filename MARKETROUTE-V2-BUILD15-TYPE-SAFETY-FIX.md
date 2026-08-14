# MarketRoute V2 — Build 15 Type-Safety Compile Fix

## Scope

This patch is a narrow production-compile correction to Build 15. It does not change commercial reasoning, Truth, R4, R5, R6, opportunity authority, engagement authority, workflow semantics, database schema, or Supabase migrations.

## Vercel failure corrected

Vercel successfully completed webpack compilation, then failed during TypeScript validation in the Opportunity Workspace because a Truth-dimension tuple mixed a literal display label with a `JsonValue` read-model field. TypeScript widened the tuple elements so the label inherited `JsonValue`, which cannot be rendered directly as a React node when it may be an object or array.

The tuple representation was replaced with explicitly typed display rows:

- `label: string`
- `value: unknown`

The existing `percent(value)` presentation boundary remains responsible for safely converting the canonical read-model value for display. No commercial calculation moved into the UI.

## Additional warning cleanup

The Build 15 campaign switcher CSS now uses `align-items: flex-end` rather than `align-items: end`, removing the Autoprefixer mixed-support warning without changing intended layout.

## Verification

- Full `npm run constitution:check`: PASS
- Build 15 static gate: 29/29 PASS
- Build 15 adversarial gate: 18/18 PASS
- Architecture gate: 247/247 PASS
- Local source import resolution: zero unresolved imports
- No new Supabase migration
- No authority-writer changes
