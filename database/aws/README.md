# AWS production database history

This directory is the clean MarketRoute AWS database-history boundary.

**Build 1 creates no database schema and no database resource.**

Do not copy or replay `supabase/migrations/` or the root `APPLY-IN-SUPABASE-*.sql` chain here. Those files remain RC 0.68 forensic/behavioural reference only.

AWS database history begins with the flattened canonical baseline created and frozen in **AWS-V0 Build 3**:

```text
0001_marketroute_aws_canonical_baseline.sql
0002_marketroute_cognito_identity_mapping.sql
```

`0001` is immutable and represents the final required MarketRoute schema with zero development/customer/research rows at baseline application time. Build 2 created the empty Aurora foundation and Build 3 compiled, applied and certified the canonical baseline.

Build 5 begins additive AWS migration history with `0002_marketroute_cognito_identity_mapping.sql`. It maps external Cognito identity to the canonical internal `public.marketroute_users.id` without changing Truth, CIE/UDOSIB, R4/R5/R6, tenancy, entitlement, or commercial semantics.
