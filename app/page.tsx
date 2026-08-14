import { ButtonLink, Icon, MarketRouteLogo } from "@/ui";

export default function Home() {
  return (
    <main className="mr-front-door">
      <div className="mr-front-door__grid" aria-hidden="true" />
      <header className="mr-front-door__nav">
        <div className="mr-front-door__brand"><MarketRouteLogo /><span>by Truth Index Systems</span></div>
        <a className="mr-front-door__signin" href="/login">Sign in</a>
      </header>
      <section className="mr-front-door__hero">
        <div className="mr-kicker"><span /> MARKET INTELLIGENCE</div>
        <h1>Know who to target.<br /><em>Know why. Know the route in.</em></h1>
        <p>
          MarketRoute researches your market, qualifies commercial reality and maps evidence-backed routes to the people and channels worth pursuing.
        </p>
        <div className="mr-front-door__actions">
          <ButtonLink href="/preview" variant="primary" icon={<Icon name="arrow" size={16} />}>See MarketRoute in action</ButtonLink>
          <ButtonLink href="#how-it-works" variant="ghost">How it works</ButtonLink>
        </div>
        <div className="mr-front-door__route" id="how-it-works" aria-label="MarketRoute intelligence path">
          {[
            ["01", "Research"],
            ["02", "Truth"],
            ["03", "Commercial reality"],
            ["04", "Route"],
            ["05", "Contact"],
          ].map(([step, label], index, array) => (
            <div className="mr-front-door__route-step" key={step}>
              <span><small>{step}</small>{label}</span>
              {index < array.length - 1 && <i />}
            </div>
          ))}
        </div>
      </section>
      <section className="mr-front-door__promise">
        <div><span>01</span><strong>See the product first.</strong><p>Explore a complete example opportunity before MarketRoute asks you to create anything.</p></div>
        <div><span>02</span><strong>Create an account when it is useful.</strong><p>Account creation appears when you choose to build the same intelligence for your own market.</p></div>
        <div><span>03</span><strong>Your workspace becomes private.</strong><p>Seller context, research, authority and engagement remain scoped to your organisation.</p></div>
      </section>
      <footer className="mr-front-door__footer">
        <span>MarketRoute V2</span><span>Genesis T8 · Evidence → authority → action</span>
      </footer>
    </main>
  );
}
