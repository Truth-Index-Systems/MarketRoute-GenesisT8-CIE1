import type { AwsDataApiOperationDefinition } from "./aws-data-api-types";

export type AwsDataApiOperationName =
  | "system.health"
  | "system.currentDatabase"
  | "commercial.publicPlans"
  | "genesis.growthSettings"
  | "truth.policyBinding"
  | "identity.resolveActor";

export interface AwsDataApiOperationInputMap {
  "system.health": Record<string, never>;
  "system.currentDatabase": Record<string, never>;
  "commercial.publicPlans": Record<string, never>;
  "genesis.growthSettings": Record<string, never>;
  "truth.policyBinding": {
    subjectType: string;
    claimKey: string;
  };
  "identity.resolveActor": {
    provider: "COGNITO";
    issuer: string;
    subject: string;
    email: string | null;
    emailVerified: boolean;
  };
}

const OPERATIONS: Readonly<Record<AwsDataApiOperationName, AwsDataApiOperationDefinition>> = Object.freeze({
  "system.health": Object.freeze({
    name: "system.health",
    kind: "READ",
    sql: "SELECT 1::bigint AS ok",
    parameterNames: Object.freeze([]),
    maxRows: 1,
  }),
  "system.currentDatabase": Object.freeze({
    name: "system.currentDatabase",
    kind: "READ",
    sql: "SELECT current_database() AS database_name",
    parameterNames: Object.freeze([]),
    maxRows: 1,
  }),
  "commercial.publicPlans": Object.freeze({
    name: "commercial.publicPlans",
    kind: "READ",
    sql: `SELECT
      plan_code,
      display_name,
      monthly_price_gbp::double precision AS monthly_price_gbp,
      research_capacity_units,
      active_market_limit,
      team_seat_limit,
      metadata_json::text AS metadata_json
    FROM public.marketroute_plan_catalog
    WHERE public_visible IS TRUE
    ORDER BY sort_order, plan_code`,
    parameterNames: Object.freeze([]),
    jsonColumns: Object.freeze(["metadata_json"]),
    maxRows: 16,
  }),
  "genesis.growthSettings": Object.freeze({
    name: "genesis.growthSettings",
    kind: "READ",
    sql: `SELECT
      enabled,
      seed_target_company_count,
      launch_target_company_count,
      daily_budget_usd::double precision AS daily_budget_usd,
      max_action_cost_usd::double precision AS max_action_cost_usd,
      discovery_batch_size,
      max_actions_per_run,
      retry_hours,
      refresh_days,
      updated_at::text AS updated_at
    FROM public.genesis_growth_settings
    WHERE singleton IS TRUE
    LIMIT 1`,
    parameterNames: Object.freeze([]),
    maxRows: 1,
  }),
  "truth.policyBinding": Object.freeze({
    name: "truth.policyBinding",
    kind: "READ",
    sql: `SELECT
      policy_key,
      policy_version,
      max_age_days,
      known_support_family_requirement
    FROM public.marketroute_truth_policy_for_claim_v1(:subject_type, :claim_key)`,
    parameterNames: Object.freeze(["subject_type", "claim_key"]),
    maxRows: 1,
  }),
  "identity.resolveActor": Object.freeze({
    name: "identity.resolveActor",
    kind: "WRITE",
    sql: `SELECT public.marketroute_resolve_external_identity_v1(
      :provider,
      :issuer,
      :subject,
      :email,
      :email_verified
    )::text AS actor_user_id`,
    parameterNames: Object.freeze(["provider", "issuer", "subject", "email", "email_verified"]),
    maxRows: 1,
  }),
});

export function awsDataApiOperationDefinition(name: AwsDataApiOperationName): AwsDataApiOperationDefinition {
  return OPERATIONS[name];
}

export function awsDataApiOperationNames(): readonly AwsDataApiOperationName[] {
  return Object.freeze(Object.keys(OPERATIONS) as AwsDataApiOperationName[]);
}
