# Opportunities application layer

Build 11 materialises an opportunity only from a current `AUTHORITY_READY` envelope. Product semantics are categorical and dimensional; there is no weighted opportunity score and no new authority writer.

System-owned pre-human states may move `RESEARCHING <-> REVIEWABLE`. Human states remain independent and are never overwritten by opportunity synchronisation.
