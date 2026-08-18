# MarketRoute V2 RC — Command Centre Read Performance Hotfix

## Incident
Production returned PostgreSQL `57014 canceling statement due to statement timeout` from `marketroute_application_command_centre_read_v1` while loading application overview/navigation surfaces.

## Root cause
The Command Centre summary RPC iterated every non-archived campaign and called `marketroute_application_campaign_read_v1` for each campaign. The campaign read is intentionally detailed: it builds opportunity profiles and evaluates authority-derived lifecycle data per company. It also computed profile-derived aggregate counts separately. The Command Centre discarded the full opportunity payload, so overview/navigation reads paid the cost of detailed company authority evaluation across every campaign.

For Discovery access, the application service then performed another full campaign read per campaign solely to redact counters, creating a second N+1 path.

## Correction
Migration `0057_command_centre_read_performance_hotfix.sql` replaces only the Command Centre RPC implementation.

The Command Centre now uses:
- indexed campaign rows;
- indexed `organisation_company_scopes` counts;
- indexed materialised `opportunities` counts;
- grouped opportunity workflow counts;
- campaign-level research policy/budget snapshots;
- campaign-level assisted-engagement policy.

Readiness shown on the Command Centre is now explicitly the materialised workflow projection (`REVIEWABLE`, legacy `APPROVED`, or `ENGAGED`). This is a summary presentation projection, not a new authority decision or writer.

Detailed campaign/company reads are unchanged and continue to use current R4/R5/R6/Truth canonical logic when the user opens those resources.

The application-level Discovery redaction path no longer calls `repository.campaign()` per Command Centre row. It fails closed and caps all visible opportunity metrics to the already-authorised Discovery opportunity allowance.

## Constitutional boundaries
- No R4/R5/R6 writer changes.
- No Truth changes.
- No CIE/UDOSIB changes.
- No research orchestration changes.
- No billing changes.
- No autonomous delivery changes.
- Archived campaigns remain excluded.
- Service-role-only read boundary preserved.

## Deployment
1. Apply `APPLY-IN-SUPABASE-MARKETROUTE-V2-RC-COMMAND-CENTRE-READ-PERFORMANCE-HOTFIX.sql` in Supabase.
2. Deploy the aligned RC repository.
3. Reload `/app`, `/app/companies`, `/app/campaigns`, `/app/opportunities`, and `/app/engagement`.

No environment-variable changes are required.

## Validation
- Command Centre performance static: 10/10.
- Command Centre adversarial: 10/10.
- Build 13 canonical read model: 21/21.
- Build 13 SQL safety: 16/16.
- Build 13 adversarial: 17/17 + 35/35 database boundary replay.
- Build 18 release certification: 39/39.
- Full red-team: 22/22.
- Complete `npm run production:check`: PASS.
- Changed TypeScript read service: isolated TypeScript compile PASS.
