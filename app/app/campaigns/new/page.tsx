import Link from "next/link";
import { workspaceSessionOrRedirect } from "@/app/app/_lib/session";
import { commercialAccessServiceFromEnvironment } from "@/application/commercial/service";
import { CampaignCreationForm,Icon,PageHeader,Panel,SectionHeading } from "@/ui";

function campaignCreationError(code:string|null){
  if(!code)return null;
  const messages:Record<string,string>={
    MARKETROUTE_CAMPAIGN_NAME_REQUIRED:"Give the campaign a name between 3 and 120 characters.",
    MARKETROUTE_SETUP_OFFERING_REQUIRED:"Describe what your business currently sells so MarketRoute can verify it against your website.",
    MARKETROUTE_SETUP_OBJECTIVE_REQUIRED:"Tell MarketRoute what commercial outcome you want to pursue.",
    MARKETROUTE_SETUP_TARGET_REQUIRED:"Describe the market or companies you want MarketRoute to research.",
    MARKETROUTE_SETUP_CONSTRAINT_CHOICE_REQUIRED:"Choose whether the campaign has hard commercial limits.",
    MARKETROUTE_SETUP_CONSTRAINT_CONFLICT:"Choose ‘I have hard limits’ when limits are written, or remove the written limits before choosing none.",
    MARKETROUTE_SETUP_CONSTRAINT_DECLARATION_REQUIRED:"Describe your hard limits or choose that you have none at this stage.",
    MARKETROUTE_CAMPAIGN_ADMIN_REQUIRED:"Only workspace owners and admins can create a campaign.",
    MARKETROUTE_CAMPAIGN_PLAN_REQUIRED:"Your campaign brief is saved. Choose a MarketRoute plan before starting an additional campaign.",
    MARKETROUTE_CAMPAIGN_LIMIT_REACHED:"Your campaign brief is saved. Upgrade your plan to add another active market, or archive one you no longer need live.",
    MARKETROUTE_CAMPAIGN_CREATION_ALREADY_PROCESSING:"MarketRoute is already preparing another campaign. This brief is saved on your device.",
    MARKETROUTE_SETUP_SELLER_NOT_FOUND:"MarketRoute could not find the active seller business for this workspace."
  };
  return messages[code]??"MarketRoute could not start the campaign. Check the brief and try again.";
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

  if(!canManage)return <div><PageHeader eyebrow="ADD CAMPAIGN" title="Campaign creation" accent="needs an owner or admin." description="You can still view every market in this workspace." actions={<Link className="mr-button mr-button--secondary" href="/app/campaigns">Back to campaigns</Link>}/><Panel><div className="mr-alert"><Icon name="shield" size={18}/><span>Ask a workspace owner or admin to configure the next campaign.</span></div></Panel></div>;

  return <div>
    <PageHeader eyebrow="ADD CAMPAIGN" title="Configure the next" accent="market brief." description="Every campaign starts here. MarketRoute never creates a new market from an old campaign without a fresh brief." actions={<Link className="mr-button mr-button--secondary" href="/app/campaigns">Cancel</Link>}/>
    <Panel className="mr-campaign-create">
      <SectionHeading eyebrow="Campaign brief" title="What should MarketRoute pursue next?" description="Genesis checks its existing intelligence bank first and uses fresh discovery only when the bank cannot supply enough candidates. Plan capacity is checked when you start the configured brief."/>
      {error&&<div className="mr-alert mr-alert--error"><Icon name="warning" size={18}/><span>{error}</span></div>}
      <CampaignCreationForm capacity={capacity} plans={plans} processing={processing} initialPaywallOpen={initialPaywallOpen}/>
    </Panel>
  </div>;
}
