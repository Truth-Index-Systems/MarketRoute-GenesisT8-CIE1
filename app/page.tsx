import { ButtonLink, Icon, MarketRouteLogo } from "@/ui";

export default function Home() {
  return (
    <main className="mr-front-door">
      <header className="mr-front-door__nav">
        <div className="mr-front-door__brand"><MarketRouteLogo /><span>by Truth Index Systems</span></div>
        <a className="mr-front-door__signin" href="/login">Sign in</a>
      </header>

      <section className="mr-front-door__hero">
        <div className="mr-kicker"><span /> B2B MARKET INTELLIGENCE</div>
        <h1>Know who to target.<br /><em>Know why. Know how to reach them.</em></h1>
        <p>
          MarketRoute researches your market, qualifies commercial reality and maps evidence-backed routes to the right people — so your team can see which companies are worth pursuing and act with a reason, not a lead score.
        </p>
        <div className="mr-front-door__actions">
          <ButtonLink href="/preview" variant="primary" icon={<Icon name="arrow" size={16} />}>See a real MarketRoute view</ButtonLink>
          <ButtonLink href="#how-it-works" variant="ghost">How MarketRoute works</ButtonLink>
        </div>
      </section>

      <section className="mr-front-door__process" id="how-it-works" aria-label="How MarketRoute works">
        <div className="mr-front-door__process-intro">
          <span>From market to action</span>
          <strong>MarketRoute turns research into a clear commercial decision.</strong>
        </div>
        <div className="mr-front-door__process-steps">
          {[
            ["01", "Research the market", "Find and verify the companies that matter."],
            ["02", "Prove the commercial case", "Separate real fit from assumptions and missing evidence."],
            ["03", "Map the route in", "Show the organisational path to a decision maker or viable channel."],
            ["04", "Act when it is ready", "Only surface outreach when the evidence and route still hold."],
          ].map(([step, title, body]) => (
            <article key={step}>
              <span>{step}</span>
              <strong>{title}</strong>
              <p>{body}</p>
            </article>
          ))}
        </div>
      </section>

      <section className="mr-front-door__trust">
        <div><span>Built for clarity</span><strong>Commercial language first.</strong><p>Genesis explains its reasoning without asking users to decode the underlying architecture.</p></div>
        <div><span>Built for trust</span><strong>Evidence stays visible.</strong><p>Known facts, unknowns, stale evidence and contradictions remain distinct throughout the product.</p></div>
        <div><span>Built for action</span><strong>Reachability is proven, not assumed.</strong><p>A company only becomes executable when the current commercial, route and contact chain allows it.</p></div>
      </section>

      <footer className="mr-front-door__footer">
        <span>MarketRoute V2</span><span>A Truth Index Systems product</span>
      </footer>
    </main>
  );
}
