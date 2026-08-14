import type { ReactNode } from "react";
export function PageHeader({eyebrow,title,accent,description,actions}:{eyebrow:string;title:string;accent?:string;description:string;actions?:ReactNode}){
  return <section className="mr-live-page-header"><div className="mr-live-page-header__copy"><div className="mr-kicker"><span/>{eyebrow}</div><h1>{title}{accent&&<> <em>{accent}</em></>}</h1><p>{description}</p></div>{actions&&<div className="mr-live-page-header__actions">{actions}</div>}</section>
}
