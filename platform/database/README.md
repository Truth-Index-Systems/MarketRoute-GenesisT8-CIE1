# database

Backend database adapters live here.

Build 3 introduced RPC-only Evidence & Provenance persistence.
Build 4 adds RPC-only Truth context/persistence. Generic `reasoning_runs` / `reasoning_artifacts` direct writes are revoked from `service_role`; every future reasoning layer must expose its own audited persistence RPC.
