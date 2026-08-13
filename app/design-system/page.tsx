import { ButtonLink, Icon, MarketRouteLogo, Panel, StatusBadge } from "@/ui";

export default function DesignSystemPage() {
  return (
    <main className="mr-design-page">
      <div className="mr-app-grid" aria-hidden="true" />
      <header className="mr-design-page__header">
        <a href="/" aria-label="MarketRoute home"><MarketRouteLogo /></a>
        <ButtonLink href="/app" variant="secondary" icon={<Icon name="arrow" size={15} />}>Open application shell</ButtonLink>
      </header>
      <section className="mr-design-hero">
        <div className="mr-kicker"><span /> MARKETROUTE V2 · BUILD 14</div>
        <h1>Intelligence,<br /><em>made legible.</em></h1>
        <p>A dark, blue-first interface system designed to explain commercial evidence and authority without reducing it to decorative scores.</p>
      </section>
      <section className="mr-design-grid">
        <Panel>
          <div className="mr-panel-label">Brand colour</div>
          <div className="mr-swatch-row">
            {["#2F8CFF", "#76B6FF", "#0C65CF", "#07111F"].map((value) => <div className="mr-swatch" key={value}><i style={{ background: value }} /><code>{value}</code></div>)}
          </div>
        </Panel>
        <Panel>
          <div className="mr-panel-label">Authority language</div>
          <div className="mr-badge-row">
            <StatusBadge label="ACTIONABLE" tone="green" />
            <StatusBadge label="RESEARCH REQUIRED" tone="amber" />
            <StatusBadge label="CONTRADICTED" tone="red" />
            <StatusBadge label="REVALIDATION" tone="violet" />
          </div>
        </Panel>
      </section>
    </main>
  );
}
