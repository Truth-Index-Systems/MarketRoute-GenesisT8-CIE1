import { ButtonLink, Icon, MarketRouteLogo } from "@/ui";
import { commercialAccessServiceFromEnvironment } from "@/application/commercial/service";

const process = [
  {step:"01",icon:"spark" as const,title:"Tell us what you sell",body:"Give MarketRoute your business, offer and the market you want to win."},
  {step:"02",icon:"companies" as const,title:"We find the right companies",body:"MarketRoute searches the market and builds a focused list around your real offer."},
  {step:"03",icon:"research" as const,title:"We work out who is worth it",body:"Each company is researched until there is enough evidence to make a useful commercial call."},
  {step:"04",icon:"route" as const,title:"You get the route in",body:"See why the company matters, who to speak to and the best current way to reach them."},
];

const trust = [
  ["Useful before impressive", "MarketRoute is designed to give you a commercial answer, not drown you in research."],
  ["Evidence behind every answer", "You can always open the supporting research when you want to see why MarketRoute reached a conclusion."],
  ["It can say ‘not enough yet’", "Weak, stale or conflicting information stays visible instead of being turned into false certainty."],
];

export default async function Home() {
  const plans=await commercialAccessServiceFromEnvironment().plans();
  return (
    <main className="mr-site mr-site--launch">
      <header className="mr-site-nav">
        <div className="mr-site-nav__inner">
          <a className="mr-site-nav__brand" href="/" aria-label="MarketRoute home">
            <MarketRouteLogo />
            <span>by Truth Index Systems</span>
          </a>
          <nav className="mr-site-nav__links" aria-label="Primary navigation">
            <a href="#how-it-works">How it works</a>
            <a href="#intelligence">What you get</a>
            <a href="/preview">See the product</a>
            <a href="#pricing">Pricing</a>
          </nav>
          <div className="mr-site-nav__actions">
            <a className="mr-site-nav__signin" href="/login">Sign in</a>
            <ButtonLink href="/discover" variant="primary" icon={<Icon name="arrow" size={16} />}>Find my opportunities</ButtonLink>
          </div>
        </div>
      </header>

      <section className="mr-site-hero">
        <div className="mr-site-shell mr-site-hero__grid">
          <div className="mr-site-hero__copy">
            <div className="mr-site-chip"><span /> AI-powered B2B growth research</div>
            <h1>Know who to target.<br /><em>Know why. Know how to reach them.</em></h1>
            <p>
              MarketRoute researches your market, finds the companies worth your time and maps a real route to the right buyer — so you can move from “who should we sell to?” to action with confidence.
            </p>
            <div className="mr-site-hero__actions">
              <ButtonLink href="/discover" variant="primary" icon={<Icon name="arrow" size={17} />}>Find my first opportunities</ButtonLink>
              <ButtonLink href="/preview" variant="secondary">See an example</ButtonLink>
            </div>
            <div className="mr-site-hero__microproof">
              <span><Icon name="check" size={15} /> First 8 opportunities free</span>
              <span><Icon name="check" size={15} /> No account to start</span>
              <span><Icon name="check" size={15} /> Real company research</span>
              <span><Icon name="check" size={15} /> Buyer routes included</span>
            </div>
          </div>

          <div className="mr-site-hero__product" aria-label="Example MarketRoute opportunity summary">
            <div className="mr-site-window">
              <div className="mr-site-window__topbar">
                <div><span className="mr-site-window__mark"><Icon name="opportunities" size={16} /></span><strong>Opportunity</strong></div>
                <span>Live-style example</span>
              </div>
              <div className="mr-site-window__company">
                <div>
                  <small>Northstar Industrial Systems</small>
                  <strong>Strong opportunity</strong>
                  <span>Industrial automation · Birmingham, UK</span>
                </div>
                <div className="mr-site-window__ready"><i /> Ready to contact</div>
              </div>
              <div className="mr-site-window__facts">
                <article><span><Icon name="spark" size={17} /></span><div><small>Why it fits</small><strong>Clear commercial need</strong></div></article>
                <article><span><Icon name="route" size={17} /></span><div><small>Usable routes</small><strong>2 ways in</strong></div></article>
                <article><span><Icon name="user" size={17} /></span><div><small>Right person</small><strong>VP Operations</strong></div></article>
              </div>
              <div className="mr-site-window__route">
                <div className="mr-site-window__route-head"><span>Your route in</span><small>Checked and current</small></div>
                <div className="mr-site-window__route-line">
                  <span><i /><strong>Company</strong><small>Northstar</small></span>
                  <b>→</b>
                  <span><i /><strong>Team</strong><small>Operations</small></span>
                  <b>→</b>
                  <span><i /><strong>Buyer</strong><small>VP Operations</small></span>
                  <b>→</b>
                  <span><i /><strong>Reach them</strong><small>Work email</small></span>
                </div>
              </div>
              <div className="mr-site-window__foot"><Icon name="research" size={15} /><span>Research strength 88 / 100</span><span>·</span><span>Checked recently</span></div>
            </div>
            <div className="mr-site-hero__note"><span>The answer comes first.</span> Open the research underneath whenever you want the detail.</div>
          </div>
        </div>
      </section>

      <section className="mr-site-proofbar">
        <div className="mr-site-shell mr-site-proofbar__inner">
          <div><strong>Find the right companies</strong><span>Stop wasting time on weak-fit lists</span></div>
          <div><strong>Know why they matter</strong><span>See the commercial reason in plain English</span></div>
          <div><strong>Find the right buyer</strong><span>Understand who owns the decision</span></div>
          <div><strong>Get a route you can use</strong><span>Email, phone and direct paths when ready</span></div>
        </div>
      </section>

      <section className="mr-site-section mr-site-problem">
        <div className="mr-site-shell mr-site-problem__grid">
          <div className="mr-site-section-copy">
            <div className="mr-site-chip mr-site-chip--quiet"><span /> Why MarketRoute</div>
            <h2>A list gives you names.<br /><em>You still have to do the hard part.</em></h2>
            <p>Most prospecting tools tell you who exists. MarketRoute goes further: it works out which companies deserve your attention, why they matter, who owns the decision and how you can reach them.</p>
          </div>
          <div className="mr-site-problem__compare">
            <article className="mr-site-problem__old">
              <span>Typical lead list</span>
              <strong>Northstar Industrial Systems</strong>
              <ul>
                <li><i /> Company name</li>
                <li><i /> Contact record</li>
                <li><i /> Fit score: 82</li>
              </ul>
              <p>You still need to work out whether it is worth your time.</p>
            </article>
            <div className="mr-site-problem__arrow"><Icon name="arrow" size={21} /></div>
            <article className="mr-site-problem__new">
              <span>MarketRoute</span>
              <strong>Strong opportunity — ready to contact</strong>
              <ul>
                <li><Icon name="check" size={15} /> Why this company matters</li>
                <li><Icon name="check" size={15} /> Who to speak to</li>
                <li><Icon name="check" size={15} /> A current route in</li>
              </ul>
              <p>The research arrives as a decision you can actually use.</p>
            </article>
          </div>
        </div>
      </section>

      <section className="mr-site-section mr-site-how" id="how-it-works">
        <div className="mr-site-shell">
          <div className="mr-site-section-head">
            <div><div className="mr-site-chip mr-site-chip--quiet"><span /> How it works</div><h2>From “who should we sell to?” to a route in.</h2></div>
            <p>MarketRoute does the market research in the background and keeps the experience simple: give it the brief, then watch useful opportunities emerge.</p>
          </div>
          <div className="mr-site-process">
            {process.map((item) => (
              <article key={item.step}>
                <div className="mr-site-process__top"><span>{item.step}</span><i><Icon name={item.icon} size={21} /></i></div>
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
            <h2>Four answers your sales team can use immediately.</h2>
            <p>The complexity stays underneath. MarketRoute gives you the commercial answer first, with the research one click away.</p>
          </div>

          <div className="mr-site-feature mr-site-feature--truth">
            <div className="mr-site-feature__copy">
              <span className="mr-site-feature__number">01</span>
              <div className="mr-site-chip mr-site-chip--soft"><Icon name="database" size={14} /> Research strength</div>
              <h3>Do we know enough to trust this?</h3>
              <p>MarketRoute keeps checking how complete and current the research is. If something important is missing, it tells you instead of pretending to know.</p>
              <ul><li><Icon name="check" size={14}/> Sources behind the answer</li><li><Icon name="check" size={14}/> Freshness checks</li><li><Icon name="check" size={14}/> Clear unknowns</li></ul>
            </div>
            <div className="mr-site-feature__visual mr-site-feature__visual--truth">
              <div className="mr-site-truth-card">
                <div><small>Research strength</small><strong>88</strong><span>/100</span></div>
                <em>Strong research base</em>
                <div className="mr-site-truth-bar"><span /></div>
                <dl><div><dt>Coverage</dt><dd>92%</dd></div><div><dt>Support</dt><dd>86%</dd></div><div><dt>Freshness</dt><dd>90%</dd></div><div><dt>Open questions</dt><dd>1</dd></div></dl>
              </div>
            </div>
          </div>

          <div className="mr-site-feature mr-site-feature--reverse">
            <div className="mr-site-feature__copy">
              <span className="mr-site-feature__number">02</span>
              <div className="mr-site-chip mr-site-chip--soft"><Icon name="spark" size={14} /> Why it matters</div>
              <h3>Why is this company worth pursuing?</h3>
              <p>Instead of another generic fit score, MarketRoute explains the commercial reason this company belongs on your radar — in language you can use in a real sales conversation.</p>
              <ul><li><Icon name="check" size={14}/> Your offer considered</li><li><Icon name="check" size={14}/> Real market context</li><li><Icon name="check" size={14}/> Weak cases filtered out</li></ul>
            </div>
            <div className="mr-site-feature__visual">
              <div className="mr-site-decision-card">
                <div className="mr-site-decision-card__head"><span>Why pursue them?</span><em><i /> Strong case</em></div>
                <h4>A clear reason to start a conversation</h4>
                <div className="mr-site-decision-step"><b>01</b><div><small>Need</small><strong>There is a current problem your offer can solve.</strong></div></div>
                <div className="mr-site-decision-step"><b>02</b><div><small>Access</small><strong>Two credible routes into the buying team are available.</strong></div></div>
                <div className="mr-site-decision-step"><b>03</b><div><small>Buyer</small><strong>A relevant decision-maker can be reached now.</strong></div></div>
              </div>
            </div>
          </div>

          <div className="mr-site-feature">
            <div className="mr-site-feature__copy">
              <span className="mr-site-feature__number">03</span>
              <div className="mr-site-chip mr-site-chip--soft"><Icon name="route" size={14} /> Route to the buyer</div>
              <h3>Who should we speak to — and how do we get there?</h3>
              <p>MarketRoute connects the company, the team that owns the decision, the right person and the best current contact route into one simple path.</p>
              <ul><li><Icon name="check" size={14}/> Decision-owning team</li><li><Icon name="check" size={14}/> Relevant buyer</li><li><Icon name="check" size={14}/> More than one route when available</li></ul>
            </div>
            <div className="mr-site-feature__visual mr-site-feature__visual--route">
              <div className="mr-site-route-card">
                <div className="mr-site-route-card__head"><span>Your route in</span><em>2 paths available</em></div>
                <div className="mr-site-route-card__flow">
                  <article><i><Icon name="companies" size={17}/></i><small>Company</small><strong>Northstar</strong></article><b>→</b>
                  <article><i><Icon name="command" size={17}/></i><small>Team</small><strong>Operations</strong></article><b>→</b>
                  <article><i className="mr-site-route-person"><Icon name="user" size={17}/></i><small>Buyer</small><strong>VP Operations</strong></article><b>→</b>
                  <article><i className="mr-site-route-access"><Icon name="mail" size={17}/></i><small>Reach them</small><strong>Work email</strong></article>
                </div>
                <p><Icon name="shield" size={14}/> MarketRoute keeps checking the route so stale contact data does not quietly become your problem.</p>
              </div>
            </div>
          </div>

          <div className="mr-site-feature mr-site-feature--reverse">
            <div className="mr-site-feature__copy">
              <span className="mr-site-feature__number">04</span>
              <div className="mr-site-chip mr-site-chip--soft"><Icon name="user" size={14} /> Ready to act</div>
              <h3>Can we contact them now?</h3>
              <p>A person on a database is not enough. MarketRoute checks that the role still makes sense and that the contact route is usable before it tells you to act.</p>
              <ul><li><Icon name="check" size={14}/> Current role</li><li><Icon name="check" size={14}/> Relevant responsibility</li><li><Icon name="check" size={14}/> Usable contact route</li></ul>
            </div>
            <div className="mr-site-feature__visual">
              <div className="mr-site-contact-card">
                <div className="mr-site-contact-card__avatar">VO</div>
                <div className="mr-site-contact-card__identity"><small>Best person to contact</small><strong>VP Operations</strong><span>Operations leadership</span></div>
                <div className="mr-site-contact-card__state"><i /> Ready</div>
                <div className="mr-site-contact-card__checks"><span><Icon name="check" size={14}/> Company confirmed</span><span><Icon name="check" size={14}/> Role current</span><span><Icon name="check" size={14}/> Work email ready</span></div>
                <div className="mr-site-contact-card__footer"><span>Contact route</span><strong>Ready to use</strong></div>
              </div>
            </div>
          </div>
        </div>
      </section>

      <section className="mr-site-example" id="example">
        <div className="mr-site-shell mr-site-example__grid">
          <div className="mr-site-example__copy">
            <div className="mr-site-chip mr-site-chip--dark"><span /> See the product</div>
            <h2>See what a finished opportunity actually looks like.</h2>
            <p>Open the example and follow the journey from “this company matters” to the person and route your team can use.</p>
            <ButtonLink href="/preview" variant="primary" icon={<Icon name="arrow" size={16}/>}>Open the example</ButtonLink>
          </div>
          <div className="mr-site-example__result">
            <span>Example result</span>
            <strong>Strong opportunity — ready to contact</strong>
            <div><p><b>Why</b> Clear reason to engage</p><p><b>Who</b> VP Operations</p><p><b>How</b> Current work email</p></div>
          </div>
        </div>
      </section>

      <section className="mr-site-section mr-site-genesis" id="genesis">
        <div className="mr-site-shell mr-site-genesis__grid">
          <div className="mr-site-genesis__copy">
            <div className="mr-site-chip mr-site-chip--quiet"><span /> Why you can trust it</div>
            <h2>Simple on the surface. Serious underneath.</h2>
            <p>MarketRoute is powered by Genesis T8 and Truth Index research discipline. The technology stays mostly out of your way, but it gives the product an important ability: to separate what is known, what is uncertain and what still needs checking before you act.</p>
            <a href="#principles">See how we think <Icon name="arrow" size={14}/></a>
          </div>
          <div className="mr-site-genesis__principles" id="principles">
            {trust.map(([title, body], index) => <article key={title}><span>0{index + 1}</span><div><strong>{title}</strong><p>{body}</p></div></article>)}
          </div>
        </div>
      </section>

      <section className="mr-site-section mr-site-pricing" id="pricing">
        <div className="mr-site-shell">
          <div className="mr-site-section-head"><div><div className="mr-site-chip mr-site-chip--quiet"><span/> Pricing</div><h2>Try the real product first.</h2></div><p>Your first eight opportunities are free. If MarketRoute keeps finding more value, upgrade to unlock the rest and keep the research running.</p></div>
          <div className="mr-site-pricing__grid">
            <article className="mr-site-price-card mr-site-price-card--free"><span>FREE DISCOVERY</span><h3>£0</h3><p>One market. Eight real opportunities. No demo data.</p><ul><li><Icon name="check" size={14}/> No account to start</li><li><Icon name="check" size={14}/> Real company research</li><li><Icon name="check" size={14}/> Keep your first 8 opportunities</li></ul><ButtonLink href="/discover" variant="secondary">Start free</ButtonLink></article>
            {plans.map(plan=>{const recommended=(plan.metadata??{}).recommended===true;return <article className={`mr-site-price-card${recommended?" is-recommended":""}`} key={plan.planCode}>{recommended&&<b>POPULAR</b>}<span>{plan.displayName.toUpperCase()}</span><h3>£{Math.round(plan.monthlyPriceGbp)}<small>/mo</small></h3><p>{plan.activeMarketLimit===1?"For one focused market":`For up to ${plan.activeMarketLimit} active markets`}</p><ul><li><Icon name="check" size={14}/> Ongoing company research</li><li><Icon name="check" size={14}/> Opportunity monitoring</li><li><Icon name="check" size={14}/> Buyer and contact routes</li></ul><ButtonLink href="/discover" variant={recommended?"primary":"secondary"}>Start free first</ButtonLink></article>})}
          </div><div className="mr-site-pricing__foot"><a href="/pricing">Compare plans <Icon name="arrow" size={13}/></a><span>Monthly plans. No annual commitment at launch.</span></div>
        </div>
      </section>

      <section className="mr-site-section mr-site-access">
        <div className="mr-site-shell">
          <div className="mr-site-access__card">
            <div>
              <div className="mr-site-chip mr-site-chip--soft"><Icon name="spark" size={14}/> Start free</div>
              <h2>Give MarketRoute the brief. Let it do the digging.</h2>
              <p>Tell us what you sell and who you want to reach. MarketRoute will start researching the market before you even create an account.</p>
            </div>
            <div className="mr-site-access__steps"><span><b>1</b> Tell us what you sell</span><i>→</i><span><b>2</b> We research the market</span><i>→</i><span><b>3</b> Opportunities appear</span></div>
            <ButtonLink href="/discover" variant="primary" icon={<Icon name="arrow" size={17}/>}>Find my opportunities</ButtonLink>
          </div>
        </div>
      </section>

      <section className="mr-site-final">
        <div className="mr-site-shell mr-site-final__inner">
          <div><span>MarketRoute</span><h2>Stop searching for leads. Start seeing where to go next.</h2><p>Know which companies deserve your attention, who matters inside them and the route to start the conversation.</p></div>
          <div className="mr-site-final__actions"><ButtonLink href="/discover" variant="primary" icon={<Icon name="arrow" size={17}/>}>Find my first opportunities</ButtonLink><a href="/login">Already have an account? Sign in</a></div>
        </div>
      </section>

      <footer className="mr-site-footer">
        <div className="mr-site-shell mr-site-footer__inner">
          <div><MarketRouteLogo/><span>A Truth Index Systems product</span></div>
          <nav><a href="#how-it-works">How it works</a><a href="#pricing">Pricing</a><a href="/privacy">Privacy</a><a href="/terms">Terms</a><a href="/support">Support</a><a href="/login">Sign in</a></nav>
          <span>MarketRoute</span>
        </div>
      </footer>
    </main>
  );
}
