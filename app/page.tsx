const principles = [
  "Evidence before authority",
  "Unknown never means false",
  "AI interprets; deterministic systems govern",
  "Workflow state is not authority state",
  "No V1 runtime dependency",
];

export default function Home() {
  return (
    <main className="shell">
      <div className="grid" aria-hidden="true" />
      <section className="hero">
        <div className="eyebrow"><span /> MARKETROUTE V2 · BUILD 3</div>
        <h1>Evidence<br /><em>before judgement.</em></h1>
        <p className="lede">
          Canonical sources, immutable provenance and deterministic evidence identity. MarketRoute can now accumulate research without turning raw evidence into commercial judgement.
        </p>
        <div className="route" aria-label="Constitutional authority path">
          <span>Evidence</span><i /><span>Truth</span><i /><span>Authority</span><i /><span>Action</span>
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
