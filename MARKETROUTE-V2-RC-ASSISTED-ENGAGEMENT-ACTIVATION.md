# MarketRoute V2 RC — Assisted Engagement Activation

## Product decision
MarketRoute launches with **assisted engagement**, not autonomous outbound delivery.

The launch interaction is:

1. MarketRoute establishes a current executable opportunity and authorised contact route.
2. A paid/full workspace may ask MarketRoute to prepare an evidence-grounded message.
3. The existing categorical language reviewer must return `PASS`.
4. A human must explicitly approve the message.
5. The UI exposes the real external action: email, phone, LinkedIn/contact form/route, plus copy controls.
6. The human makes the contact outside MarketRoute.
7. The human clicks **Mark contacted**. MarketRoute records an append-only manual engagement event and advances the opportunity from `APPROVED` to `ENGAGED`.

MarketRoute never claims that it sent the message.

## Autonomous delivery is physically disabled
This patch does more than hide a toggle:

- `/api/cron/delivery` is removed from `vercel.json` scheduling.
- `runDeliveryCron()` always returns `ASSISTED_ONLY` and processes zero delivery work.
- `EngagementService.queueMessage()` throws `MARKETROUTE_ASSISTED_ENGAGEMENT_ONLY`.
- `EngagementService.deliverNext()` throws `MARKETROUTE_ASSISTED_ENGAGEMENT_ONLY`.
- `EngagementService.setPolicy()` rejects `AUTOPILOT`.
- the legacy queue API is hard-blocked with `MARKETROUTE_ASSISTED_ENGAGEMENT_ONLY`.
- delivery provider credentials are no longer part of the production environment contract.

The frozen Build 12 queue/send-time engine remains in source for forensic compatibility and regression coverage, but it is unreachable from the launch product runtime.

## Manual engagement database record
Migration `0050_assisted_engagement_activation.sql` adds append-only `engagement_manual_actions` and `marketroute_record_manual_engagement_v1`.

A manual contact can be recorded only when:

- caller is service-role mediated;
- actor is an active OWNER / ADMIN / MEMBER of the opportunity organisation;
- opportunity is currently `APPROVED`;
- organisation, campaign, seller and target are active;
- the exact path remains R6-authorised and the opportunity remains executable;
- the current engagement strategy matches the path;
- the current message passed categorical AI language review;
- the latest approval is explicit `HUMAN / APPROVE`;
- the authority-envelope fingerprint still matches strategy and approval.

The RPC writes no R4/R5/R6/Truth authority. On first valid manual contact it records the action and workflow event `FIRST_MANUAL_ENGAGEMENT_RECORDED`, then advances `APPROVED -> ENGAGED`.

## Commercial cost boundary
The eight free Discovery routes remain usable from Opportunities.

AI engagement drafting is **paid/full only**. The generation API checks commercial access before calling the engagement language provider. This prevents a claimed free Discovery workspace from creating an uncapped second AI-cost surface after the anonymous research budget has ended.

## UI
`/app/engagement` is now a commercial action desk showing:

- Ready to contact
- Prepared
- Needs approval
- Contacted
- prepared subject/body
- copy message
- open email / call / LinkedIn / contact form / route
- copy email/number/route
- human approval
- manual `Mark contacted`

The opportunity detail page uses the same assisted-engagement model.

## Deployment
1. Apply `APPLY-IN-SUPABASE-MARKETROUTE-V2-ASSISTED-ENGAGEMENT-ACTIVATION.sql`.
2. Deploy the repository ZIP.
3. No new environment variables are required.
4. Old `MARKETROUTE_DELIVERY_ENABLED`, Resend sender and delivery-batch variables are no longer needed by the launch runtime and may be removed from Vercel after deployment.

## Validation
- Assisted engagement static gate: 18/18
- Assisted engagement adversarial gate: 14/14
- Build 12 engagement engine: 27/27
- Build 12 SQL safety: 23/23
- Build 12 engagement adversarial: 26/26
- Build 12 database engagement adversarial: 54/54
- Production activation: 22/22
- Release certification: 32/32
- Full red-team replay: 22/22
- Complete `npm run production:check`: PASS
- TS/TSX syntax transpilation: 208/208
- Local full `tsc --noEmit` cannot start because the source bundle does not include installed `@types/node`, `@types/react`, or `@types/react-dom`; no modified-file diagnostics are produced before that dependency-level stop. Vercel remains the final Next/TypeScript compile gate.
