# Authority

Build 9 keeps exactly three authority writers:

- `marketroute.r4.commercial-reality` — Commercial Reality.
- `marketroute.r5.relationship-graph` — structural Route Authority.
- `marketroute.r6.contact-truth` — Contact Authority.

Build 9 adds a **derived authority lifecycle**, not a fourth writer. It composes only current R4 → R5 → R6 decisions into a categorical lifecycle state and a single `authorityReady` predicate.

Human workflow state is independent. An opportunity may remain `APPROVED` while its authority becomes stale; revalidation of R4/R5/R6 never rewrites founder intent. Execution permission is still not an authority writer and does not exist until the later engagement build.
