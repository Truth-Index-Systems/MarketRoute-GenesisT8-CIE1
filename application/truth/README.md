# Truth application service

Build 4 orchestrates the pure `/core/truth` kernel and the RPC-only Truth persistence boundary.

The application does not decide whether a claim is KNOWN. It asks Supabase for the exact persisted evidence context, evaluates that context through the deterministic kernel, then submits the result back to an RPC that independently re-derives the categorical result from stored evidence before persistence.
