import { commercialAccessServiceFromEnvironment } from "@/application/commercial/service";
import { Icon,PublicPageShell } from "@/ui";

export default async function Pricing(){
  const plans=await commercialAccessServiceFromEnvironment().plans();
  return <PublicPageShell eyebrow="PRICING" title="Try the real product. Upgrade when it earns its place." intro="Your first eight opportunities are free and stay yours. Choose a paid plan when you want MarketRoute researching more markets, finding more opportunities and keeping them current.">
    <section className="mr-public-pricing">
      <article className="mr-public-pricing__discovery"><span>FREE DISCOVERY</span><h2>£0</h2><strong>See MarketRoute work on your market</strong><ul><li><Icon name="check" size={13}/> No account required to start</li><li><Icon name="check" size={13}/> First 8 opportunities are yours</li><li><Icon name="check" size={13}/> Real company research and buyer routes</li></ul><a className="mr-button mr-button--secondary" href="/discover">Find my opportunities</a></article>
      {plans.map(plan=>{const meta=plan.metadata??{},recommended=meta.recommended===true;return <article className={recommended?"is-recommended":""} key={plan.planCode}>{recommended&&<b>POPULAR</b>}<span>{plan.displayName.toUpperCase()}</span><h2>£{Math.round(plan.monthlyPriceGbp)}<small>/month</small></h2><strong>Keep MarketRoute working</strong><ul><li><Icon name="check" size={13}/>{plan.activeMarketLimit} active market{plan.activeMarketLimit===1?"":"s"}</li><li><Icon name="check" size={13}/>{String(meta.depthLabel??"Deeper company research")}</li><li><Icon name="check" size={13}/>{String(meta.monitoringLabel??"Ongoing opportunity checks")}</li><li><Icon name="check" size={13}/> Buyer, email, phone and direct contact routes</li><li><Icon name="check" size={13}/>{String(meta.capacityLabel??"More ongoing research")}</li></ul><a className={`mr-button ${recommended?"mr-button--primary":"mr-button--secondary"}`} href="/discover">Start free first</a></article>})}
    </section>
    <article><span>01</span><div><h2>Why start free?</h2><p>Because MarketRoute should prove it understands your business before asking you to pay. Your first eight opportunities stay available after you create an account.</p></div></article>
    <article><span>02</span><div><h2>What changes when I upgrade?</h2><p>MarketRoute can work more markets, search wider when strong opportunities are hard to find, research companies more deeply and keep checking the opportunities you care about.</p></div></article>
    <article><span>03</span><div><h2>Do I lose my research if I change plan?</h2><p>No. Plan changes control how much new work MarketRoute can do at once. Research and opportunities already built for your workspace stay intact.</p></div></article>
  </PublicPageShell>;
}
