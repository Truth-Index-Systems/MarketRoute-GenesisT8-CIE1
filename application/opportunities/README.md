# Opportunities application layer

Build 11 materialises an opportunity only from a current `AUTHORITY_READY` envelope. Product semantics are categorical and dimensional; there is no weighted opportunity score and no new authority writer.

System-owned states may move `RESEARCHING <-> REVIEWABLE`; `REVIEWABLE` is the compatibility storage value for customer-facing **Ready**. A second human opportunity approval is no longer required. Human message approval remains independent and opportunity synchronisation never writes engagement state.
