# MarketRoute V2 research-plan persistence hotfix — 0.18.3.11

The first production research cron reached deterministic planning but failed when `marketroute_persist_research_plan_v1` validated and persisted the plan.

## Root causes

1. PostgreSQL serialised the database-generated `referenceTime` with a numeric UTC offset such as `+00:00`. The TypeScript planner correctly normalised the same instant with `Date#toISOString()`, which ends in `Z`. The RPC hashed the raw PostgreSQL representation and rejected the otherwise identical work unit as `MARKETROUTE_RESEARCH_WORK_DEDUPE_MISMATCH`.
2. After that check, the table-return columns `plan_id` and `plan_fingerprint` shadowed unqualified table columns in plan deduplication queries. PostgreSQL would reject those references as ambiguous.

## Repair

- Canonicalise the database-side work-unit fingerprint time as UTC ISO 8601 with milliseconds and `Z`, matching JavaScript exactly.
- Qualify all plan fingerprint and work-unit plan ID references with table aliases.
- Name the plan fingerprint unique constraint explicitly in `ON CONFLICT`.
- Preserve service-role-only execution, database recomputation, immutable plan/work-unit semantics and all budget checks.
- Add no Truth, R4, R5, R6, opportunity or workflow authority writer.

The observed run failed before `api.openai.com` was called, so it incurred no research-provider cost. The scheduler run and lease were closed normally; no manual retry reset is required.

## Deployment

1. Apply `APPLY-IN-SUPABASE-MARKETROUTE-V2-0.18.3.11-RESEARCH-PLAN-PERSISTENCE-HOTFIX.sql` in Supabase SQL Editor.
2. Deploy the accompanying application ZIP.
3. Allow the next `/api/cron/research` invocation to run. It should persist work units and then progress to the research worker.
