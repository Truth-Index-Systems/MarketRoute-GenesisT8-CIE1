import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { sessionServiceFromEnvironment } from "@/application/session/service";
import { ACCESS_COOKIE,ORG_COOKIE } from "@/app/app/_lib/session";
import { MarketRouteLogo,Icon } from "@/ui";

function message(code:string|null){
  if(!code)return null;
  const map:Record<string,string>={
    MARKETROUTE_SETUP_OFFERING_REQUIRED:"Describe what your business currently sells so MarketRoute can verify it against your website.",
    MARKETROUTE_SETUP_OBJECTIVE_REQUIRED:"Tell MarketRoute what commercial outcome you want to pursue.",
    MARKETROUTE_SETUP_TARGET_REQUIRED:"Describe the market or companies you want MarketRoute to research.",
    MARKETROUTE_SETUP_CONSTRAINT_CHOICE_REQUIRED:"Choose whether the campaign has hard commercial limits.",
    MARKETROUTE_SETUP_CONSTRAINT_CONFLICT:"Choose ‘I have hard limits’ when limits are written, or remove the written limits before choosing none.",
    MARKETROUTE_SETUP_CONSTRAINT_DECLARATION_REQUIRED:"Describe your hard limits or choose that you have none at this stage.",
    MARKETROUTE_HARD_CONSTRAINTS_NOT_CANONICALLY_REPRESENTED:"MarketRoute could not safely translate those hard limits. Make them more explicit (for example country, industry, company size or business model).",
    MARKETROUTE_SELLER_OFFERING_UNRESOLVED:"MarketRoute could not verify a clear offering. Describe what you currently sell in plain English and try again.",
  };
  return map[code]??"MarketRoute needs a little more information before it can start your first market.";
}

export default async function Setup({searchParams}:{searchParams:Promise<Record<string,string|string[]|undefined>>}){
  const query=await searchParams;
  const jar=await cookies();
  const access=jar.get(ACCESS_COOKIE)?.value;
  if(!access)redirect("/login?next=/setup");
  const service=sessionServiceFromEnvironment();
  let session;
  try{session=await service.authenticate(access);}catch{redirect("/login?next=/setup");}
  if(session.memberships.length===0)redirect("/onboarding");
  const workspace=service.selectWorkspace(session,jar.get(ORG_COOKIE)?.value);
  const status=await service.activationStatus(access,workspace.organisationId);
  if(!["NOT_SUBMITTED","NEEDS_INPUT"].includes(status.status))redirect("/app");
  const raw=typeof query.error==="string"?decodeURIComponent(query.error):status.lastErrorCode;
  const error=message(raw);
  return <main className="mr-login">
    <section className="mr-login__context">
      <a href="/" aria-label="MarketRoute home"><MarketRouteLogo/></a>
      <div><span>Commercial brief</span><h1>Tell MarketRoute what to go and find.</h1><p>This is the only commercial context Genesis needs before it can prepare your first research campaign.</p></div>
      <footer>Final setup step · research begins automatically</footer>
    </section>
    <section className="mr-login__panel">
      <div className="mr-kicker"><span/> Your market</div>
      <h2>Set the first research brief</h2>
      <p>Keep it plain English. MarketRoute structures your declaration, freshly analyses your website, then verifies companies independently.</p>
      {error&&<div className="mr-alert mr-alert--error"><Icon name="shield" size={18}/><span>{error}</span></div>}
      <form action="/api/session/setup" method="post" className="mr-login__form">
        <label><span>What does your business currently sell?</span><textarea name="sellerOfferingText" required minLength={8} rows={3} placeholder="Bespoke software engineering and commercial intelligence systems for B2B organisations."/><small className="mr-field-help">This is a first-party declaration. MarketRoute checks it against your website instead of guessing from search visibility alone.</small></label>
        <label><span>What are you trying to achieve?</span><textarea name="objectiveText" required rows={3} placeholder="Win new B2B contracts."/><small className="mr-field-help">Your commercial objective becomes seller context, not an opportunity score.</small></label>
        <label><span>Which market should MarketRoute research?</span><textarea name="targetMarketText" required rows={3} placeholder="UK logistics and supply-chain organisations."/><small className="mr-field-help">Genesis checks its existing intelligence bank first, then uses fresh discovery only when the bank cannot supply enough candidates.</small></label>
        <fieldset className="mr-constraint-choice">
          <legend>Does this campaign have hard limits?</legend>
          <label className="mr-check-row"><input type="radio" name="constraintMode" value="DESCRIBED" required/><span>I have hard commercial limits and have described them below.</span></label>
          <label className="mr-check-row"><input type="radio" name="constraintMode" value="NONE" required/><span>I have no hard commercial restrictions beyond the brief above.</span></label>
        </fieldset>
        <label><span>Hard limits</span><textarea name="hardConstraintsText" rows={2} placeholder="For example: UK only; small organisations; B2B only."/><small className="mr-field-help">Complete this only when “I have hard limits” is selected. Hard limits remain fail-closed.</small></label>
        <button className="mr-button mr-button--primary" type="submit">Start preparing my market <Icon name="arrow" size={18}/></button>
      </form>
      <small>Genesis researches candidate companies in the background. Nothing receives commercial authority until the evidence supports it.</small>
    </section>
  </main>;
}
