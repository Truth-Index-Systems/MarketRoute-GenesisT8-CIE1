import { redirect } from "next/navigation";
import { workspaceSessionOrRedirect } from "@/app/app/_lib/session";
import { billingServiceFromEnvironment } from "@/application/billing/service";
import { Icon,PageHeader } from "@/ui";

export default async function BillingSuccess({searchParams}:{searchParams:Promise<Record<string,string|string[]|undefined>>}){
  const query=await searchParams;const sessionId=typeof query.session_id==="string"?query.session_id:"";const {workspace}=await workspaceSessionOrRedirect();if(!sessionId)redirect("/app/plans?billingError=MARKETROUTE_BILLING_CHECKOUT_ID_MISSING");
  try{const access=await billingServiceFromEnvironment().reconcileCheckout(sessionId,workspace.organisationId);if(access.mode==="PAID"||access.mode==="FULL")redirect("/app/opportunities?billing=active");}
  catch(error){const code=error instanceof Error?error.message:"MARKETROUTE_BILLING_RECONCILE_FAILED";return <div><PageHeader eyebrow="BILLING" title="Payment received." accent="Access is syncing." description="Stripe has returned you to MarketRoute. We are verifying the subscription before unlocking commercial intelligence."/><div className="mr-plan-current"><Icon name="clock" size={18}/><div><span>VERIFYING SUBSCRIPTION</span><strong>Your opportunities are still protected.</strong><p>{code.includes("PENDING")?"The subscription is still being confirmed. Refresh shortly or return to your plan page.":"MarketRoute could not verify the subscription yet. Your payment state will also be reconciled by the signed Stripe webhook."}</p><a className="mr-button mr-button--primary" href="/app/plans">Return to plan & billing</a></div></div></div>;}
  return null;
}
