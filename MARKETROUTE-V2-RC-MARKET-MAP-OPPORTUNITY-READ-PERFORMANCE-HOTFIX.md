# MarketRoute V2 RC — Market Map + Opportunities Read Performance Hotfix

## Purpose

Remove the remaining list-page timeout class after the Command Centre performance repair.

The affected paths were:

- `/app/companies` (Market Map) → `marketroute_application_company_index_read_v1`
- `/app/opportunities` → full `marketroute_application_campaign_read_v1`
- `/app` → a second full campaign reread after the lightweight Command Centre read
- normal `/app/campaigns/[campaignId]` overview → full campaign read

The original list functions repeatedly evaluated `marketroute_opportunity_profile_v1`, which recursively recomputes the current R4/R5/R6 authority envelope. That work is appropriate for an exact opportunity detail/action boundary, but not for a 100–200 row overview.

## New read model

Migration `0058_market_map_opportunity_read_performance_hotfix.sql` introduces a bounded materialised list projection:

`marketroute_application_materialised_profile_index_v1`

It reads only persisted/indexed state:

- explicit campaign company scope;
- company identity;
- materialised opportunity workflow;
- latest persisted R4/R5/R6 records;
- their exact parent authority IDs/fingerprints;
- authority validity/revalidation times;
- invalidation/supersession/revocation events;
- the exact Truth entity snapshot referenced by persisted R4;
- latest canonical `opportunity_sync_events.authority_envelope_json`.

It does **not** call:

- `marketroute_opportunity_profile_v1`;
- `marketroute_list_opportunity_profiles_v1`;
- `marketroute_authority_envelope_v1`;
- `marketroute_r4_authority_current_v1`;
- `marketroute_r5_authority_current_v1`;
- `marketroute_r6_authority_current_v1`;
- `marketroute_opportunity_executable_now_v1`.

The list projection is capped at 250 rows and labelled `MATERIALISED_LIST_SUMMARY`.

## Ready-state safety

The fast projection does not grant execution authority.

A list item is shown as executable only when:

1. persisted R4/R5/R6 form the exact parent chain;
2. each persisted record is still within its authority validity/revalidation window;
3. none has a superseded/invalidated/revoked event;
4. the latest canonical opportunity-sync snapshot was authority-ready;
5. that sync snapshot references the exact same latest R4/R5/R6 authority record IDs;
6. the sync snapshot has not crossed `nextRevalidationAt`; and
7. workflow is `REVIEWABLE` or `APPROVED`.

This is a conservative presentation projection only. The detail and engagement paths still recompute exact current authority before exposing/executing sensitive actions.

## Application changes

- `COMPANY_INDEX` now uses the materialised projection rather than per-row opportunity profiles.
- New `OPPORTUNITY_INDEX` read resource lists only materialised opportunities without a full campaign read.
- `/app/opportunities` now uses `opportunityIndex()`.
- `/app` uses the lightweight Command Centre campaign summary + `opportunityIndex()`; it no longer performs a full campaign reread.
- normal non-archived campaign overview uses the same lightweight summary/index path.
- archived direct campaign URLs retain a canonical full-read fallback for historical compatibility.
- Market Map company links use Next `Link`/prefetch rather than full document navigation.
- Discovery filtering remains server-side and can only reduce the list to the already-authorised company/opportunity IDs.

## Constitutional boundary

Unchanged:

- exactly three authority writers: R4, R5, R6;
- no AI authority;
- no opportunity/workflow mutation;
- no Truth mutation;
- no engagement/delivery mutation;
- autonomous delivery remains disabled;
- exact company detail still calls `ApplicationReadService.company()`;
- route detail still calls `routeDisplay()`;
- engagement currentness/execution gates are untouched.

## Deployment

1. Run `APPLY-IN-SUPABASE-MARKETROUTE-V2-RC-MARKET-MAP-OPPORTUNITY-READ-PERFORMANCE-HOTFIX.sql`.
2. Deploy the aligned RC ZIP.
3. Reload `/app`, `/app/companies`, `/app/opportunities`, and an active campaign overview.
4. In Vercel logs, Market Map should call `marketroute_application_company_index_read_v1` without the old per-company authority RPC chain.
5. Opportunities should call `marketroute_application_opportunity_index_read_v1` instead of `marketroute_application_campaign_read_v1`.
6. Opening a specific opportunity should still invoke the exact canonical company/route read path.

## Validation

- dedicated static gate: 15/15 PASS
- dedicated adversarial gate: 14/14 PASS
- Build 13 canonical read model: 21/21 + 16/16 + 17/17 PASS
- Build 15 UI: 30/30 + 18/18 PASS
- Product Build 22: 15/15 + 10/10 PASS
- Product Build 24: 20/20 + 11/11 PASS
- Product Build 26: 20/20 + 12/12 PASS
- Command Centre performance gate: 10/10 + 10/10 PASS
- Build 18 release certification: 40/40 PASS
- full red-team: 22/22 PASS
- full `npm run production:check`: PASS
- TS/TSX syntax sweep: 208/208 PASS

A full local `next build` could not be executed in the clean release container because the release ZIP intentionally contains no `node_modules`, and one npm dependency was not available in the offline cache. No dependency or package version was changed.
