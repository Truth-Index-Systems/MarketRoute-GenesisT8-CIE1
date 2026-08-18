import type { MarketRouteNarrative } from "@/application/conversation/contracts";
import { Icon } from "@/ui/icons";

export function MarketRouteNarrativeCard({narrative,eyebrow="MARKETROUTE"}:{narrative:MarketRouteNarrative;eyebrow?:string}){
  return <section className="mr-narrative-card mr-narrative-card--v2">
    <div className="mr-narrative-card__mark"><span><Icon name="spark" size={17}/></span><i/></div>
    <div className="mr-narrative-card__body"><div className="mr-narrative-card__eyebrow-row"><span className="mr-narrative-card__eyebrow">{eyebrow}</span><small>{narrative.generation==="AI"?"Based on your live market":"Live market update"}</small></div><h2>{narrative.headline}</h2><p className="mr-narrative-card__summary">{narrative.summary}</p>
      <div className="mr-narrative-card__columns"><div><small>Why this matters</small><p>{narrative.whyItMatters}</p></div><div><small>What to do next</small><p>{narrative.recommendation}</p></div></div>
      {narrative.known.length>0&&<div className="mr-narrative-card__known"><small>What is clear</small><div>{narrative.known.slice(0,3).map((item,index)=><span key={`${item}-${index}`}><Icon name="check" size={12}/>{item}</span>)}</div></div>}
      {narrative.uncertainties.length>0&&<div className="mr-narrative-card__uncertainty"><Icon name="search" size={14}/><div><small>Still checking</small><p>{narrative.uncertainties[0]}</p></div></div>}
      <footer><span className="mr-narrative-card__next-icon"><Icon name="arrow" size={13}/></span><strong>Next move</strong><span>{narrative.nextAction}</span></footer>
    </div>
  </section>;
}
