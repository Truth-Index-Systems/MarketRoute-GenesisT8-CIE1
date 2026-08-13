# Relationships application boundary

The service can register evidence-backed canonical relationship assertions and evaluate R5. It cannot create relationship Truth directly: evidence is persisted first, the generic Truth Engine evaluates `relationship.exists`, and only then may R5 traverse the edge.
