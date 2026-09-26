# Build 11 — controlled live validation

Status: **operator tooling; live AWS proof NOT RUN by CI**. This is not an
activation or deployment authorisation. Keep PR #11 draft, and keep production
SQS consumption, model admission and recovery control disabled.

## First operation: collect prerequisites from CloudShell

The `build11-live-validation-kit` CI artifact contains only this guide, a Python
collector, synthetic request files and a database routine reference observed in
disposable PostgreSQL. It does not contain credentials, a migration runner or a
command which can deploy infrastructure or invoke a generative model.

Download/unzip the kit and enter its root directory, then run:

```sh
sha256sum -c SHA256SUMS
python3 scripts/build11-live-preflight.py --read-database
```

Use the existing **MarketRouteV0Administrator role session** in account
`801132668416`. Do not create/paste keys, use root, or enable a queue. Python 3.10+
and AWS CLI v2 are required; no npm or Python package installation is needed.

The collector writes `build11-live-preflight.json` with mode 0600 and refuses to
overwrite it. For a second capture, use `--out build11-live-preflight-2.json`.
Return the JSON receipt for review. The summary intentionally says BLOCKED:
collecting evidence is not passing live worker or pricing certification.

**Cost distinction:** CountTokens does not generate output and AWS documents it
as free. `--read-database` runs two fixed, read-only catalog/configuration SELECTs
if the verified database supports them. This may resume paused Aurora and incur
normal database/Data API charges. Omit that flag to avoid all database calls;
then the database prerequisite remains explicitly unverified. No customer rows,
secret values, tokens, access keys or unrelated Lambda environment values are
included. Account/resource ARNs and IAM policies are operational metadata: share
the receipt only with people authorised to review this account.

The collector uses pinned official regional endpoints, one CLI attempt, bounded
network timeouts and an explicit read-action allowlist. It has no mutation mode.
Errors retain only AWS error codes, not arbitrary response/error strings.

### Evidence collected

- Caller identity and account before any other AWS request; only role sessions in
  the expected account proceed. This is the **shell** identity, not Lambda proof.
- Application profile `1t6o6h9xl4qb`, exact Sonnet 4.5 model and seven-region EU
  route; current model lifecycle and ordinary (not 1M-context/global) RPM/TPM.
- Existing database/research stack metadata, research resource inventory, Aurora
  Data API status, and the database/secret ARNs from the verified database stack.
- Actual worker code SHA-256, Node22/ARM64/handler, layers, allowlisted configuration,
  inline IAM documents and managed-policy names. This permits policy review; it
  does not simulate or certify IAM authorisation.
- Event-source mappings (all must be Disabled; missing mappings are not a pass).
- One CountTokens request using fixed synthetic input and the **byte-identical
  native structured request** produced by the current prepared-provider module.
  Successful counting proves only this request under the shell caller.
- Optional database routine definition hashes, SECURITY DEFINER/public-execute
  flags, AWS table names and disabled controls. Compare against the actual
  PostgreSQL reference in the kit, not merely function names or stack status.

Routine equality does **not** verify every table constraint, role grant, index,
existing business row or prior migration execution receipt. Different PostgreSQL
DDL rendering can also require review. Do not infer that the complete database
migration is correct from these subset checks. The hashes/manifest are integrity
receipts, not cryptographic signatures or security attestations.

### Expected blockers and safe responses

| Finding | Meaning and next action |
| --- | --- |
| Worker ResourceNotFoundException | The reviewed package is not deployed here. Review a targeted research-stack change set; do not create a console Lambda by hand. |
| Routine contract mismatch or absent controls | Determine the precise missing/changed schema objects and migration history. Never replay baseline 0001 over an existing database. |
| AccessDenied | Inspect the named caller/resource permission. Do not grant AdministratorAccess or wildcard InvokeModel to make the test green. |
| CountTokens ValidationException | Verify this model/request/Region API support. Do not substitute an estimate, bypass cost admission, silently move Regions or switch models. |
| Enabled mapping/admission/recovery | Stop. Investigate the unexpected activation before a canary; the collector will not change it. |
| Wrong package or extra layers | Compare deployment code hash and package receipt. Do not test a different artifact and claim this candidate passed. |
| Timeout/DatabaseResumingException | Preserve the receipt. An explicit later read may be needed; no automatic paid retry is introduced. |

## Reviewed deployment sequence — after the receipt

These are gates, not commands to execute blindly. This stage does not run them.

1. **Inventory and rollback evidence.** Preserve the preflight, current template,
   stack parameters, database routine hashes and current deployment package. Check
   Aurora backup/PITR coverage and create/verify a recoverable snapshot before
   schema changes. The original database-stack source permits deletion, so never
   run an all-stack destroy/deploy as a rollback technique.
