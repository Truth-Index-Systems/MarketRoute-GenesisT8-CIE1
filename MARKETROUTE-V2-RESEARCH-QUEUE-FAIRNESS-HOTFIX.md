# MarketRoute V2 — Research Queue Fairness Hotfix

Date: 2026-08-18
Baseline: Product Build 26 — Full Product Experience + Research Capacity Type Hotfix
Version: 0.18.3 (frozen product/version family; orchestration hotfix only)

## Production symptom

A newly-started campaign successfully planned and persisted research work, but consecutive `/api/cron/research` invocations reached `marketroute_claim_research_work_v1` and then finished without executing research. Queue inspection showed overdue `GENESIS_RESEARCH_V1` work remaining `PENDING` with zero attempts.

The queue also contained older priority-10 `DECISION_BLOCKER` work ahead of priority-20 deterministic `CURRENTNESS_REPAIR` work.

## Root causes

### 1. Active-campaign filter regression

`0030_campaign_lifecycle_controls.sql` had hardened `marketroute_claim_research_work_v1` to join `campaigns` and require `c.workflow_state = 'ACTIVE'`.

Product Build 24 later replaced the claim function while adding anonymous/commercial-capacity enforcement and accidentally dropped that active-campaign predicate. Historical paused/archived queue rows could therefore participate in global queue ordering again.

### 2. Global head-of-line starvation

The Build 24 claim implementation selected exactly one queue-head row. If that row was blocked by policy, concurrency, plan capacity, anonymous limits, or budget, the function deferred/cancelled that row and immediately returned `NULL`.

The TypeScript scheduler correctly interprets `NULL` as no claimed work, so runnable jobs behind the blocked row were never examined in that invocation.

## Fix

Migration `0047_research_queue_fairness_hotfix.sql` replaces only `marketroute_claim_research_work_v1`.

It now:

- requires `campaign.workflow_state = 'ACTIVE'` before a row can enter claim ordering;
- excludes explicitly-disabled research policies before ordering;
- cancels queued `PENDING`/`DEFERRED` jobs belonging to `ARCHIVED` campaigns while retaining immutable research lineage;
- retains PAUSED jobs for later resume without allowing them to compete in the live queue;
- scans past blocked candidates using a PL/pgSQL loop rather than returning `NULL` after the first defer/cancel;
- skips a concurrency-blocked campaign for the remainder of the current claim call;
- skips a plan-capacity-blocked organisation for the remainder of the current claim call;
- skips an individually rejected work unit for the remainder of the current claim call, preventing loop-spin when its `available_at` remains due;
- deliberately does not skip a whole campaign after a unit-specific daily/lifetime budget rejection, allowing a zero-cost deterministic `REVALIDATE_R4/R5/R6` unit behind a paid AI unit to run;
- preserves the Build 20 anonymous discovery window/budget boundary;
- preserves the Build 24 paid research-capacity boundary;
- preserves scheduler lease validation and service-role-only execution;
- preserves all returned claim payload fields and `researchOrigin` semantics.

## Authority boundary

This hotfix is orchestration-only.

It does not create or modify an authority writer and does not write Truth, R4, R5, R6, opportunities, claims, evidence, engagement, billing entitlement, or commercial scoring semantics.

Growth remains paused. Autonomous outbound delivery remains off.

## Deployment

1. Run `APPLY-IN-SUPABASE-MARKETROUTE-V2-RESEARCH-QUEUE-FAIRNESS-HOTFIX.sql` in Supabase SQL Editor.
2. Deploy the accompanying ZIP so repository migration history and validators match production.
3. Observe the next `/api/cron/research` invocation.

The SQL is the actual runtime fix because `marketroute_claim_research_work_v1` executes in Supabase. No new Vercel environment variable is required.

## Expected first post-hotfix behaviour

On the next research cron, archived queue backlog should be cancelled and ignored. If an active priority-10 unit is blocked, the claim function should continue scanning instead of stopping. A runnable unit should transition from `PENDING`/`DEFERRED` to `RUNNING`, increment `attempt_count`, and produce a `research_budget_events` RESERVE event.

For `ACQUIRE_CLAIM_EVIDENCE` / other provider-backed work, an OpenAI/provider call should then appear in the Vercel trace. For zero-cost deterministic `REVALIDATE_R4/R5/R6`, no OpenAI call is required; the worker should execute the deterministic authority revalidation path.

## Validation

Dedicated hotfix gate:
- Static: 15/15
- Adversarial: 9/9

Explicit adversarial cases:
- blocked priority-10 + runnable priority-20 => runnable work can be claimed;
- archived priority-10 + active priority-20 => archived work cannot compete;
- exhausted AI budget + zero-cost deterministic revalidation => zero-cost unit remains runnable;
- capacity-blocked organisation cannot starve another organisation;
- paused campaign is retained but not claimable;
- disabled policy cannot become queue head;
- unit-specific defer cannot spin the same row inside one claim call.

Regression replay passed:
- Architecture boundary
- Research engine + SQL safety + adversarial
- R5 + SQL safety + adversarial
- R6 + SQL safety + adversarial
- Opportunity + SQL safety + adversarial
- Engagement + SQL safety + adversarial
- Build 18 release certification: 29/29
- Build 18 full red-team: 22/22
- Production activation: 22/22
- Founder dashboard validation
- Product Build 19: 21/21 + 4/4
- Product Build 20: 24/24 + 8/8
- Product Build 21: 16/16 + 9/9
- Product Build 22: 15/15 + 10/10
- Product Build 23: 17/17 + 9/9
- Product Build 24: 20/20 + 11/11
- Product Build 25: 17/17 + 12/12
- Product Build 26: 20/20 + 12/12

No application TypeScript/runtime source was changed by this hotfix.
