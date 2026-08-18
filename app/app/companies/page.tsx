import Link from "next/link";
import { commandCentre,resolveCampaignId } from "@/app/app/_lib/data";
import { workspaceSessionOrRedirect } from "@/app/app/_lib/session";
import { applicationReadServiceFromEnvironment } from "@/application/read-model/service";
import { asObjectArray,campaignListItem,companyProfile,statusTone } from "@/application/read-model/presentation";
import { CampaignSwitcher,EmptyState,humanStatus,IntelligenceTable,PageHeader,Panel,researchPressureLabel,StatusBadge,truthStrength } from "@/ui";

export default async function Companies({searchParams}:{searchParams:Promise<Record<string,string|string[]|undefined>>}){
  const query=await searchParams;
  const {workspace}=await workspaceSessionOrRedirect();
  const cc=await commandCentre(workspace.organisationId);
  const campaigns=asObjectArray(cc.campaigns).map(campaignListItem);
  const campaignId=resolveCampaignId(cc,typeof query.campaign==="string"?query.campaign:null);
  const options=campaigns.map(c=>({campaignId:c.campaignId,name:c.name,workflowState:c.workflowState}));
  if(!campaignId)return <div><PageHeader eyebrow="COMPANIES" title="What do we know" accent="about the market?" description="Every company is kept inside an explicit campaign so research, commercial fit and route intelligence always have context."/><Panel><EmptyState icon="companies" title="No campaign available" body="Create or activate a campaign before companies can enter MarketRoute research."/></Panel></div>;
  const index=await applicationReadServiceFromEnvironment().companyIndex({organisationId:workspace.organisationId,campaignId,limit:200});
  const profiles=asObjectArray(index.companies).map(companyProfile);
  return <div>
    <PageHeader eyebrow="COMPANIES" title="The market," accent="as MarketRoute understands it." description="See which organisations are known, which are becoming commercially relevant and where MarketRoute still needs stronger evidence or a clearer route in." actions={<CampaignSwitcher campaigns={options} current={campaignId} action="/app/companies"/>}/>
    <Panel>{profiles.length===0?<EmptyState icon="companies" title="No companies in this campaign" body="MarketRoute has not yet added companies to this campaign scope."/>:<IntelligenceTable head={["Company","MarketRoute view","Research need","Research quality","Commercial case","Route in","Buyer access"]}>{profiles.map(p=>{const truthIndex=Math.round(Number(p.truth.truthIndex??0));return <tr key={p.companyId}><td><Link href={`/app/opportunities/${campaignId}/${p.companyId}`} prefetch><strong>{p.companyName}</strong><small>{p.canonicalDomain??"No canonical domain"}</small></Link></td><td><StatusBadge compact label={humanStatus(p.disposition)} title={p.disposition} tone={statusTone(p.disposition)}/></td><td><span className="mr-table-primary">{researchPressureLabel(p.researchPressure)}</span></td><td><strong className="mr-table-number">{truthIndex}</strong><small>{truthStrength(truthIndex)}</small></td><td><span className="mr-table-state" title={p.commercialReality}>{humanStatus(p.commercialReality)}</span></td><td><span className="mr-table-state" title={p.routeAuthority}>{humanStatus(p.routeAuthority)}</span></td><td><span className="mr-table-state" title={p.contactAuthority}>{humanStatus(p.contactAuthority)}</span></td></tr>})}</IntelligenceTable>}<div className="mr-table-footer">Showing {index.returnedCount} of {index.totalCount} companies in this campaign.</div></Panel>
  </div>
}
