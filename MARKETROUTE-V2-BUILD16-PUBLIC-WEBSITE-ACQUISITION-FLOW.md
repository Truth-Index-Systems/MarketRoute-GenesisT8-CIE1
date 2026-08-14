# MarketRoute V2 — Build 16

## Public Website + Value-First Acquisition Flow

Build 16 creates the public commercial experience for MarketRoute without changing Genesis T8 authority, Truth, research, opportunity, contact or engagement logic.

### Product language rule

The public site answers the buyer's question before exposing the system vocabulary:

- what MarketRoute does;
- why a company is worth pursuing;
- how strong the research is;
- how the buyer is reached;
- when the opportunity is actionable.

Genesis T8, Truth Index and R4/R5/R6 remain credibility/provenance language beneath the commercial explanation.

### Acquisition flow

The build preserves the value-first decision made during Build 15:

1. Public website explains the product.
2. Visitor opens a full illustrative MarketRoute opportunity.
3. Only after the walkthrough does MarketRoute ask the visitor to create an account.
4. Onboarding collects the organisation identity and company website.

The homepage deliberately contains no direct `/signup` CTA.

### Public experience

The website now contains:

- clear hero positioning;
- example MarketRoute opportunity UI;
- lead-list versus commercial-opportunity comparison;
- four-stage product workflow;
- Company Truth explanation;
- Commercial Reality explanation;
- Relationship Route explanation;
- Contact Readiness explanation;
- full product walkthrough CTA;
- Genesis T8 credibility section;
- value-first launch access section;
- final commercial CTA;
- responsive navigation and footer.

### Visual identity

MarketRoute remains visually distinct from Truth Index Systems:

- off-white/light working canvas;
- white product surfaces;
- controlled navy gradients for high-emphasis commercial moments;
- MarketRoute blue as the signature action/route accent;
- approachable B2B SaaS spacing and typography;
- no black technical-centre aesthetic;
- no generic AI glow/dashboard treatment.

### Authority boundary

Build 16 is presentation only.

The public site imports no authority implementation, application read model, database repository or AI provider. It contains illustrative product examples only and cannot create commercial authority.

### Database

No Supabase migration is required for Build 16.

### Validation

Run:

```bash
npm run constitution:website
npm run constitution:website-adversarial
npm run constitution:check
```
