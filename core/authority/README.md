# Authority

Build 6 registers exactly one authority writer: `marketroute.r4.commercial-reality`.

The writer is implemented by the deterministic Commercial Reality core. It cannot import AI, application, UI, or database code. Persistence is only through the Build 6 R4 RPC, where PostgreSQL recomputes the decision inputs, boundary result, reasoning fingerprint, and authority fingerprint from persisted records.

Route authority (R5), contact authority (R6), and execution permission do not exist yet.
