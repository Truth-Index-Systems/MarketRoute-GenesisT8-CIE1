import { ButtonLink, Icon, MarketRouteLogo } from "@/ui";

export default function Home() {
  return (
    <main className="mr-front-door">
      <div className="mr-front-door__grid" aria-hidden="true" />
      <header className="mr-front-door__nav">
        <MarketRouteLogo />
        <span>by Truth Index Systems</span>
      </header>
      <section className="mr-front-door__hero">
        <div className="mr-kicker"><span /> MARKET INTELLIGENCE</div>
        <h1>Know who to target.<br /><em>Know why. Know the route in.</em></h1>
        <p>
          MarketRoute researches your market, qualifies commercial reality and maps evidence-backed routes to the people and channels worth pursuing.
        </p>
        <div className="mr-front-door__actions">
          <ButtonLink href="/app" variant="primary" icon={<Icon name="arrow" size={16} />}>Open application preview</ButtonLink>
          <ButtonLink href="/design-system" variant="ghost">View design system</ButtonLink>
        </div>
        <div className="mr-front-door__route" aria-label="MarketRoute intelligence path">
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
      <footer className="mr-front-door__footer">
        <span>MarketRoute V2</span><span>Build 14 · Design system + application shell</span>
      </footer>
    </main>
  );
}
