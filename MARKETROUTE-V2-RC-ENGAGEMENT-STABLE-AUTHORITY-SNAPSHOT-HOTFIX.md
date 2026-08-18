# MarketRoute V2 RC — Engagement Stable Authority Snapshot Hotfix

## Why this exists

The first currentness hotfix removed the top-level engagement `evaluatedAt` from the generation-context fingerprint. Production then proved a second timestamp dependency remained: `authorityEnvelopeFingerprint` was calculated from the global authority envelope, whose JSON also contains `evaluatedAt`.

That made the sequence `create strategy -> OpenAI generation -> persist message` fail whenever the observation time changed between the two database calls, even when R4/R5/R6 were unchanged.

## Fix

- Adds `marketroute_engagement_authority_snapshot_fingerprint_v1(jsonb)`.
- The helper excludes only the authority envelope's observation timestamp (`evaluatedAt`).
- It retains organisation, campaign, company, lifecycle state, readiness, reason, next revalidation, R4/R5/R6 decisions, authority record IDs, authority fingerprints, parent lineage and validity.
- Engagement generation context now stores this stable fingerprint.
- Human message approval stores the same stable fingerprint.
- Manual `Mark contacted` compares against the same stable fingerprint.
- Generation-context fingerprint namespace advances to `MRV2-ENGAGEMENT-GENERATION-CONTEXT-1.0.2`, intentionally making pre-hotfix strategies stale. A fresh `Prepare message` creates a corrected strategy.

## Explicitly unchanged

- Global `marketroute_authority_envelope_fingerprint_v1` is not modified.
- R4/R5/R6 authority semantics are not modified.
- Exactly three authority writers remain.
- Human message approval remains required.
- Autonomous delivery remains disabled.
- No environment variables are added.

## Deploy

1. Run `APPLY-IN-SUPABASE-MARKETROUTE-V2-RC-ENGAGEMENT-STABLE-AUTHORITY-SNAPSHOT-HOTFIX.sql`.
2. Deploy the aligned repository.
3. Open a Ready opportunity and click `Prepare message` again.
4. Expected trace: generation context -> fingerprint -> create strategy -> OpenAI -> record engagement message (200) -> OpenAI review -> record engagement AI review (200).
5. Approve the message and verify `Mark contacted` remains available after time passes.
