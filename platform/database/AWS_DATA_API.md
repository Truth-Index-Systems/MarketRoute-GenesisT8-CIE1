# AWS Data API boundary — Build 4

This directory now contains the first AWS-native database transport boundary for MarketRoute.

`aws-data-api.ts` exposes only named operations from `aws-data-api-operations.ts`. It deliberately does **not** expose generic SQL, table-name, or routine-name execution. The initial registry is read-only and exists to prove Aurora Serverless v2 Data API connectivity against migrated baseline/configuration data without touching fresh runtime state.

Required server-side runtime configuration:

- `AWS_REGION`
- `MARKETROUTE_AWS_RDS_CLUSTER_ARN`
- `MARKETROUTE_AWS_RDS_SECRET_ARN`
- `MARKETROUTE_AWS_RDS_DATABASE`

Build 4 intentionally leaves the current Supabase repositories untouched as the reference stack. The AWS SDK package is loaded only when `awsDataApiFromEnvironment()` is invoked; Build 6 will pin `@aws-sdk/client-rds-data` in the application dependency graph when the AWS transport becomes live application wiring.

Safety properties:

- operation registry owns every SQL statement;
- parameters are named and encoded separately from SQL;
- results are row-bounded per operation;
- JSON decoding is explicit per known column;
- safe read-only calls may retry transient Aurora resume/service errors;
- writes and transaction statements are never automatically retried;
- one Data API transaction cannot execute overlapping statements;
- errors expose operation name/provider code only, never SQL, ARN or secret material.
