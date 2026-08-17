import { workspaceSessionOrRedirect } from "@/app/app/_lib/session";
import { commercialAccessServiceFromEnvironment } from "@/application/commercial/service";
import { Icon,PageHeader,PlanChooser } from "@/ui";

export default async function Plans({searchParams}:{searchParams:Promise<Record<string,string|string[]|undefined>>}){
  const query=await searchParams;const selected=typeof query.plan==="string"?query.plan:null;
  const {workspace}=await workspaceSessionOrRedirect();const service=commercialAccessServiceFromEnvironment();const [access,plans]=await Promise.all([service.access(workspace.organisationId),service.plans()]);
  return <div><PageHeader eyebrow="PLANS" title="Keep MarketRoute" accent="working your market." description="Your plan controls product access and research capacity. The intelligence engine remains evidence-led and demand-driven."/>
    {selected&&<div className="mr-alert mr-alert--success"><Icon name="check" size={16}/><span>{selected} selected. The secure checkout connection lands in the billing build; no charge has been made.</span></div>}
    {access.mode==="PAID"||access.mode==="FULL"?<div className="mr-plan-current"><Icon name="shield" size={18}/><div><span>CURRENT ACCESS</span><strong>{access.planName??"Full access"}</strong><p>Your workspace currently has full opportunity access.</p></div></div>:<PlanChooser plans={plans} lockedCount={access.lockedCount}/>}</div>;
}
