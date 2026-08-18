import Link from "next/link";
import { resolveCampaignId } from "@/app/app/_lib/data";
import { workspaceSessionOrRedirect } from "@/app/app/_lib/session";
import { applicationReadServiceFromEnvironment } from "@/application/read-model/service";
import { commercialAccessServiceFromEnvironment } from "@/application/commercial/service";
import { asObjectArray,campaignListItem,companyProfile,statusTone } from "@/application/read-model/presentation";
import { CampaignSwitcher,commercialVerdict,EmptyState,humanStatus,Icon,IntelligenceTable,LockedOpportunityFeed,PageHeader,Panel,routeSummary,StatusBadge } from "@/ui";

export default async function Opportunities({searchParams}:{searchParams:Promise<Record<string,string|string[]|undefined>>}){
  const query=await searchParams;
  const {workspace}=await workspaceSessionOrRedirect();
  const read=applicationReadServiceFromEnvironment();const commercial=commercialAccessServiceFromEnvironment();
  const [cc,access,plans]=await Promise.all([read.commandCentre({organisationId:workspace.organisationId}),read.commercialAccess({organisationId:workspace.organisationId}),commercial.plans()]);
  const campaigns=asObjectArray(cc.campaigns).map(campaignListItem);
  const campaignId=resolveCampaignId(cc,typeof query.campaign==="string"?query.campaign:null);
  if(!campaignId)return <div><PageHeader eyebrow="OPPORTUNITIES" title="Which companies are" accent="worth pursuing?" description="MarketRoute turns research into an opportunity only when a current commercial case and route can be represented."/><Panel><EmptyState icon="opportunities" title="No opportunities yet" body="MarketRoute is still preparing or researching your first market. Opportunities appear only after the evidence and commercial route support them."/></Panel></div>;
  const index=await read.opportunityIndex({organisationId:workspace.organisationId,campaignId,limit:200});
  const profiles=asObjectArray(index.opportunities).map(companyProfile);
  const locked=access.campaignId===campaignId?access.lockedOpportunities:[];
  return <div>
    {query.billing==="active"&&<div className="mr-alert mr-alert--success"><Icon name="check" size={16}/><span>Your subscription is active. The opportunities MarketRoute had waiting are now unlocked.</span></div>}
    <PageHeader eyebrow="OPPORTUNITIES" title="The companies" accent="worth your attention." description={access.mode==="DISCOVERY_FREE"&&access.lockedCount>0?`${profiles.length} opportunities are unlocked and ${access.lockedCount} more are ready when you upgrade.`:"MarketRoute only surfaces an opportunity when the current evidence supports a real commercial case."} actions={<CampaignSwitcher campaigns={campaigns.map(c=>({campaignId:c.campaignId,name:c.name,workflowState:c.workflowState}))} current={campaignId} action="/app/opportunities"/>}/>
    <Panel>{profiles.length===0?<EmptyState icon="opportunities" title="No qualified opportunities yet" body="No company has yet earned an opportunity record in this campaign."/>:<IntelligenceTable head={["Company","MarketRoute view","Readiness","Reachable now","Route coverage","Revalidate"]}>{profiles.map(p=><tr key={p.companyId}><td><Link href={`/app/opportunities/${campaignId}/${p.companyId}`} prefetch><strong>{p.companyName}</strong><small>{p.canonicalDomain??"No domain"}</small></Link></td><td><StatusBadge compact label={commercialVerdict(p.disposition,p.executableNow)} title={p.disposition} tone={statusTone(p.disposition)}/></td><td><span className="mr-table-primary">{p.executableNow?"Ready":humanStatus(p.workflowState,"Researching")}</span></td><td><StatusBadge compact label={p.executableNow?"Yes":"Not yet"} tone={p.executableNow?"green":"slate"}/></td><td>{routeSummary(p.authorisedRoutes,p.structuralRoutes)}</td><td>{p.nextRevalidationAt?new Date(p.nextRevalidationAt).toLocaleString("en-GB"):"—"}</td></tr>)}</IntelligenceTable>}</Panel>
    {access.mode==="DISCOVERY_FREE"&&<LockedOpportunityFeed items={locked} totalLocked={access.lockedCount} plans={plans}/>} 
  </div>;
}
