import { Icon } from "@/ui/icons";
import Link from "next/link";
import type { ProductPipelineStage } from "@/application/product-experience/pipeline";

const icons={UNDERSTAND:"spark",MAP:"route",DISCOVER:"companies",RESEARCH:"research",EVALUATE:"opportunities",ROUTE:"route",READY:"check"} as const;
export function ProductPipeline({stages,title="Your MarketRoute",compact=false}:{stages:ProductPipelineStage[];title?:string;compact?:boolean}){
  const active=stages.find(s=>s.status==="ACTIVE"||s.status==="ATTENTION")??stages.at(-1);
  return <section className={`mr-product-pipeline${compact?" mr-product-pipeline--compact":""}`}>
    <header><div><span>LIVE PROGRESS</span><h2>{title}</h2><p>{active?.status==="ATTENTION"?"One step needs attention. Everything already completed is saved.":active?.status==="ACTIVE"?`${active.label} is what MarketRoute is working on now. Progress is saved automatically.`:"This market is ready for action."}</p></div><div className={`mr-product-pipeline__now is-${(active?.status??"WAITING").toLowerCase()}`}><i/><span><small>NOW</small><strong>{active?.label??"Ready"}</strong></span></div></header>
    <ol>{stages.map((stage,index)=><li className={`is-${stage.status.toLowerCase()}`} key={stage.key}><Link href={stage.href} prefetch><div className="mr-product-pipeline__rail"><span>{stage.status==="COMPLETE"?<Icon name="check" size={12}/>:String(index+1).padStart(2,"0")}</span><i/></div><div className="mr-product-pipeline__stage"><div><span>{stage.label}</span><Icon name={icons[stage.key]} size={15}/></div><strong>{stage.value}</strong><p>{stage.detail}</p></div></Link></li>)}</ol>
  </section>;
}
