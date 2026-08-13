# MarketRoute V2 — Build 1 Constitutional Repository Foundation

## Outcome

Build 1 creates the clean-room repository constitution for MarketRoute V2. It deliberately implements no commercial authority.

## Architectural guarantee

The repository begins with a whitelist rather than a legacy migration. Runtime layers are `core`, `platform`, `application`, `ui`, and `app`. Dependency direction is enforced automatically. Core cannot reach platform/application/UI; the authority core is explicitly forbidden from importing AI transport.

## AI boundary

AI may interpret unstructured information, classify semantics, summarise evidence, propose research hypotheses, generate language, and make categorical language-quality judgements. AI may not grant Truth probability without empirical calibration, commercial viability, route authority, contact authority, execution permission, or convert numeric confidence into workflow authority.

## V1 quarantine

The V2 runtime forbids V1-era compatibility/legacy directories and known legacy authority tokens. V1 can later be read by a one-way ETL build only.

## Authority manifest

Build 1 contains zero authority writers. Future authority stages are declared conceptually but cannot be implemented invisibly. The manifest establishes that UI may not construct authority and workflow state is separate from authority state.

## Database policy

Build 1 owns no SQL. The fresh Supabase schema begins in Build 2 rather than allowing repository scaffolding to casually define persistence contracts.

## Visual shell

A minimal compile-only MarketRoute V2 page uses the product's blue system (`#2F8CFF` / `#76B6FF`) on a dark grid. It is not the final V2 landing page or application design system.

## Exit criteria

- all constitutional validators pass;
- adversarial import/path fixtures pass;
- project typechecks;
- Next.js production build compiles;
- no database migration exists;
- no authority writer exists;
- no V1 runtime dependency exists.
