import { AuthorityStack,ButtonLink,Icon,MarketRouteLogo,Panel,ResearchPressure,RoutePath,SectionHeading,StatusBadge,TruthGauge } from "@/ui";

const stages=[
  {stage:"01",name:"Why it fits",decision:"CONFIRMED",detail:"A clear, current reason to start a conversation",tone:"green" as const},
  {stage:"02",name:"Your route in",decision:"OPEN",detail:"Two credible ways into the buying team",tone:"blue" as const},
  {stage:"03",name:"Contact route",decision:"CURRENT",detail:"A relevant buyer has a current work contact route",tone:"green" as const},
];

export default function PublicPreview(){
  return <main className="mr-public-preview">
    <header className="mr-preview-nav"><a href="/" aria-label="MarketRoute home"><MarketRouteLogo/></a><a href="/login" className="mr-preview-signin">Sign in</a></header>

    <section className="mr-preview-hero">
      <div><div className="mr-kicker"><span/> PRODUCT EXAMPLE</div><h1>See what matters.<br/><em>Skip the noise.</em></h1><p>This is what MarketRoute looks like after the research: a clear view of whether the company is worth your time, why it matters and how to reach the right person.</p></div>
      <StatusBadge label="Illustrative example" tone="slate"/>
    </section>

    <section className="mr-preview-workspace">
      <div className="mr-preview-workspace__bar">
        <div><span className="mr-preview-workspace__mark"><Icon name="opportunities" size={15}/></span><strong>Opportunity view</strong><span>Northstar Industrial Systems</span></div>
        <span>Example data</span>
      </div>

      <section className="mr-preview-company">
        <div className="mr-preview-company__identity"><span>Example company</span><h2>Northstar Industrial Systems</h2><p>Industrial automation · Birmingham, UK</p></div>
        <div className="mr-preview-company__verdict"><span>MarketRoute view</span><strong>Strong opportunity — ready to contact</strong><p>Why it fits confirmed · Buyer route available · Current contact route</p></div>
      </section>

      <section className="mr-preview-outcomes">
        <div><span className="mr-preview-outcome__icon mr-preview-outcome__icon--green"><Icon name="shield" size={17}/></span><div><span>Why it fits</span><strong>Confirmed</strong><small>Checked recently</small></div></div>
        <div><span className="mr-preview-outcome__icon mr-preview-outcome__icon--blue"><Icon name="route" size={17}/></span><div><span>Your route in</span><strong>2 paths</strong><small>2 ways in</small></div></div>
        <div><span className="mr-preview-outcome__icon mr-preview-outcome__icon--violet"><Icon name="user" size={17}/></span><div><span>Contact route</span><strong>Ready</strong><small>Current route</small></div></div>
        <div><span className="mr-preview-outcome__icon mr-preview-outcome__icon--blue"><Icon name="research" size={17}/></span><div><span>Research strength</span><strong>88 / 100</strong><small>Research quality</small></div></div>
      </section>

      <section className="mr-preview-grid">
        <Panel emphasis="blue" className="mr-preview-card mr-preview-card--decision"><SectionHeading eyebrow="Why it matters" title="Why this company deserves attention" description="MarketRoute looks for a real commercial reason, a route to the buying team and a contact path you can use."/><AuthorityStack stages={stages}/></Panel>
        <Panel className="mr-preview-card mr-preview-card--truth"><SectionHeading eyebrow="Research strength" title="How much can we trust this?" description="MarketRoute shows how complete and current the research is, and keeps important unknowns visible."/><TruthGauge value={88} state="Well supported"/><div className="mr-preview-truth-list"><div><span>Coverage</span><strong>92%</strong></div><div><span>Support</span><strong>86%</strong></div><div><span>Freshness</span><strong>90%</strong></div><div><span>Open questions</span><strong>1 remaining</strong></div></div></Panel>
        <Panel className="mr-preview-route-panel mr-preview-card mr-preview-card--route"><SectionHeading eyebrow="Your route in" title="Who should we speak to, and how?" description="See the company, the team that owns the decision, the right person and the best current way to reach them."/><RoutePath nodes={[{label:"Northstar Industrial Systems",meta:"Target company",kind:"company"},{label:"Operations leadership",meta:"Buying team",kind:"unit"},{label:"VP Operations",meta:"Current role",kind:"person"},{label:"Work email",meta:"Ready access point",kind:"channel"}]} caption="A second route is available if the primary contact changes."/></Panel>
        <Panel className="mr-preview-card mr-preview-card--research"><SectionHeading eyebrow="Still checking" title="What is MarketRoute still checking?" description="See what is already clear, what MarketRoute is monitoring and what still needs a little more work."/><ResearchPressure items={[{label:"Secondary procurement contact",detail:"Useful extra context; it does not block outreach",state:"watch"},{label:"Primary contact role",detail:"Current and supported",state:"clear"},{label:"Work email",detail:"Current and supported",state:"clear"}]}/></Panel>
      </section>
    </section>

    <section className="mr-preview-value">
      <div className="mr-preview-value__copy"><span>What MarketRoute changes</span><h2>From company research to a conversation your team can start.</h2><p>MarketRoute brings the reason, the buyer and the route together in one place.</p></div>
      <div className="mr-preview-value__proof">
        <div><span>01</span><strong>Know why</strong><small>See the clear commercial reason to pursue the company.</small></div>
        <div><span>02</span><strong>Know who</strong><small>Identify the right buyer and the route to them.</small></div>
        <div><span>03</span><strong>Know when to act</strong><small>Move when the research and contact route are ready.</small></div>
      </div>
      <div className="mr-preview-value__actions"><ButtonLink href="/discover" variant="primary" icon={<Icon name="arrow" size={16}/>}>Build this for my market</ButtonLink><ButtonLink href="/" variant="ghost">Back to overview</ButtonLink></div>
    </section>

    <footer className="mr-preview-footer"><span>MarketRoute · by Truth Index Systems</span><span>Example data shown for product demonstration</span></footer>
  </main>;
}
