# MarketRoute V2 — Production Hotfix 0.18.3.3

## Purpose

Fix the final PostgreSQL ambiguity exposed by the first successful autonomous Genesis Truth pass.

Production error:

`column reference "input_fingerprint" is ambiguous`

The failure occurred inside `marketroute_persist_entity_truth_v1` after evidence ingestion, claim/evidence linking, claim Truth context, and claim Truth persistence had all succeeded.

## Root cause

`marketroute_persist_entity_truth_v1` returns a table containing an output column named `input_fingerprint`. Its idempotency lookup also referenced `truth_entity_snapshots.input_fingerprint` without qualifying the table. In PL/pgSQL, that made the name ambiguous between the output variable and table column.

## Fix

The lookup now aliases `public.truth_entity_snapshots AS tes` and qualifies the complete predicate, including `tes.input_fingerprint`.

No Truth mathematics changed. No evidence semantics changed. No R4/R5/R6 authority path changed. No append-only protections were weakened.

## Deployment

1. Apply `APPLY-IN-SUPABASE-MARKETROUTE-V2-0.18.3.3-HOTFIX.sql`.
2. Deploy the 0.18.3.3 ZIP so the canonical migration history also contains the repair.
3. Re-enable autonomous Growth if it was disabled.
4. Verify `/api/cron/growth`: `marketroute_persist_entity_truth_v1` should return success and the action should continue to completion rather than `marketroute_growth_fail_action_v1`.

## Expected production progression

OpenAI/web search → evidence ingestion → claim/evidence links → claim Truth → entity Truth → growth action completion.