2. **Schema delta.** Review the exact current database against 0001–0007 hashes.
   Apply only missing, approved forward migrations using a trusted migration
   process with transaction/error handling and a durable migration ledger. SQL
   files contain multi-statement transactions: they are not single Data API
   ExecuteStatement requests. Do not split SQL on semicolons (function bodies
   contain them). No migration is applied by the collector or credential-free CI.
3. **Targeted infrastructure review.** Build/verify the research ZIP from the
   reviewed commit. Review `MrAwsV0ResearchStack` only. Required parameters are
   `AuroraSecretArn` from the verified database stack and the exact existing
   `BedrockInferenceProfileArn`. Confirm that only intended research resources,
   scoped policies and the verified package change; the SQS mapping stays off.
   Exclude database, identity, Cognito, application and observability-stack changes.
4. **Disabled deployment evidence.** Record change-set ID, exact commit, package
   SHA-256, parameters, resulting worker role and function revision. Verify live
   `CodeSha256` against the ZIP and rerun preflight. Publish/select a numeric
   immutable Lambda version for the canary after reviewing permission to do so.
   Do not certify `$LATEST` while another deployment can change it.
5. **Controlled synthetic worker proof.** Use one dedicated synthetic campaign,
   real canonical evidence records, a canonical job/reservation and the exact
   stored envelope. Fixture creation must be a reviewed isolated transaction,
   not the disposable-test baseline/fixture loader applied to production. Make
   sure no other executable research exists before a temporary model-scope
   enable. Set a hard canary budget of at most USD 0.05 and a single admitted
   provider attempt. Invoke the actual versioned worker once; do not add a
   diagnostic handler which bypasses admission or manually fabricate a receipt.
6. **Read the actual receipts.** Correlate Lambda request ID, version/role, request
   fingerprint, token count, Bedrock request ID, input/output usage, semantic
   artifact, canonical job and budget settlement. Schema conformance is not
   semantic correctness: inspect the synthetic result and its evidence IDs.
   A second delivery may test replay only after the first outcome is known;
   it must not add a provider receipt or budget event. An uncertain outcome goes
   to REVIEW_REQUIRED, never a blind paid retry.
7. **Restore off and document.** Turn the temporary model-scope admission back off
   using the reviewed control process, even on failure. Queue and recovery remain
   off throughout. Preserve data/receipts; do not delete evidence or refund an
   unknown request. A rollback must preserve new execution receipts and held
   reservations; never restore an old unguarded worker against them.

No claim is made that these future operational gates have happened. Full queue
transport/recovery remains a Build 13 integration dependency: the controller is
source-only, with no deployed scheduler or publisher. Production consumers cannot
be enabled until that connection and live queue timing/DLQ behaviour are proven.
Review-required work also needs monitored operator reconciliation before pilot.

## Model, request and pricing review (26 September 2026)

AWS's Sonnet 4.5 model card lists Count tokens and Structured outputs as supported,
with EU inference from London. The prepared native body uses
`output_config.format` on bedrock-runtime InvokeModel, not bedrock-mantle.
CountTokens support must still be observed for this exact account/Region/body.
New structured schemas may take minutes to compile; a cold request can exceed the
worker's existing timeout. Record that result honestly rather than extending a
lease/timeout or rerunning a possibly charged request without review.

The current accounting rates remain **USD 3.30 per million input tokens and
USD 16.50 per million output tokens**, with a 1,400-token output cap and no cache
or long-context path. Anthropic's current documentation corroborates a 10%
regional/multi-region premium. This is **not a newly verified AWS billing tariff**:
attach the exact dated AWS price dimensions for this EU standard route (or the
account's contracted price), then reconcile measured usage with billing evidence.
AWS credits do not make economic cost zero. Bedrock model charges may appear under
the model provider/AWS Marketplace rather than an Amazon Bedrock-only filter.
The collector always leaves live billing reconciliation as NOT_RUN.

## References

- https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-sonnet-4-5.html
- https://docs.aws.amazon.com/bedrock/latest/userguide/count-tokens.html
- https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_CountTokens.html
- https://docs.aws.amazon.com/bedrock/latest/userguide/structured-output.html
- https://docs.aws.amazon.com/cli/latest/reference/lambda/get-function-configuration.html
- https://docs.aws.amazon.com/cli/latest/reference/rds-data/execute-statement.html
- https://aws.amazon.com/bedrock/pricing/
- https://platform.claude.com/docs/en/about-claude/pricing
