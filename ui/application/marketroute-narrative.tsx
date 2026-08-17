import type { MarketRouteNarrative } from "@/application/conversation/contracts";
import { Icon } from "@/ui/icons";

export function MarketRouteNarrativeCard({narrative,eyebrow="MARKETROUTE"}:{narrative:MarketRouteNarrative;eyebrow?:string}){
  return <section className="mr-narrative-card">
    <div className="mr-narrative-card__mark"><span><Icon name="route" size={17}/></span><i/></div>
    <div className="mr-narrative-card__body"><span className="mr-narrative-card__eyebrow">{eyebrow}</span><h2>{narrative.headline}</h2><p className="mr-narrative-card__summary">{narrative.summary}</p>
      <div className="mr-narrative-card__columns"><div><small>Why it matters</small><p>{narrative.whyItMatters}</p></div><div><small>What I recommend</small><p>{narrative.recommendation}</p></div></div>
      {narrative.uncertainties.length>0&&<div className="mr-narrative-card__uncertainty"><Icon name="search" size={14}/><div><small>Still checking</small><p>{narrative.uncertainties[0]}</p></div></div>}
      <footer><strong>Next</strong><span>{narrative.nextAction}</span></footer>
    </div>
  </section>;
}
