import { redirect } from "next/navigation";
import { founderSessionIsValid } from "@/application/founder/auth";
import { MarketRouteLogo } from "@/ui/brand/marketroute-logo";

export const dynamic="force-dynamic";
export default async function FounderLogin({searchParams}:{searchParams:Promise<{error?:string}>}){
  if(await founderSessionIsValid())redirect("/dashboard");const query=await searchParams;
  return <main className="mr-founder-login"><section className="mr-founder-login__card"><div className="mr-founder-login__brand"><MarketRouteLogo/><span>Founder operations</span></div><div className="mr-founder-login__copy"><span>PRIVATE CONSOLE</span><h1>See whether MarketRoute is actually working.</h1><p>Live system health, data volume, research throughput, authority progression and AI spend. This surface is not available to customer accounts.</p></div>{query.error&&<div className="mr-founder-login__error">Password not recognised.</div>}<form method="post" action="/api/founder/login"><label htmlFor="founder-password">Founder password</label><input id="founder-password" name="password" type="password" autoComplete="current-password" required autoFocus/><button type="submit">Open founder dashboard</button></form></section></main>;
}
