# MarketRoute V2 — Activation Company-Domain Hotfix 0.18.3.9

## Production evidence

After the seller-genome JSON repair, production advanced successfully through seller extraction and persistence, campaign creation, seller-context selection, research-policy creation, Genesis-bank retrieval and paid fallback discovery. The first call to `marketroute_ensure_activation_company_v1` then returned HTTP 400.

The activation RPC used `\\.` inside a standard PostgreSQL string for both `www` removal and hostname validation. PostgreSQL interpreted the resulting regular expression as requiring a literal backslash rather than matching a domain dot. A valid hostname such as `example.com` therefore failed the activation boundary. Genesis growth remained healthy because its equivalent RPC used the correct single-dot expression.

## Repair

Migration `0029_activation_company_domain_hotfix.sql` replaces the activation-company RPC at the same signature. It uses `[.]` for unambiguous dot matching, rejects double-dot domains, explicitly rejects an empty name before inserting a new global company, keeps existing company reuse and campaign scoping idempotent, and preserves service-role-only execution.

Web fallback discovery now drops empty company names before calling persistence. No Truth, R4, R5, R6, opportunity, engagement or execution authority writer is added.

## Deployment and recovery

1. Apply `APPLY-IN-SUPABASE-MARKETROUTE-V2-0.18.3.9-ACTIVATION-COMPANY-DOMAIN-HOTFIX.sql` in Supabase first.
2. Deploy this package to Vercel.
3. Run or await `/api/cron/bootstrap`.

Do not resubmit setup or create another campaign. The existing activation campaign and genome are already present, while the activation job remains retryable. The current bootstrap implementation re-extracts the seller genome and re-runs fallback discovery on retry, so applying the SQL before another cron invocation avoids wasting one of the remaining attempts and another paid call.

## Validation

- PostgreSQL-compatible regression: the deployed pattern rejects `example.com`; the corrected pattern accepts it.
- `npm run validate:hotfix-01839`
- `npm run typecheck`
- `npm run build`
- `npm run constitution:check`
