# MarketRoute V2 RC — Campaign Activation Lineage Modernisation

## Why this patch exists

The multi-campaign UI and plan governance were modern, but production bootstrap still inherited one legacy assumption: `workspace_activation_jobs` allowed only one row per organisation and additional campaign submissions reused that row with `ON CONFLICT(organisation_id)`.

On a workspace originally created through anonymous Discovery, that could make a newly configured campaign look like the original anonymous activation to bootstrap. In particular, a grandfathered `LEGACY_FULL` workspace could still have an unexpired claimed Discovery run, so a new campaign could incorrectly receive anonymous launch policy (10 targets / USD 1 lifetime research / one concurrent research job).

## What changed

- Removes the one-row-per-organisation activation constraint.
- Every activation request now has an explicit kind:
  - `WORKSPACE_INITIAL`
  - `ANONYMOUS_DISCOVERY`
  - `CUSTOMER_CAMPAIGN`
- Every additional campaign submission inserts a fresh immutable activation job.
- Only one PENDING/RUNNING activation may exist per organisation at a time.
- Campaigns can carry an exact `activation_job_id` lineage.
- Bootstrap claims `marketroute_claim_workspace_activation_v4` and receives `activation_kind`.
- Anonymous activation policy is now job-bound through `marketroute_anonymous_discovery_policy_for_activation_v1(organisation_id, activation_job_id)`.
- `CUSTOMER_CAMPAIGN` work can never receive anonymous Discovery policy, including on `LEGACY_FULL` workspaces.
- Campaign creation is job-bound through `marketroute_create_activation_campaign_v4`; retry idempotency no longer searches by matching name/objective.
- `marketroute_submit_campaign_v3` is the canonical additional-campaign submission RPC.
- Older `marketroute_submit_campaign_v2` and `marketroute_submit_replacement_campaign_v1` remain only as wrappers to v3.
- Initial workspace setup cannot be used as an alternate add-campaign endpoint after a campaign already exists.
- Anonymous free-eight unlock/status now use `anonymous_discovery_runs.original_campaign_id` directly and never fall back to a later active customer campaign.

## Existing-workspace repair

If an anonymous Discovery activation row was already overwritten by a later campaign submission, migration 0056 repairs it transactionally:

1. creates a historical immutable `ANONYMOUS_DISCOVERY` activation job,
2. rebinds the anonymous run to that job,
3. preserves `original_campaign_id`,
4. classifies the currently reused job as `CUSTOMER_CAMPAIGN`, and
5. backfills campaign-to-activation lineage where exact history is still available, and
6. repairs an already-created customer campaign only when its research policy still exactly resembles the frozen anonymous launch policy (<= $1/day, <= $0.35/job, 1 concurrent job, <=3 work units, >=12h refresh).

No Truth or authority data is rewritten.

## Product behavior after deployment

`Add campaign` remains always visible to workspace owners/admins. Configuration occurs first. Plan capacity is checked at submission. If allowed, a new `CUSTOMER_CAMPAIGN` activation job is created and bootstrap follows the normal customer path using paid/full research policy rather than the anonymous 10/$1/12h envelope.

Discovery remains permanently attached to its original campaign and original activation lineage.

## Deployment

1. Apply `APPLY-IN-SUPABASE-MARKETROUTE-V2-RC-CAMPAIGN-ACTIVATION-LINEAGE-MODERNISATION.sql` in Supabase.
2. Deploy the matching RC repository to Vercel.
3. Start a fresh additional campaign from `/app/campaigns/new`.
4. Inspect the next `/api/cron/bootstrap` invocation. A customer campaign should progress through seller context, campaign creation and target selection. It must not use anonymous launch policy.

No new environment variables are required.

## Validation

- Campaign activation lineage static gate: 18/18
- Campaign activation lineage adversarial gate: 13/13
- Multi-campaign static gate: 21/21
- Multi-campaign adversarial gate: 16/16
- Production activation: 22/22
- Anonymous Discovery: 24/24 + 8/8
- Free Eight / account claim: 17/17 + 9/9
- Claimed Discovery continuation: 18/18 + 14/14
- Release certification: 38/38
- Full red-team: 22/22
- Full `npm run production:check`: PASS
- TS/TSX syntax transpilation: 209/209

A local `npm ci`/full Next build was not available in the artifact container, because the release tree intentionally contains no `node_modules`; Vercel should perform the normal dependency install from `package-lock.json` during deployment.

## Constitutional boundary

This migration is orchestration/commercial-product state only. It creates no new authority writer and does not change Truth, R4, R5, R6, CIE/UDOSIB, opportunity authority, assisted Engagement authority, or autonomous-delivery state.
