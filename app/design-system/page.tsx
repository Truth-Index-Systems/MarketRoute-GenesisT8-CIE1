import { ButtonLink, humanStatus, Icon, MarketRouteLogo, Panel, StatusBadge } from "@/ui";

export default function DesignSystemPage() {
  return (
    <main className="mr-design-page">
      <header className="mr-design-page__header">
        <a href="/" aria-label="MarketRoute home"><MarketRouteLogo /></a>
        <ButtonLink href="/app" variant="secondary" icon={<Icon name="arrow" size={15} />}>Open application</ButtonLink>
      </header>
      <section className="mr-design-hero">
        <div className="mr-kicker"><span /> MARKETROUTE PRODUCT SYSTEM</div>
        <h1>Commercial intelligence,<br /><em>made easy to trust.</em></h1>
        <p>MarketRoute inherits Truth Index Systems' precision and evidence discipline, then translates it into a calmer B2B product language: clear answers first, technical authority second.</p>
      </section>
      <section className="mr-design-grid">
        <Panel>
          <div className="mr-panel-label">MarketRoute identity</div>
          <div className="mr-swatch-row">
            {["#2F8CFF", "#76B6FF", "#0C65CF", "#07111F"].map((value) => <div className="mr-swatch" key={value}><i style={{ background: value }} /><code>{value}</code></div>)}
          </div>
        </Panel>
        <Panel>
          <div className="mr-panel-label">Status language</div>
          <div className="mr-badge-row">
            <StatusBadge label={humanStatus("ACTIONABLE")} tone="green" />
            <StatusBadge label={humanStatus("RESEARCH_REQUIRED")} tone="amber" />
            <StatusBadge label={humanStatus("CONTRADICTED")} tone="red" />
            <StatusBadge label={humanStatus("REVALIDATION_REQUIRED")} tone="slate" />
          </div>
        </Panel>
      </section>
    </main>
  );
}
