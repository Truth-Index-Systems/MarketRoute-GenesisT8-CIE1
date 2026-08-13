# opportunities

Build 9 introduces the authority/workflow lifecycle application boundary.

It does **not** create opportunities and does not implement opportunity ranking; those remain Build 11 responsibilities. It can:

- read the current R4 → R5 → R6 authority envelope;
- record an idempotent founder human review for an existing `REVIEWABLE` opportunity;
- preserve approval/rejection independently of later authority expiry;
- ask the single shared `isExecutableNow` predicate.

Direct workflow DML remains forbidden.
