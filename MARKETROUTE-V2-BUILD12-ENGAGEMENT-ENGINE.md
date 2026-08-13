# MarketRoute V2 — Build 12
## Engagement Engine

**Build:** 12 of 18  
**Migration:** `0015_engagement_engine.sql`  
**Application version:** `0.12.0`  
**Authority writers after this build:** exactly 3 (R4, R5, R6)  
**New authority writer:** none  

## 1. Purpose

Build 12 converts an already founder-approved and currently executable MarketRoute opportunity into an outbound engagement lifecycle without allowing outreach generation, AI review, queue state or delivery state to become a new source of commercial authority.

The governing chain is:

`Evidence → Truth → R4 Commercial Reality → R5 Route Authority → R6 Contact Authority → Authority Lifecycle → Opportunity → Engagement`

Engagement consumes the authority chain. It never replaces it.

## 2. Constitutional boundary

The build introduces six separate stages:

1. **Strategy creation** — binds one exact current R6-authorised path and channel.
2. **Language generation** — vendor-neutral provider generates channel-specific copy from a structured commercial brief.
3. **AI self-review** — categorical `PASS / REWRITE / BLOCK` only.
4. **Message approval** — human by default; explicit campaign `AUTOPILOT` policy is optional.
5. **Queueing** — re-proves current opportunity/R4/R5/R6 authority and binds the exact authority envelope.
6. **Delivery claim/send** — re-proves the live send gate immediately before external provider work.

No stage writes `authority_records`, `authority_events` or `authority_writer_registry`.

## 3. Grounded generation context

The language provider receives structured, provenance-bound context rather than raw website/evidence text:

- opportunity, organisation, campaign and company identity;
- active company name/domain;
- exact R6-authorised path fingerprint;
- exact terminal access point and route mode;
- exact named person for a named route, when applicable;
- seller objective key and explanatory objective statement;
- selected seller offering labels/descriptions;
- current **R4-satisfied target boundary facts** with claim key and observed value;
- exact authority-envelope fingerprint;
- exact R6 authority record/fingerprint.

Raw evidence excerpts are intentionally outside the generation boundary. This reduces prompt-injection surface and prevents unqualified research text from becoming outreach claims simply because a language model saw it.

The complete generation context is fingerprinted by PostgreSQL. A material change to the commercial brief or authority lineage makes the strategy non-current.

## 4. Strategy authority binding

A strategy can be created only when:

- the organisation is `ACTIVE`;
- the campaign is `ACTIVE`;
- the seller business is `ACTIVE`;
- the target company is `ACTIVE`;
- the opportunity workflow is `APPROVED`;
- `marketroute_opportunity_executable_now_v1(...)` is true;
- current R6 is `CONTACT_AUTHORISED`;
- the selected path appears in the exact R6 authorised bindings;
- the corresponding R5 path exists and has the same terminal access point;
- a named path points to an active person;
- the current R4 record is `COMMERCIAL_CANDIDATE`.

The strategy fingerprint binds the exact path, channel, access point, person, authority envelope and R6 authority.

## 5. Channel strategy

Access point type maps deterministically to channel:

- generic/department/personal email → `EMAIL`
- contact/department form → `CONTACT_FORM`
- LinkedIn → `LINKEDIN`
- switchboard/personal phone → `PHONE`
- explicit other → `OTHER`

The language model does not choose a more convenient channel than the route proven by R5/R6.

## 6. Message generation and rewrites

Messages are append-only and bound to one strategy/context fingerprint.

Rules:

- email requires a subject;
- non-email channels forbid an email subject;
- body length is bounded;
- rewrite ancestry is explicit;
- maximum rewrite ordinal is 2;
- one rewrite ordinal may exist only once per strategy;
- generation version and generation request id are forensically persisted.

The application performs at most the original generation plus two rewrites.

## 7. Categorical AI self-review

AI language review can return only:

