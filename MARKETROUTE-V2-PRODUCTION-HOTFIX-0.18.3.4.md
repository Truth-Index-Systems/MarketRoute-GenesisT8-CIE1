# MarketRoute V2 Production Hotfix 0.18.3.4

## Purpose
Harden the OpenAI evidence grounding boundary after production surfaced `MARKETROUTE_PUBLISHER_DOMAIN_URL_MISMATCH` on otherwise grounded evidence.

## Root cause
OpenAI structured output contains both `sourceUrl` and `publisherDomain`. The runtime correctly requires `sourceUrl` to exactly match a URL actually consulted by hosted web search. However, after matching the URL, the provider previously preserved the model-supplied `publisherDomain` when non-null. If that metadata named a company/parent domain while the actual consulted URL belonged to a registry, newsroom, CDN, subdomain, or another publisher, the evidence canonicalizer correctly rejected the mismatch.

## Fix
- Treat the exact consulted URL as authoritative for publisher identity.
- Derive `publisherDomain` from the matched URL after grounding.
- Re-derive it again at persistence boundaries as defence in depth.
- Apply the same hardening to autonomous Genesis growth and campaign-scoped OpenAI research.
- Keep the canonical `MARKETROUTE_PUBLISHER_DOMAIN_URL_MISMATCH` guard intact.

## Database
No Supabase migration is required.

## Constitutional boundary
No Truth mathematics, R4/R5/R6 authority, opportunity ordering, execution permission, or evidence canonicalization rules were relaxed.
