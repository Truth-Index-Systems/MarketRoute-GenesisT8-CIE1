# MarketRoute V2 — Build 15C Readability & Seller Identity Onboarding

## Purpose

This patch corrects two product-experience issues identified after Build 15B:

1. customer-facing typography was too small across the application;
2. onboarding exposed an internal workspace slug as though it were a customer-facing URL.

## UI changes

- Raises the working type scale across navigation, tables, cards, authority views, research views, provenance, authentication and onboarding.
- Keeps micro labels subordinate, but removes 7–9px fine-print styling from operational information.
- Increases form labels, input text, helper copy and primary action sizing.
- Preserves the Build 15B light/off-white MarketRoute identity, navy structure and MarketRoute blue.

## Onboarding changes

The user now supplies:

- Organisation name
- Company website, for example `https://truthindexsystems.co.uk`

The user no longer creates or sees a technical workspace slug during onboarding.

`marketroute_create_workspace_with_seller_v1` generates the internal organisation slug and atomically creates the first `seller_businesses` identity using the supplied website and canonical domain.

## Constitutional boundary

This patch does not create or mutate:

- Truth authority;
- R4 Commercial Reality;
- R5 Route Authority;
- R6 Contact Authority;
- opportunity authority;
- engagement authority;
- execution permission.

The added SQL is onboarding/application persistence only.
