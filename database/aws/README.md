# AWS production database history

This directory is the clean MarketRoute AWS database-history boundary.

**Build 1 creates no database schema and no database resource.**

Do not copy or replay `supabase/migrations/` or the root `APPLY-IN-SUPABASE-*.sql` chain here. Those files remain RC 0.68 forensic/behavioural reference only.

AWS database history begins with the flattened canonical baseline created in **AWS-V0 Build 3**:

```text
0001_marketroute_aws_canonical_baseline.sql
0002_...
```

The future `0001` must represent the final required MarketRoute state with zero development/customer/research rows. Build 2 creates the empty Aurora foundation; Build 3 compiles and validates this baseline.
