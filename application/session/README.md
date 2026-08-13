# Session boundary

Build 15 authenticates through Supabase Auth on the server, resolves active organisation memberships on the server, and only then permits service-role canonical application reads. Browser code never receives the service-role key and never queries R4/R5/R6 tables directly.
