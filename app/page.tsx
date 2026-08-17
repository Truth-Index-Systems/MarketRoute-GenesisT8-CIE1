import { ButtonLink, Icon, MarketRouteLogo } from "@/ui";

const process = [
  {
    step: "01",
    icon: "search" as const,
    title: "Research the market",
    body: "MarketRoute builds an evidence-backed view of the companies that could matter to your commercial objective.",
  },
  {
    step: "02",
    icon: "shield" as const,
    title: "Prove the commercial case",
    body: "It separates a real reason to pursue a company from assumptions, weak evidence and unanswered questions.",
  },
  {
    step: "03",
    icon: "route" as const,
    title: "Map the route in",
    body: "It traces the organisational path to the relevant buyer and verifies the access point you can actually use.",
  },
  {
    step: "04",
    icon: "check" as const,
    title: "Act when it is ready",
    body: "The opportunity becomes actionable only when the commercial case, route and contact authority are current.",
  },
];

const trust = [
  ["Evidence, not theatre", "Known, unknown, stale and contradicted information stay distinct."],
  ["Routes, not contact dumps", "You see why a person matters and the organisational path that makes them relevant."],
  ["Decisions, not lead scores", "Commercial readiness is earned through current authority, not a weighted score threshold."],
];

export default function Home() {
  return (
    <main className="mr-site">
      <header className="mr-site-nav">
        <div className="mr-site-nav__inner">
          <a className="mr-site-nav__brand" href="/" aria-label="MarketRoute home">
            <MarketRouteLogo />
            <span>by Truth Index Systems</span>
          </a>
          <nav className="mr-site-nav__links" aria-label="Primary navigation">
            <a href="#how-it-works">How it works</a>
            <a href="#intelligence">What you get</a>
            <a href="#genesis">Why trust it</a>
            <a href="/preview">Product example</a>
          </nav>
          <div className="mr-site-nav__actions">
            <a className="mr-site-nav__signin" href="/login">Sign in</a>
            <ButtonLink href="/discover" variant="primary" icon={<Icon name="arrow" size={15} />}>Find my routes</ButtonLink>
          </div>
        </div>
      </header>

      <section className="mr-site-hero">
        <div className="mr-site-shell mr-site-hero__grid">
          <div className="mr-site-hero__copy">
            <div className="mr-site-chip"><span /> B2B commercial intelligence</div>
            <h1>Know who to target.<br /><em>Know why. Know how to reach them.</em></h1>
            <p>
              MarketRoute researches your market and the companies inside it, verifies whether they are worth pursuing and maps evidence-backed routes to the right buyer — so your team can move from a market to an actionable opportunity without guessing.
            </p>
            <div className="mr-site-hero__actions">
              <ButtonLink href="/discover" variant="primary" icon={<Icon name="arrow" size={16} />}>Find my routes — free</ButtonLink>
              <ButtonLink href="#how-it-works" variant="secondary">How it works</ButtonLink>
            </div>
            <div className="mr-site-hero__microproof">
              <span><Icon name="check" size={14} /> Commercial reason</span>
              <span><Icon name="check" size={14} /> Route to buyer</span>
              <span><Icon name="check" size={14} /> Evidence behind both</span>
              <span><Icon name="check" size={14} /> No account required</span>
            </div>
          </div>

          <div className="mr-site-hero__product" aria-label="Example MarketRoute opportunity summary">
            <div className="mr-site-window">
              <div className="mr-site-window__topbar">
                <div><span className="mr-site-window__mark"><Icon name="opportunities" size={15} /></span><strong>Opportunity</strong></div>
                <span>Example view</span>
              </div>
              <div className="mr-site-window__company">
                <div>
                  <small>Northstar Industrial Systems</small>
                  <strong>Worth pursuing</strong>
                  <span>Industrial automation · Birmingham, UK</span>
                </div>
                <div className="mr-site-window__ready"><i /> Reachable now</div>
              </div>
              <div className="mr-site-window__facts">
                <article><span><Icon name="shield" size={16} /></span><div><small>Commercial case</small><strong>Confirmed</strong></div></article>
                <article><span><Icon name="route" size={16} /></span><div><small>Route in</small><strong>2 paths</strong></div></article>
                <article><span><Icon name="user" size={16} /></span><div><small>Buyer access</small><strong>Qualified</strong></div></article>
              </div>
              <div className="mr-site-window__route">
                <div className="mr-site-window__route-head"><span>Route to buyer</span><small>Current R5 + R6</small></div>
                <div className="mr-site-window__route-line">
                  <span><i /><strong>Company</strong><small>Northstar</small></span>
                  <b>→</b>
                  <span><i /><strong>Decision area</strong><small>Operations</small></span>
                  <b>→</b>
                  <span><i /><strong>Buyer</strong><small>VP Operations</small></span>
                  <b>→</b>
                  <span><i /><strong>Access</strong><small>Work email</small></span>
                </div>
              </div>
              <div className="mr-site-window__foot"><Icon name="research" size={14} /><span>Research strength 88 / 100</span><span>·</span><span>1 item to monitor</span></div>
            </div>
            <div className="mr-site-hero__note"><span>MarketRoute shows the decision first.</span> Evidence and Genesis reasoning remain available underneath.</div>
          </div>
        </div>
      </section>

      <section className="mr-site-proofbar">
        <div className="mr-site-shell mr-site-proofbar__inner">
          <div><strong>Company research</strong><span>Know the business properly</span></div>
          <div><strong>Commercial qualification</strong><span>Know whether it is worth pursuing</span></div>
          <div><strong>Relationship routes</strong><span>Know how the buyer connects</span></div>
          <div><strong>Contact readiness</strong><span>Know when you can act</span></div>
        </div>
      </section>

      <section className="mr-site-section mr-site-problem">
        <div className="mr-site-shell mr-site-problem__grid">
          <div className="mr-site-section-copy">
            <div className="mr-site-chip mr-site-chip--quiet"><span /> The problem</div>
            <h2>A lead tells you <em>who exists.</em><br />It rarely tells you what to do next.</h2>
            <p>Lists, enrichment tools and prospect scores can leave the hardest commercial questions unanswered: Why this company? Why now? Who actually matters? Is the route still current?</p>
          </div>
          <div className="mr-site-problem__compare">
            <article className="mr-site-problem__old">
              <span>Traditional lead record</span>
              <strong>Northstar Industrial Systems</strong>
              <ul>
                <li><i /> Company found</li>
                <li><i /> Contact found</li>
                <li><i /> Fit score: 82</li>
              </ul>
              <p>The important commercial reasoning is still yours to work out.</p>
            </article>
            <div className="mr-site-problem__arrow"><Icon name="arrow" size={20} /></div>
            <article className="mr-site-problem__new">
              <span>MarketRoute opportunity</span>
              <strong>Worth pursuing — reachable now</strong>
              <ul>
                <li><Icon name="check" size={14} /> Commercial reason evidenced</li>
                <li><Icon name="check" size={14} /> Buyer route proven</li>
                <li><Icon name="check" size={14} /> Contact channel qualified</li>
              </ul>
              <p>The answer, route and evidence arrive together.</p>
            </article>
          </div>
        </div>
      </section>

      <section className="mr-site-section mr-site-how" id="how-it-works">
        <div className="mr-site-shell">
          <div className="mr-site-section-head">
            <div><div className="mr-site-chip mr-site-chip--quiet"><span /> How MarketRoute works</div><h2>From a market to a route you can act on.</h2></div>
            <p>MarketRoute does not simply search for contacts. It builds the commercial case in order, keeping unknowns visible until the evidence is strong enough to support the next step.</p>
          </div>
          <div className="mr-site-process">
            {process.map((item) => (
              <article key={item.step}>
                <div className="mr-site-process__top"><span>{item.step}</span><i><Icon name={item.icon} size={20} /></i></div>
                <strong>{item.title}</strong>
                <p>{item.body}</p>
              </article>
            ))}
          </div>
        </div>
      </section>

      <section className="mr-site-section mr-site-intelligence" id="intelligence">
        <div className="mr-site-shell">
          <div className="mr-site-section-head mr-site-section-head--stacked">
            <div className="mr-site-chip mr-site-chip--quiet"><span /> What you get</div>
            <h2>One commercial view. Four questions answered.</h2>
            <p>Technical provenance stays available, but the product speaks commercial language first.</p>
          </div>

          <div className="mr-site-feature mr-site-feature--truth">
            <div className="mr-site-feature__copy">
              <span className="mr-site-feature__number">01</span>
              <div className="mr-site-chip mr-site-chip--soft"><Icon name="database" size={14} /> Company truth</div>
              <h3>How well do we actually know this company?</h3>
              <p>MarketRoute keeps coverage, freshness, evidence sufficiency and unresolved questions separate. Weak or stale evidence does not become artificial certainty.</p>
              <ul><li><Icon name="check" size={14}/> Evidence provenance</li><li><Icon name="check" size={14}/> Freshness and contradiction</li><li><Icon name="check" size={14}/> Explicit unknowns</li></ul>
            </div>
            <div className="mr-site-feature__visual mr-site-feature__visual--truth">
              <div className="mr-site-truth-card">
                <div><small>Research strength</small><strong>88</strong><span>/100</span></div>
                <em>Well supported</em>
                <div className="mr-site-truth-bar"><span /></div>
                <dl><div><dt>Coverage</dt><dd>92%</dd></div><div><dt>Evidence sufficiency</dt><dd>86%</dd></div><div><dt>Freshness</dt><dd>90%</dd></div><div><dt>Calibration</dt><dd>Uncalibrated</dd></div></dl>
              </div>
            </div>
          </div>

          <div className="mr-site-feature mr-site-feature--reverse">
            <div className="mr-site-feature__copy">
              <span className="mr-site-feature__number">02</span>
              <div className="mr-site-chip mr-site-chip--soft"><Icon name="shield" size={14} /> Commercial reality</div>
              <h3>Is there a real reason for you to pursue them?</h3>
              <p>MarketRoute tests the seller, target and required commercial conditions together. A company becomes a candidate because an admissible commercial reality exists — not because a score crossed a line.</p>
              <ul><li><Icon name="check" size={14}/> Seller context included</li><li><Icon name="check" size={14}/> Required conditions checked</li><li><Icon name="check" size={14}/> Research required when evidence is missing</li></ul>
            </div>
            <div className="mr-site-feature__visual">
              <div className="mr-site-decision-card">
                <div className="mr-site-decision-card__head"><span>Commercial decision</span><em><i /> Confirmed</em></div>
                <h4>Why this company is worth pursuing</h4>
                <div className="mr-site-decision-step"><b>R4</b><div><small>Commercial reality</small><strong>A current, evidence-backed reason to engage exists.</strong></div></div>
                <div className="mr-site-decision-step"><b>R5</b><div><small>Route authority</small><strong>Two independent structural routes are available.</strong></div></div>
                <div className="mr-site-decision-step"><b>R6</b><div><small>Contact authority</small><strong>A qualified work channel is current.</strong></div></div>
              </div>
            </div>
          </div>

          <div className="mr-site-feature">
            <div className="mr-site-feature__copy">
              <span className="mr-site-feature__number">03</span>
              <div className="mr-site-chip mr-site-chip--soft"><Icon name="route" size={14} /> Relationship route</div>
              <h3>How do we reach the person who matters?</h3>
              <p>The route is more than a contact record. MarketRoute shows the company, the decision-owning area, the person and the access point as a chain of evidenced relationships.</p>
              <ul><li><Icon name="check" size={14}/> Organisational path</li><li><Icon name="check" size={14}/> Current role support</li><li><Icon name="check" size={14}/> Independent route resilience</li></ul>
            </div>
            <div className="mr-site-feature__visual mr-site-feature__visual--route">
              <div className="mr-site-route-card">
                <div className="mr-site-route-card__head"><span>Route to buyer</span><em>2 paths available</em></div>
                <div className="mr-site-route-card__flow">
                  <article><i><Icon name="companies" size={17}/></i><small>Company</small><strong>Northstar</strong></article><b>→</b>
                  <article><i><Icon name="command" size={17}/></i><small>Decision area</small><strong>Operations</strong></article><b>→</b>
                  <article><i className="mr-site-route-person"><Icon name="user" size={17}/></i><small>Buyer</small><strong>VP Operations</strong></article><b>→</b>
                  <article><i className="mr-site-route-access"><Icon name="mail" size={17}/></i><small>Access</small><strong>Work email</strong></article>
                </div>
                <p><Icon name="shield" size={14}/> Each edge remains subject to freshness and evidence qualification.</p>
              </div>
            </div>
          </div>

          <div className="mr-site-feature mr-site-feature--reverse">
            <div className="mr-site-feature__copy">
              <span className="mr-site-feature__number">04</span>
              <div className="mr-site-chip mr-site-chip--soft"><Icon name="user" size={14} /> Contact readiness</div>
              <h3>Can your team actually act on this now?</h3>
              <p>A named person is not enough. MarketRoute keeps identity, employment, role and channel ownership independently qualified so stale or unsupported contact data fails closed.</p>
              <ul><li><Icon name="check" size={14}/> Current employment</li><li><Icon name="check" size={14}/> Relevant responsibility</li><li><Icon name="check" size={14}/> Qualified access point</li></ul>
            </div>
            <div className="mr-site-feature__visual">
              <div className="mr-site-contact-card">
                <div className="mr-site-contact-card__avatar">VO</div>
                <div className="mr-site-contact-card__identity"><small>Relevant buyer</small><strong>VP Operations</strong><span>Operations leadership</span></div>
                <div className="mr-site-contact-card__state"><i /> Current</div>
                <div className="mr-site-contact-card__checks"><span><Icon name="check" size={14}/> Employer supported</span><span><Icon name="check" size={14}/> Role current</span><span><Icon name="check" size={14}/> Work email qualified</span></div>
                <div className="mr-site-contact-card__footer"><span>Buyer access</span><strong>Ready to use</strong></div>
              </div>
            </div>
          </div>
        </div>
      </section>

      <section className="mr-site-example" id="example">
        <div className="mr-site-shell mr-site-example__grid">
          <div className="mr-site-example__copy">
            <div className="mr-site-chip mr-site-chip--dark"><span /> Product walkthrough</div>
            <h2>See exactly what your team gets after research.</h2>
            <p>Open the full example opportunity and follow the decision from commercial reality through the route, buyer access and remaining research questions.</p>
            <ButtonLink href="/preview" variant="primary" icon={<Icon name="arrow" size={16}/>}>Open the example opportunity</ButtonLink>
          </div>
          <div className="mr-site-example__result">
            <span>Example outcome</span>
            <strong>Worth pursuing — reachable now</strong>
            <div><p><b>Why</b> Commercial case confirmed</p><p><b>Who</b> VP Operations</p><p><b>How</b> Qualified work email</p></div>
          </div>
        </div>
      </section>

      <section className="mr-site-section mr-site-genesis" id="genesis">
        <div className="mr-site-shell mr-site-genesis__grid">
          <div className="mr-site-genesis__copy">
            <div className="mr-site-chip mr-site-chip--quiet"><span /> Built on Genesis T8</div>
            <h2>The product stays simple because the reasoning underneath is strict.</h2>
            <p>Genesis T8 is the intelligence architecture underneath MarketRoute. AI helps interpret language and research the market; beneath the commercial interface, the system qualifies commercial reality against evidence and current authority. Deterministic rules and lifecycle checks decide what the product is allowed to treat as commercially actionable.</p>
            <a href="#principles">See the principles <Icon name="arrow" size={14}/></a>
          </div>
          <div className="mr-site-genesis__principles" id="principles">
            {trust.map(([title, body], index) => <article key={title}><span>0{index + 1}</span><div><strong>{title}</strong><p>{body}</p></div></article>)}
          </div>
        </div>
      </section>

      <section className="mr-site-section mr-site-access">
        <div className="mr-site-shell">
          <div className="mr-site-access__card">
            <div>
              <div className="mr-site-chip mr-site-chip--soft"><Icon name="spark" size={14}/> Launch access</div>
              <h2>Tell MarketRoute what you sell. Watch it build the route.</h2>
              <p>Start with one free discovery run. MarketRoute understands your business, maps the relevant market and begins researching real organisations before you create an account.</p>
            </div>
            <div className="mr-site-access__steps"><span><b>1</b> Enter your business</span><i>→</i><span><b>2</b> Watch research progress</span><i>→</i><span><b>3</b> See routes emerge</span></div>
            <ButtonLink href="/discover" variant="primary" icon={<Icon name="arrow" size={16}/>}>Start free discovery</ButtonLink>
          </div>
        </div>
      </section>

      <section className="mr-site-final">
        <div className="mr-site-shell mr-site-final__inner">
          <div><span>MarketRoute</span><h2>Turn your market into a route to revenue.</h2><p>Know which companies are worth pursuing, why they matter and how to reach the right people.</p></div>
          <div className="mr-site-final__actions"><ButtonLink href="/discover" variant="primary" icon={<Icon name="arrow" size={16}/>}>Find my routes — free</ButtonLink><a href="/login">Already have an account? Sign in</a></div>
        </div>
      </section>

      <footer className="mr-site-footer">
        <div className="mr-site-shell mr-site-footer__inner">
          <div><MarketRouteLogo/><span>A Truth Index Systems product</span></div>
          <nav><a href="#how-it-works">How it works</a><a href="#intelligence">What you get</a><a href="#genesis">Genesis T8</a><a href="/preview">Product example</a><a href="/login">Sign in</a></nav>
          <span>MarketRoute V2</span>
        </div>
      </footer>
    </main>
  );
}
