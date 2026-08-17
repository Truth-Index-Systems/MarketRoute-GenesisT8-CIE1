# MarketRoute V2 — Product Build 19
## Demand-Driven Genesis

### Product decision
Genesis Growth is paused. MarketRoute no longer spends research budget expanding the database speculatively. Existing Genesis intelligence remains reusable; new discovery and research are driven by active customer campaigns.

### What changed
- Removed `/api/cron/growth` from the Vercel production schedule.
- Growth now defaults to `PAUSED` and requires both `MARKETROUTE_GROWTH_MODE=AUTONOMOUS` and `MARKETROUTE_GROWTH_ENABLED=true` to run manually in future.
- The Supabase migration disables the persisted Growth setting, cancels any active Growth scheduler run and releases its lease.
- The database growth scheduler now fails closed with `MARKETROUTE_GROWTH_PAUSED` while the setting is disabled.
- Existing Genesis company/evidence/route/contact intelligence is not deleted or altered.
- Customer activation remains bank-first and can use customer-specific web discovery where the existing bank is insufficient.
- Campaign research remains scoped to an organisation + campaign + company and governed by its existing research budget policy.
- Research work now records a request origin in its persisted payload: `CUSTOMER_CAMPAIGN` or `CUSTOMER_REFRESH`.
- Retry execution is explicitly recorded as `SYSTEM_RETRY` while retaining the original request origin.
- OpenAI usage telemetry now stores `researchOrigin` for customer activation, campaign research and dormant autonomous Growth calls.
- Founder operations now treats paused Growth as an intentional healthy state, removes the expected two-minute Growth heartbeat, and keeps the existing intelligence bank visible.

### Not changed
- Truth Index mathematics or authority.
- R4/R5/R6 deterministic authority ownership.
- Opportunity reasoning.
- Evidence provenance.
- Campaign lifecycle.
- Customer UI.
- Billing, anonymous discovery and free-eight entitlements (later product builds).
- Outbound delivery policy.

### Production application order
1. Apply `APPLY-IN-SUPABASE-MARKETROUTE-V2-PRODUCT-BUILD19.sql` in Supabase.
2. Deploy this application build.
3. Do **not** restore the Growth cron.
4. Keep `MARKETROUTE_GROWTH_MODE=PAUSED` and `MARKETROUTE_GROWTH_ENABLED=false` (the code is safe even if an old `MARKETROUTE_GROWTH_ENABLED=true` remains, because the new mode defaults to `PAUSED`).
5. Run `npm run validate:product-build19`.
6. Verify `/api/cron/bootstrap` and `/api/cron/research` continue working for an active customer campaign.
7. Verify no new `GENESIS_DATABASE_GROWTH_V1` action runs are created after cutover.

### Reigniting Growth later
Growth is preserved, not removed. Re-enabling it is an explicit future product decision requiring:
- persisted Growth setting enabled;
- `MARKETROUTE_GROWTH_MODE=AUTONOMOUS`;
- `MARKETROUTE_GROWTH_ENABLED=true`;
- deliberate restoration of `/api/cron/growth` to `vercel.json`.

This prevents an old environment variable or accidental deployment from restarting speculative spend.
