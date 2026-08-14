# MarketRoute V2 Production Hotfix 0.18.3.2

This supersedes 0.18.3.1. The first 0.18.3.1 SQL attempted to update `genesis_growth_budget_events`, which is constitutionally append-only. Because the script was wrapped in a transaction, PostgreSQL rolled the entire failed hotfix back.

## Fixes

- Preserves the `genesis_growth_budget_events` append-only trigger; it is never disabled or bypassed.
- Fixes `claim_id` ambiguity in `marketroute_record_claim_evidence_v1`.
- Fixes `attempt_count` ambiguity in `marketroute_claim_workspace_activation_v1`.
- Backfills historical paid discovery cost only onto mutable `genesis_growth_action_runs.actual_cost_usd`.
- Adds `marketroute_growth_effective_spend_v1`, which reads the greater of immutable ledger cost and action-run cost per action, preventing double-counting while recovering old failed-call spend.
- Growth budget gating and founder-dashboard spend now use effective spend.
- Preserves recovery-first repair of partially persisted 20%-density companies.
- Runtime code retains 0.18.3.1's paid-failure cost propagation so future failed persistence calls enter the immutable budget ledger with the actual incurred cost.

## Apply

1. Keep autonomous growth disabled while patching if it is still repeatedly failing.
2. Run `APPLY-IN-SUPABASE-MARKETROUTE-V2-0.18.3.2-HOTFIX.sql`.
3. Deploy the 0.18.3.2 ZIP.
4. Re-enable autonomous growth.
5. Confirm `marketroute_record_claim_evidence_v1` returns 200 and the growth action completes instead of calling `marketroute_growth_fail_action_v1`.
