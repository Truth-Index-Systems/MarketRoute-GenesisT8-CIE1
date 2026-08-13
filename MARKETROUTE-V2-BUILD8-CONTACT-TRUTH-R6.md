# MarketRoute V2 — Build 8
## Contact Truth / R6

**Release:** Build 8  
**Migration:** `0011_contact_truth_and_authority_r6.sql`  
**Authority stage:** `CONTACT_AUTHORITY`  
**Writer:** `marketroute.r6.contact-truth` v1.0.0  
**Engine:** `MRV2-R6-ENGINE-1.0.0`  
**Semantics:** `MRV2-R6-SEMANTICS-1.0.0`

## Purpose

Build 8 completes the current R4 → R5 → R6 authority chain. R5 proves that an access path structurally exists. R6 decides whether that structural path is actually contact-authorised at the evaluation time.

For named-person routes, four independent Truth-qualified dimensions are mandatory:

1. canonical person identity;
2. current employment with the employer that appears on the actual R5 path;
3. at least one current role at that employer;
4. current ownership of the exact terminal personal channel.

Organisational routes (generic inboxes, contact forms, department-owned access points) do not require a fabricated named person.

## Contact claims

Build 8 defines canonical contact claim semantics on the existing evidence/claim/Truth substrate:

- `PERSON / identity.canonical_name`
- `PERSON / employment.current` with `companyId`
- `PERSON / role.current` with `companyId` + `roleTitle`
- `CHANNEL / ownership.current` with `personId`

Employment and role are not checked against the target company blindly. The employer is derived from the exact `employs` edge inside the R5 path. This keeps introduction routes correct: a person at an introducer company is validated against that introducer company.

## Truth policy

Identity retains the 365-day identity policy. Build 8 installs explicit policies for:

- current employment: 180 days;
- current role: 180 days;
- channel ownership: 120 days.

`KNOWN` and `SUPPORTED` are accepted categorical states when the Truth snapshot still has a future revalidation boundary. `CONTRADICTED`, `STALE`, `UNRESOLVED`, expired or mutated Truth cannot authorise a named route.

## Contradiction / ambiguity rules

R6 fails closed on ambiguous identity or personal-channel ownership. A competing currently-positive name or owner prevents authorisation. For roles, a contradiction blocks the same role proposition but does not erase a separately supported different current role at the same employer.

A person whose canonical lifecycle state is not `ACTIVE` cannot receive named-contact authority.

## Categorical output

R6 decisions:

- `CONTACT_AUTHORISED`
- `CONTACT_RESEARCH_REQUIRED`
- `CONTACT_NOT_APPLICABLE`

Path bindings:

- `ORGANISATIONAL_ROUTE / AUTHORISED`
- `NAMED_CONTACT / AUTHORISED`
- `NAMED_CONTACT / CONTACT_TRUTH_REQUIRED`

There is no contact score, contact confidence, route weight, probability or ranking in authority.

## Database independence

The persistence boundary independently verifies:

- current parent R5;
- exact parent fingerprint;
- exact contact-claim universe;
- exact Truth snapshot for every claim in that universe;
- exact evaluation timestamp;
- current Truth context fingerprint;
- person and employer structure extracted from the R5 path;
- person lifecycle state;
- contact bindings;
- authorised path set;
- authorised access-point set;
- research-required access-point set;
- distinct authorised access-point count;
- next revalidation boundary;
- input fingerprint;
- authority fingerprint.

The client supplies neither R6 input fingerprint nor authority fingerprint.

## Self-invalidation

`marketroute_r6_authority_current_v1` does not rely on a background invalidation worker. R6 ceases to be current when:

- parent R5 ceases to be current;
- the parent R5 fingerprint changes;
- a relevant contact claim is added/removed from the claim universe;
- a person lifecycle state changes;
- evidence changes a contact Truth context fingerprint;
- a contact Truth snapshot reaches its revalidation boundary;
- the R6 authority record is superseded, invalidated or revoked;
- its finite validity window expires.

R6 is capped at eight hours and can expire earlier from R5 or Contact Truth.

## Canonical contact-claim history

The four contact-authority claim types cannot be superseded. Changed research is represented as new evidence supporting/contradicting the immutable proposition, or as a different proposition (for example a different role title). This prevents authority history from being rewritten.

## Workflow boundary

Build 8 does not create, approve, reject, queue or send opportunities. No `opportunities` workflow state is mutated. Build 9 owns the unified authority lifecycle/workflow contract.

## Certification

Build-8-specific:

- Contact authority static: **27/27 PASS**
- SQL safety: **12/12 PASS**
- Contact authority adversarial: **25/25 PASS**
- Database boundary adversarial: **40/40 PASS**

Full Builds 1–8 constitutional regression: **858/858 PASS across 32 suites**.

Additional gates:

- strict evidence/contact kernel TypeScript compile: **PASS**
- strict changed-module TypeScript compile: **PASS**
- whole-source TS/TSX transpilation: **40/40 PASS**
- standalone SQL equals canonical migration `0011`: **PASS**

The local environment has no PostgreSQL/Supabase server, so the target Supabase project remains the final PL/pgSQL parser/runtime gate.
