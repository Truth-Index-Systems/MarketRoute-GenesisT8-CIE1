const principles = [
  "Truth is read, never reconstructed",
  "R4 → R5 → R6 remains the only authority chain",
  "Workflow and authority remain independent",
  "Research and engagement stay downstream",
  "The browser never reads authority tables directly",
];

export default function Home() {
  return (
    <main className="shell">
      <div className="grid" aria-hidden="true" />
      <section className="hero">
        <div className="eyebrow"><span /> MARKETROUTE V2 · BUILD 13</div>
        <h1>One state.<br /><em>One source.</em></h1>
        <p className="lede">
          MarketRoute now exposes a single canonical application contract for Truth, commercial reality, route authority, contact authority, research, workflow and engagement—without asking the interface to recreate the intelligence underneath it.
        </p>
        <div className="route" aria-label="Canonical application read path">
          <span>Genesis</span><i /><span>Read Model</span><i /><span>Application</span><i /><span>Interface</span>
        </div>
      </section>
      <section className="principles">
        {principles.map((principle, index) => (
          <article key={principle}>
            <small>{String(index + 1).padStart(2, "0")}</small>
            <p>{principle}</p>
          </article>
        ))}
      </section>
      <footer>MarketRoute by Truth Index Systems</footer>
    </main>
  );
}