- `PASS`
- `REWRITE`
- `BLOCK`

`REWRITE` and `BLOCK` require explicit reason codes.

Numeric or textual diagnostics may be stored as telemetry, but the queue never reads them. A score of `0` accompanying `PASS` and a score of `100` accompanying `PASS` have identical execution semantics.

PostgreSQL independently enforces:

- one AI review per message (prevents review shopping);
- primitive diagnostic values only;
- canonical diagnostic key grammar;
- authority/execution-like diagnostic keys forbidden;
- null/invalid reason codes rejected;
- exact review contract version.

## 8. Human-only default and autopilot

Campaign engagement policy is append-only and defaults to:

`HUMAN_ONLY`

Under `HUMAN_ONLY`, queueing requires the latest applicable human message approval to be `APPROVE`.

`AUTOPILOT` may create an explicit forensic `AUTOPILOT / APPROVE` event only after:

- the opportunity has already been founder-approved;
- the strategy is current;
- AI review is categorically `PASS`;
- the full authority envelope is still current.

Autopilot therefore cannot bypass opportunity approval or Genesis authority.

If an autopilot queue exists and policy is revoked before send, the send gate fails closed.

## 9. Human approval revocation

A queued human message does not permanently inherit an old approval row.

At send time PostgreSQL resolves the **latest human approval** for that message. A later human `REJECT` therefore prevents delivery even if the message had been queued earlier.

Message-approval mutations lock the opportunity row and are blocked while that opportunity has a `RUNNING` delivery, preventing a review/send race from producing ambiguous intent.

## 10. Queue lineage

Queue items are append-only and bind:

- opportunity;
- campaign/company;
- strategy;
- message;
- categorical AI review;
- human/autopilot approval;
- exact authority envelope JSON/fingerprint;
- queue request id/time.

One message can be queued only once.

A delivery job is mutable execution plumbing, not authority.

## 11. Send-time gate

Immediately before provider work, the database rechecks:

- workflow + current R4/R5/R6 through `marketroute_opportunity_executable_now_v1`;
- strategy currentness;
- categorical `PASS` review;
- current human approval or still-active autopilot policy;
- exact unchanged authority envelope;
- active organisation/campaign/seller/target through strategy currentness.

The gate returns a fingerprinted delivery payload only when all conditions hold.

The payload carries:

`idempotencyKey = queueItemId`

A delivery-provider implementation is constitutionally expected to honour this key.

## 12. Delivery concurrency and fairness

Build 12 deliberately serialises delivery at the opportunity boundary.

Only one delivery may be `RUNNING` for an opportunity. The claim transaction locks:

1. the candidate delivery job;
2. the campaign row;
3. the opportunity row;
4. then rechecks the live send gate.

Policy mutation locks the same campaign row. Human opportunity review and human message-approval mutation lock the same opportunity row.

This closes policy/review races with a concurrent claim.

The candidate query also:

- excludes opportunities already in flight;
- selects only the oldest pending delivery for each opportunity;
- uses `FOR UPDATE OF j SKIP LOCKED`.

Therefore a busy opportunity cannot sit at the head of the queue and starve unrelated opportunities, while FIFO is preserved within one opportunity.

## 13. At-most-once / unknown-state posture

Automatic delivery retries are intentionally not implemented.

`attempt_number` is bounded to one provider execution attempt.

If the provider definitively reports that nothing was sent, the job becomes `FAILED`.

If delivery state is unknown, the job becomes:

`RECONCILIATION_REQUIRED`

A `RUNNING` delivery abandoned for more than ten minutes is also moved to `RECONCILIATION_REQUIRED` because it may already have left the system.

This preference is deliberate: uncertain delivery must not become duplicate outreach.

## 14. First successful engagement

A successfully recorded first delivery transitions:

`APPROVED → ENGAGED`

and writes an append-only `opportunity_workflow_events` event with reason:

`FIRST_ENGAGEMENT_DELIVERED`

