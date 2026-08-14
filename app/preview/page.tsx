import { AuthorityStack,ButtonLink,Icon,MarketRouteLogo,Panel,ResearchPressure,RoutePath,SectionHeading,StatusBadge,TruthGauge } from "@/ui";

const stages=[
  {stage:"R4",name:"Commercial reality",decision:"COMMERCIAL_CANDIDATE",detail:"A current, evidence-backed reason to engage exists",tone:"green" as const},
  {stage:"R5",name:"Route authority",decision:"OPEN",detail:"Two independent structural routes into the company",tone:"blue" as const},
  {stage:"R6",name:"Contact authority",decision:"CURRENT",detail:"A relevant operational buyer has a qualified work channel",tone:"green" as const},
];

export default function PublicPreview(){
  return <main className="mr-public-preview">
    <header className="mr-preview-nav"><a href="/" aria-label="MarketRoute home"><MarketRouteLogo/></a><a href="/login" className="mr-preview-signin">Sign in</a></header>

    <section className="mr-preview-hero">
      <div><div className="mr-kicker"><span/> PRODUCT WALKTHROUGH · EXAMPLE DATA</div><h1>See the decision,<br/><em>not the machinery.</em></h1><p>This example shows what MarketRoute gives a commercial team after research: whether a company is worth pursuing, how well that conclusion is supported, and the route to the right person.</p></div>
      <StatusBadge label="Illustrative example" tone="slate"/>
    </section>

    <section className="mr-preview-company">
      <div className="mr-preview-company__identity"><span>Example company</span><h2>Northstar Industrial Systems</h2><p>Industrial automation · Birmingham, UK</p></div>
      <div className="mr-preview-company__verdict"><span>MarketRoute verdict</span><strong>Worth pursuing — reachable now</strong><p>Commercial case confirmed · Buyer route available · Current contact channel</p></div>
    </section>

    <section className="mr-preview-outcomes">
      <div><span>Commercial case</span><strong>Confirmed</strong><small>Current R4</small></div>
      <div><span>Route in</span><strong>2 paths</strong><small>Current R5</small></div>
      <div><span>Buyer access</span><strong>Qualified</strong><small>Current R6</small></div>
      <div><span>Research strength</span><strong>88 / 100</strong><small>Truth Index</small></div>
    </section>

    <section className="mr-preview-grid">
      <Panel emphasis="blue"><SectionHeading eyebrow="Commercial decision · R4 → R6" title="Why this company is worth pursuing" description="MarketRoute requires a current commercial reason, a proven organisational route and a qualified access point. No single score creates the opportunity."/><AuthorityStack stages={stages}/></Panel>
      <Panel><SectionHeading eyebrow="Research quality · Truth Index" title="How strong is the research?" description="Evidence readiness is separate from commercial authority. Unknowns stay unknown rather than becoming artificial confidence."/><TruthGauge value={88} state="Well supported"/><div className="mr-preview-truth-list"><div><span>Coverage</span><strong>92%</strong></div><div><span>Evidence sufficiency</span><strong>86%</strong></div><div><span>Freshness</span><strong>90%</strong></div><div><span>Calibration</span><strong>Uncalibrated</strong></div></div></Panel>
      <Panel className="mr-preview-route-panel"><SectionHeading eyebrow="Route to buyer · R5 + R6" title="How do we reach the right person?" description="The route shows the company, the decision-owning area, the person and the qualified access point in one readable chain."/><RoutePath nodes={[{label:"Northstar Industrial Systems",meta:"Target company",kind:"company"},{label:"Operations leadership",meta:"Decision-owning area",kind:"unit"},{label:"VP Operations",meta:"Current role supported",kind:"person"},{label:"Work email",meta:"Qualified access point",kind:"channel"}]} caption="A second independent structural route remains available if the primary contact changes."/></Panel>
      <Panel><SectionHeading eyebrow="Open questions · Genesis research" title="What still needs validating?" description="Research pressure stays visible so a user can see what is decision-blocking, what should be monitored and what is already resolved."/><ResearchPressure items={[{label:"Secondary procurement relationship",detail:"Useful enrichment; it does not block the current route",state:"watch"},{label:"Primary contact employment",detail:"Current and independently supported",state:"clear"},{label:"Work email ownership",detail:"Current and supported",state:"clear"}]}/></Panel>
    </section>

    <section className="mr-preview-value">
      <div className="mr-preview-value__copy"><span>What MarketRoute changes</span><h2>From researched company to a route your team can act on.</h2><p>MarketRoute joins the commercial decision, the evidence behind it and the route to the right buyer in one traceable workflow.</p></div>
      <div className="mr-preview-value__proof">
        <div><span>01</span><strong>Know why</strong><small>See the evidence-backed commercial reason to pursue the company.</small></div>
        <div><span>02</span><strong>Know who</strong><small>Identify the relevant buyer and the organisational path to them.</small></div>
        <div><span>03</span><strong>Know what is ready</strong><small>Act only when the current research and access route support it.</small></div>
      </div>
      <div className="mr-preview-value__actions"><ButtonLink href="/signup" variant="primary" icon={<Icon name="arrow" size={16}/>}>Build this for my market</ButtonLink><ButtonLink href="/" variant="ghost">Back to overview</ButtonLink></div>
    </section>

    <footer className="mr-preview-footer"><span>MarketRoute V2 · Genesis T8</span><span>Example data shown for product demonstration</span></footer>
  </main>;
}
