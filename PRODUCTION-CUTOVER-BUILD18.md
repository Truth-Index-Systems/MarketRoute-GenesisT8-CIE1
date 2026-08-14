# Build 18 Production Cutover Checklist

## Source candidate

- Build 17 source SHA-256: `c5dd0cc7950b1be8824c24b40f4c9b9c4bc5cb74d206e44bf823d0804fab4e5e`
- Build 18 adds no Supabase migration.
- Expected latest migration: `0019_v1_evidence_migration.sql`.

## Before cutover

- Run the Build 17 V1 factual/evidence migration.
- Confirm migrated campaigns start in `DRAFT` and cannot silently trigger autonomous execution.
- Confirm V2 has recomputed Truth/R4/R5/R6 for the chosen certification company.
- Run `npm run constitution:check`.
- Run `npm run certification:cutover-preflight`.

## Live lineage proof

Set the following in a secure shell/server environment (never browser code):

```text
SUPABASE_URL=
SUPABASE_SERVICE_ROLE_KEY=
MARKETROUTE_CERT_ORGANISATION_ID=
MARKETROUTE_CERT_CAMPAIGN_ID=
MARKETROUTE_CERT_COMPANY_ID=
```

Then run:

```text
npm run certification:live-lineage
```

Expected proof:

- canonical application read exists;
- current Truth entity snapshot exists;
- current R4 exists;
- current R5 points to that R4;
- current R6 points to that R5;
- a Truth claim can be traced to a claim row;
- the claim has evidence;
- evidence reaches an acquisition;
- acquisition reaches a source;
- opportunity/engagement projection is present where materialised.

For Build 17 migration certification, sample at least one lineage whose evidence or claim-evidence link is marked `MIGRATED`.

## Stale-send safety smoke

Before enabling real delivery, use a non-production/test opportunity to prove that invalidating/expiring current authority prevents a queued item from being claimed for delivery and records `BLOCKED_STALE` rather than sending.

## Freeze

After the lineage and send-gate smoke pass:

- freeze the deployed Git commit;
- freeze migration history through `0019`;
- preserve the Build 17 export bundle and migration audit mapping;
- record the Build 18 ZIP SHA-256;
- record the live trace output in the internal release evidence store.