The original queue authority envelope remains attached to the historical workflow event.

If authority changes after the provider has already sent, the historical fact that engagement happened remains true.

## 15. External provider boundary

Build 12 ships two vendor-neutral interfaces:

- `EngagementLanguageProvider`
- `EngagementDeliveryProvider`

The default implementations are intentionally unconfigured and fail closed.

This release does **not** claim to include a live OpenAI, Anthropic, SendGrid, Resend, LinkedIn, telephony or contact-form provider.

A concrete provider can be introduced later without changing R4/R5/R6 authority semantics.

## 16. Persistence added by migration 0015

Append-only ledgers:

- `campaign_engagement_policy_events`
- `engagement_strategies`
- `engagement_messages`
- `engagement_ai_reviews`
- `engagement_message_approvals`
- `engagement_queue_items`
- `engagement_delivery_events`

Mutable execution plumbing:

- `engagement_delivery_jobs`

All direct application DML is revoked. Writes happen through scoped service-role RPCs.

`opportunities` remains direct-DML forbidden.

## 17. Existing RPC hardened, not changed in contract

`marketroute_record_opportunity_review_v1(...)` is rebuilt with its existing argument and `RETURNS TABLE` contract and gains an in-flight engagement guard.

Its PostgreSQL signature and OUT columns remain semantically identical to Build 9, specifically avoiding the historical function-return-type migration failure class.

## 18. Significant defects found and fixed during Build 12

The hardening process caught and closed:

1. **same-opportunity concurrent delivery race** — two messages could otherwise be claimed concurrently;
2. **cross-opportunity head-of-line blocking** — a busy oldest opportunity could starve unrelated work;
3. **same-opportunity FIFO inversion under concurrent workers** — newer message could otherwise win while oldest was locked;
4. **campaign policy race** — policy could change between the RUNNING check and delivery claim;
5. **human message-approval race** — approval/rejection could race an in-flight claim;
6. **queued human approval becoming immortal** — send gate now resolves the latest human decision;
7. **paused/archived commercial context** — active organisation, campaign, seller and target are now required;
8. **AI diagnostic payload parity** — PostgreSQL now independently rejects nested/authority-like diagnostic values and invalid keys;
9. **provider idempotency contract weakness** — delivery idempotency key is required, not optional;
10. **thin language context** — provider now receives current R4-satisfied facts and seller offering descriptions instead of only company/path labels.

## 19. Constitutional verification

Final complete Builds 1–12 regression:

**1,359 / 1,359 PASS** across **48 suites**.

Build-12-specific suites:

- Engagement static gate: **27/27 PASS**
- Build-12 SQL safety: **23/23 PASS**
- Pure Engagement adversarial: **26/26 PASS**
- Engagement database adversarial: **54/54 PASS**

Additional gates:

- changed Build-12 modules strict TypeScript compile: **PASS**
- whole V2 TS/TSX source transpilation: **63/63 PASS**
- standalone installer byte-identical to canonical migration `0015`: **PASS**
- Build-9 opportunity-review function input/output contract parity: **PASS**

## 20. Runtime verification limitation

The build environment used for this forensic pass does not contain a local PostgreSQL/Supabase server. Static SQL invariants, migration parity and function-contract checks pass, but the user's V2 Supabase project remains the final PL/pgSQL parser/runtime gate.

The same repository has already compiled in Vercel through Build 11. Build 12 source-level strict/transpile gates pass; Vercel remains the final complete framework/dependency compile gate.

## 21. Build 13 boundary

Build 13 is **Canonical Application API + Authoritative Read Model**.

It should not change the intelligence mathematics. Its purpose is to expose one stable application contract for:

- companies;
- Truth;
- R4/R5/R6;
- opportunity disposition;
- research pressure;
- engagement state;
- workflow;
- authority/invalidation lineage.

The UI must consume that contract rather than reconstructing authority from tables.
