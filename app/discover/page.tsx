import { cookies } from "next/headers";
import { anonymousDiscoveryServiceFromEnvironment,ANONYMOUS_DISCOVERY_COOKIE } from "@/application/discovery/service";
import { AnonymousDiscoveryProgress,Icon,MarketRouteLogo } from "@/ui";

function errorMessage(code:string|null){const messages:Record<string,string>={MARKETROUTE_ANONYMOUS_IP_LIMIT:"Too many free discovery runs have been started from this network recently. Sign in if you already have a MarketRoute workspace.",MARKETROUTE_ANONYMOUS_WEBSITE_INVALID:"Enter a valid company website, for example https://example.com.",MARKETROUTE_ANONYMOUS_COMPANY_NAME_REQUIRED:"Add the name of the business MarketRoute should work for.",MARKETROUTE_ANONYMOUS_OFFERING_REQUIRED:"Describe what the business sells in a little more detail.",MARKETROUTE_ANONYMOUS_DISCOVERY_FAILED:"MarketRoute could not start this discovery. Please check the details and try again."};return code?messages[code]??messages.MARKETROUTE_ANONYMOUS_DISCOVERY_FAILED:null;}
export default async function Discover({searchParams}:{searchParams:Promise<Record<string,string|string[]|undefined>>}){
  const query=await searchParams;const secret=(await cookies()).get(ANONYMOUS_DISCOVERY_COOKIE)?.value;let discovery=null;
  if(secret){try{discovery=await anonymousDiscoveryServiceFromEnvironment().status(secret)}catch{discovery=null}}
  const error=errorMessage(typeof query.error==="string"?query.error:null);
  return <main className="mr-discovery-shell">
    <header className="mr-discovery-nav"><a href="/" aria-label="MarketRoute home"><MarketRouteLogo/></a><div><a href="/preview">Product example</a><a href="/login">Sign in</a></div></header>
    {discovery?<AnonymousDiscoveryProgress initial={discovery}/>:<div className="mr-discovery-start">
      <section className="mr-discovery-start__copy"><div className="mr-site-chip"><span/> Free MarketRoute discovery</div><h1>Tell me what you sell.<br/><em>I&apos;ll find the routes.</em></h1><p>MarketRoute will understand your business, map the market, research relevant organisations and begin finding evidence-backed routes to the right buyers.</p><div className="mr-discovery-start__proof"><span><Icon name="check" size={14}/> No account required</span><span><Icon name="check" size={14}/> One free discovery run</span><span><Icon name="check" size={14}/> Real research, not a demo</span></div></section>
      <section className="mr-discovery-start__form"><span>START YOUR DISCOVERY</span><h2>What should MarketRoute work on?</h2><p>Keep it simple. MarketRoute will structure the brief and research the rest.</p>{error&&<div className="mr-alert mr-alert--error"><Icon name="shield" size={18}/><span>{error}</span></div>}
        <form action="/api/discovery/start" method="post">
          <label><span>Company name</span><input name="companyName" required minLength={2} maxLength={160} autoComplete="organization" placeholder="Truth Index Systems"/></label>
          <label><span>Company website</span><input name="websiteUrl" required inputMode="url" autoComplete="url" placeholder="https://truthindexsystems.co.uk"/></label>
          <label><span>What do you sell?</span><textarea name="sellerOfferingText" required minLength={8} maxLength={2000} rows={4} placeholder="Bespoke AI and commercial intelligence systems for B2B organisations."/></label>
          <label><span>Who do you want to sell to? <small>Optional</small></span><textarea name="targetMarketText" maxLength={2000} rows={3} placeholder="UK logistics and supply-chain businesses — or leave this blank and let MarketRoute infer the market."/></label>
          <button className="mr-button mr-button--primary" type="submit">Build my MarketRoute <Icon name="arrow" size={17}/></button>
        </form><small>MarketRoute checks existing Genesis intelligence first and researches only what this business needs.</small>
      </section>
    </div>}
  </main>;
}
