import { redirect } from "next/navigation";
import { commandCentre } from "@/app/app/_lib/data";
import { workspaceSessionOrRedirect } from "@/app/app/_lib/session";
import { asObjectArray } from "@/application/read-model/presentation";
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
    MARKETROUTE_LIVE_CAMPAIGN_ALREADY_EXISTS:"This workspace already has a live campaign. Pause or manage it from the campaigns page.",
    MARKETROUTE_CAMPAIGN_CREATION_ALREADY_PROCESSING:"MarketRoute is already preparing a campaign for this workspace.",
    MARKETROUTE_SETUP_SELLER_NOT_FOUND:"MarketRoute could not find the active seller business for this workspace."
  };
  return messages[code]??"MarketRoute could not start the campaign. Check the brief and try again.";
}

export default async function NewCampaign({searchParams}:{searchParams:Promise<Record<string,string|string[]|undefined>>}){
  const query=await searchParams;
  const {workspace,activation}=await workspaceSessionOrRedirect();
  if(!["OWNER","ADMIN"].includes(workspace.role))redirect("/app/campaigns?actionError=MARKETROUTE_CAMPAIGN_ADMIN_REQUIRED");
  if(["PENDING","RUNNING","FAILED"].includes(activation.status))redirect("/app/campaigns");
  const model=await commandCentre(workspace.organisationId);
  if(asObjectArray(model.campaigns).length>0)redirect("/app/campaigns?actionError=MARKETROUTE_LIVE_CAMPAIGN_ALREADY_EXISTS");
  const raw=typeof query.error==="string"?decodeURIComponent(query.error):null;
  const error=campaignCreationError(raw);

  return <div>
    <PageHeader eyebrow="NEW CAMPAIGN" title="Start a fresh" accent="market brief." description="The archived campaign stays in audit history. This creates a separate campaign with new research scope, budget and commercial context." actions={<a className="mr-button mr-button--secondary" href="/app/campaigns">Cancel</a>}/>
    <Panel className="mr-campaign-create">
      <SectionHeading eyebrow="Campaign brief" title="What should MarketRoute pursue next?" description="Genesis checks its existing intelligence bank first and uses fresh discovery only when the bank cannot supply enough candidates."/>
      {error&&<div className="mr-alert mr-alert--error"><Icon name="shield" size={18}/><span>{error}</span></div>}
      <CampaignCreationForm/>
    </Panel>
  </div>;
}
