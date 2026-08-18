import { workspaceSessionOrRedirect } from "@/app/app/_lib/session";
import { commercialAccessServiceFromEnvironment } from "@/application/commercial/service";
import { billingServiceFromEnvironment } from "@/application/billing/service";
import { Icon,PageHeader,PlanChooser } from "@/ui";

function billingMessage(code:string){
  if(code.includes("PRICE_CONFIGURATION"))return "Billing is not configured correctly yet. Please contact MarketRoute support.";
  if(code.includes("OWNER_REQUIRED"))return "Only the workspace owner can change billing.";
  if(code.includes("PLAN_CAMPAIGN_LIMIT_TOO_LOW"))return "That plan cannot hold all of your current campaigns. Choose a plan with a higher active-market allowance.";
  if(code.includes("ALREADY_SUBSCRIBED")||code.includes("EXISTING_SUBSCRIPTION"))return "This workspace already has a Stripe subscription. Use Manage billing instead.";
  return "The billing action could not be completed. Your current access has not changed.";
}

export default async function Plans({searchParams}:{searchParams:Promise<Record<string,string|string[]|undefined>>}){
  const query=await searchParams;const campaignLimit=query.reason==="campaign-limit";const billingError=typeof query.billingError==="string"?query.billingError:null;const cancelled=query.billing==="cancelled";
  const {workspace}=await workspaceSessionOrRedirect();const commercial=commercialAccessServiceFromEnvironment();const billing=billingServiceFromEnvironment();
  const [access,plans,context,capacity]=await Promise.all([commercial.access(workspace.organisationId),commercial.plans(),billing.context(workspace.organisationId),commercial.campaignCapacity(workspace.organisationId)]);
  const hasManagedSubscription=Boolean(context.externalCustomerId&&context.externalSubscriptionId&&!['CANCELLED','EXPIRED'].includes(String(context.entitlementStatus??"")));
  const billingAttention=context.entitlementStatus==="PAST_DUE";
  const legacyFull=access.mode==="FULL"&&access.planCode==="LEGACY_FULL"&&!hasManagedSubscription;
  const eligibleLegacyPlans=legacyFull?plans.filter(plan=>plan.activeMarketLimit>=Math.max(1,capacity.activeMarketCount)):plans;
  const showCurrent=access.mode==="PAID"||access.mode==="FULL"||hasManagedSubscription;
  const showChooser=!showCurrent||legacyFull;
  return <div><PageHeader eyebrow="PLAN & BILLING" title="Keep MarketRoute" accent="working your market." description="Choose your research capacity, or manage an existing subscription. Billing changes product access only; commercial intelligence remains evidence-led and demand-driven."/>
    {campaignLimit&&<div className="mr-alert"><Icon name="campaigns" size={16}/><span>Your current campaign allowance is full. Upgrade the subscription here, then return to Add campaign — your brief stays saved.</span></div>}
    {cancelled&&<div className="mr-alert"><Icon name="arrow" size={16}/><span>Checkout was cancelled. Your current access has not changed.</span></div>}
    {billingError&&<div className="mr-alert mr-alert--danger"><Icon name="warning" size={16}/><span>{billingMessage(billingError)}</span></div>}
    {billingAttention&&<div className="mr-alert mr-alert--danger"><Icon name="warning" size={16}/><span>Your subscription needs attention. MarketRoute has protected paid intelligence until Stripe confirms active billing again.</span></div>}
    {showCurrent&&<div className="mr-plan-current"><Icon name="shield" size={18}/><div><span>CURRENT ACCESS</span><strong>{access.planName??context.planCode??"MarketRoute subscription"}</strong><p>{context.cancelAtPeriodEnd&&context.currentPeriodEnd?`Your subscription remains active until ${new Date(context.currentPeriodEnd).toLocaleDateString("en-GB")}.`:billingAttention?"Update your payment method or subscription in the secure billing portal.":legacyFull?"This workspace was grandfathered during the billing migration. You can keep this access or move onto a standard MarketRoute subscription below.":"Your paid opportunities are unlocked and research capacity follows this plan."}</p>{context.externalCustomerId&&<form action="/api/billing/portal" method="post"><button className="mr-button mr-button--secondary" type="submit">Manage billing <Icon name="arrow" size={14}/></button></form>}</div></div>}
    {showChooser&&<div className="mr-plans-page__chooser"><PlanChooser plans={eligibleLegacyPlans} lockedCount={access.lockedCount} title={legacyFull?"Move onto a MarketRoute plan":"Keep MarketRoute working for you"}/>{legacyFull&&<p className="mr-plans-page__legacy-note">Your grandfathered access stays active unless you complete checkout. Moving to a standard subscription replaces the legacy entitlement with that plan.</p>}</div>}
  </div>;
}
