import Link from "next/link";
import { workspaceSessionOrRedirect } from "@/app/app/_lib/session";
import { commercialAccessServiceFromEnvironment } from "@/application/commercial/service";
import { CampaignCreationForm,Icon,PageHeader } from "@/ui";

function campaignCreationError(code:string|null){
  if(!code)return null;
  const messages:Record<string,string>={
    MARKETROUTE_CAMPAIGN_NAME_REQUIRED:"Give the market a name between 3 and 120 characters.",
    MARKETROUTE_SETUP_OFFERING_REQUIRED:"Describe what your business currently sells so MarketRoute can verify it against your website.",
    MARKETROUTE_SETUP_OBJECTIVE_REQUIRED:"Tell MarketRoute what outcome you want.",
    MARKETROUTE_SETUP_TARGET_REQUIRED:"Describe the market or companies you want MarketRoute to research.",
    MARKETROUTE_SETUP_CONSTRAINT_CHOICE_REQUIRED:"Choose whether this market has non-negotiable limits.",
    MARKETROUTE_SETUP_CONSTRAINT_CONFLICT:"Choose ‘Add hard limits’ when limits are written, or remove the written limits.",
    MARKETROUTE_SETUP_CONSTRAINT_DECLARATION_REQUIRED:"Describe your hard limits or remove the hard-limits option.",
    MARKETROUTE_CAMPAIGN_ADMIN_REQUIRED:"Only workspace owners and admins can add a market.",
    MARKETROUTE_CAMPAIGN_PLAN_REQUIRED:"Your market brief is saved. Choose a MarketRoute plan before starting another market.",
    MARKETROUTE_CAMPAIGN_LIMIT_REACHED:"Your market brief is saved. Upgrade to add another active market, or archive one you no longer need live.",
    MARKETROUTE_CAMPAIGN_CREATION_ALREADY_PROCESSING:"MarketRoute is already preparing another market. This brief is saved on your device.",
    MARKETROUTE_SETUP_SELLER_NOT_FOUND:"MarketRoute could not find the active seller business for this workspace."
  };
  return messages[code]??"MarketRoute could not start the market. Check the brief and try again.";
}

export default async function NewCampaign({searchParams}:{searchParams:Promise<Record<string,string|string[]|undefined>>}){
  const query=await searchParams;
  const {workspace,activation}=await workspaceSessionOrRedirect();
  const commercial=commercialAccessServiceFromEnvironment();
  const [capacity,plans]=await Promise.all([commercial.campaignCapacity(workspace.organisationId),commercial.plans()]);
  const raw=typeof query.error==="string"?decodeURIComponent(query.error):null;
  const error=campaignCreationError(raw);
  const canManage=["OWNER","ADMIN"].includes(workspace.role);
  const processing=["PENDING","RUNNING"].includes(activation.status);
  const initialPaywallOpen=raw==="MARKETROUTE_CAMPAIGN_PLAN_REQUIRED"||raw==="MARKETROUTE_CAMPAIGN_LIMIT_REACHED";

  if(!canManage)return <div><PageHeader eyebrow="ADD MARKET" title="Adding a market" accent="needs an owner or admin." description="You can still view every market in this workspace." actions={<Link className="mr-button mr-button--secondary" href="/app/campaigns">Back to markets</Link>}/><div className="mr-alert"><Icon name="shield" size={18}/><span>Ask a workspace owner or admin to add the next market.</span></div></div>;

  return <div className="mr-campaign-new-page">
    <PageHeader eyebrow="ADD MARKET" title="Put MarketRoute to work on" accent="another market." description="Give MarketRoute a fresh brief. It will reuse useful research, fill the gaps and keep this market separate from the others." actions={<Link className="mr-button mr-button--secondary" href="/app/campaigns">Cancel</Link>}/>
    {error&&<div className="mr-alert mr-alert--error mr-campaign-new-error"><Icon name="warning" size={18}/><span>{error}</span></div>}
    <CampaignCreationForm capacity={capacity} plans={plans} processing={processing} initialPaywallOpen={initialPaywallOpen}/>
  </div>;
}
