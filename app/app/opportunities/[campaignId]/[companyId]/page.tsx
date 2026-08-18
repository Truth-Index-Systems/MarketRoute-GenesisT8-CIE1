import { workspaceSessionOrRedirect } from "@/app/app/_lib/session";
import { notFound,redirect } from "next/navigation";
import { applicationReadServiceFromEnvironment } from "@/application/read-model/service";
import { commercialAccessServiceFromEnvironment } from "@/application/commercial/service";
import { asObject,asObjectArray,booleanValue,companyProfile,formatDateTime,percent,shortFingerprint,statusTone,text } from "@/application/read-model/presentation";
import type { RouteNodeView } from "@/ui/intelligence/route-path";
import { AskMarketRoute,AssistedEngagementPanel,AuthorityStack,commercialVerdict,ContactRouteCard,EmptyState,humanStatus,Icon,LockedOpportunityDetail,MarketRouteNarrativeCard,PageHeader,Panel,ProvenanceDrawer,ProvenanceTrail,ResearchPressure,routeSummary,RoutePath,SectionHeading,StatusBadge,TruthGauge,truthStrength } from "@/ui";
import { marketRouteConversationServiceFromEnvironment } from "@/application/conversation/service";
import { contactRoutePresentation } from "@/application/opportunities/contact-route-presentation";

function routeNodes(value:unknown,revealContact:boolean):RouteNodeView[]{
  return asObjectArray(value).map((node)=>{
    const kind=text(node.kind,"ORGANISATIONAL_UNIT");
    const label=!revealContact&&kind==="PERSON"?"Named contact under verification":!revealContact&&kind==="ACCESS_POINT"?"Contact route under verification":text(node.label,"Unnamed node");
    return {label,meta:text(node.meta,""),kind:kind==="COMPANY"?"company":kind==="PERSON"?"person":kind==="ACCESS_POINT"?"channel":"unit"};
  });
}

export default async function OpportunityWorkspace({params,searchParams}:{params:Promise<{campaignId:string;companyId:string}>;searchParams:Promise<Record<string,string|string[]|undefined>>}){
  const {campaignId,companyId}=await params;
  const query=await searchParams;
  const {workspace}=await workspaceSessionOrRedirect();
  const commercial=commercialAccessServiceFromEnvironment();
  const [commercialAccess,plans]=await Promise.all([commercial.access(workspace.organisationId),commercial.plans()]);
  if(commercialAccess.mode==="DISCOVERY_FREE"&&!commercial.canReadCompany(commercialAccess,campaignId,companyId)){const locked=commercial.lockedCompany(commercialAccess,campaignId,companyId);if(locked)return <LockedOpportunityDetail item={locked} plans={plans} totalLocked={commercialAccess.lockedCount}/>;notFound();}
  if(commercialAccess.mode==="UNENTITLED")redirect("/app/plans");
  const service=applicationReadServiceFromEnvironment();
  const canMutate=workspace.role!=="VIEWER";
  const [model,routes,claimIndex]=await Promise.all([
    service.company({organisationId:workspace.organisationId,campaignId,companyId}),
    service.routeDisplay({organisationId:workspace.organisationId,campaignId,companyId}),
    service.provenanceClaimIndex({organisationId:workspace.organisationId,campaignId,companyId})
  ]);

  const profile=companyProfile(asObject(model.profile));
  const truth=asObject(model.truth),authority=asObject(model.authority),r4=asObject(authority.r4),r5=asObject(authority.r5),r6=asObject(authority.r6),workflow=asObject(model.workflow),research=asObject(model.research),engagement=asObject(model.engagement),claims=asObjectArray(claimIndex.claims),paths=asObjectArray(routes.paths);
  const authorisedPath=paths.find((path)=>booleanValue(path.authorised)&&typeof path.pathFingerprint==="string")??null;
  const opportunityId=typeof workflow.opportunityId==="string"?workflow.opportunityId:null;
  const selectedClaim=typeof query.claim==="string"?query.claim:null;
  const provenance=selectedClaim?await service.claimProvenance({organisationId:workspace.organisationId,campaignId,companyId,claimSnapshotId:selectedClaim}).catch(()=>null):null;
  const returnHref=`/app/opportunities/${campaignId}/${companyId}`;
  const actionError=typeof query.actionError==="string"?decodeURIComponent(query.actionError):null;
  const truthIndex=Math.round(percent(truth.truthIndex));
  const contactRoutes=contactRoutePresentation(routes);
  const narrative=await marketRouteConversationServiceFromEnvironment().opportunity(model,routes);

  const stages=[
    {stage:"R4",name:"Commercial reality",decision:text(r4.decision,"NO CURRENT R4"),detail:humanStatus(text(r4.decision,"NO_CURRENT_R4")),tone:statusTone(text(r4.decision,"UNKNOWN"))},
    {stage:"R5",name:"Route authority",decision:text(r5.decision,"NO CURRENT R5"),detail:`${Number(r5.distinctAccessPointCount??0)} structural access point(s) currently represented`,tone:statusTone(text(r5.decision,"UNKNOWN"))},
    {stage:"R6",name:"Contact authority",decision:text(r6.decision,"NO CURRENT R6"),detail:`${Number(r6.distinctAuthorisedAccessPointCount??0)} qualified access point(s) currently authorised`,tone:statusTone(text(r6.decision,"UNKNOWN"))}
  ];
  const gaps=asObjectArray(research.candidates).slice(0,6).map((g)=>({label:`${humanStatus(text(g.layer))}: ${humanStatus(text(g.action))}`,detail:humanStatus(text(g.reasonCode)),state:(text(g.tier)==="DECISION_BLOCKER"?"blocking":text(g.tier)==="ENRICHMENT"?"clear":"watch") as "blocking"|"watch"|"clear"}));
  const truthDimensions:Array<{label:string;value:unknown}>=[{label:"Coverage",value:truth.currentCoverage},{label:"Evidence sufficiency",value:truth.evidenceSufficiency},{label:"Freshness",value:truth.freshnessCoverage},{label:"Coherence",value:truth.coherence}];
  const verdict=commercialVerdict(profile.disposition,profile.executableNow);

  return <div>
    <PageHeader eyebrow="OPPORTUNITY" title={profile.companyName} description={profile.canonicalDomain??"Company website not confirmed yet"} actions={<StatusBadge label={profile.executableNow?"Ready to contact":"Not ready to contact"} tone={profile.executableNow?"green":"slate"}/>}/>
    {actionError&&<div className="mr-alert mr-alert--error"><Icon name="shield" size={16}/><span>{actionError}</span></div>}

    <MarketRouteNarrativeCard narrative={narrative} eyebrow="MARKETROUTE VIEW"/>
    <AskMarketRoute campaignId={campaignId} companyId={companyId} opportunityId={opportunityId} canDirect={canMutate} returnTo={returnHref}/>

    <section className="mr-ready-routes">
      <div className="mr-ready-routes__head"><div><span>READY TO USE</span><h2>{contactRoutes.ready.length>0?`${contactRoutes.ready.length} contact route${contactRoutes.ready.length===1?"":"s"} available`:"I'm still validating the route in"}</h2><p>{contactRoutes.ready.length>0?"Every route below has been checked and is ready to use. Open the contact details, or dig into the research if you want to see why.":"MarketRoute has found a possible way in, but is still checking it before showing it as ready."}</p></div>{contactRoutes.ready.length>0&&<StatusBadge label="Ready to contact" tone="green"/>}</div>
      {contactRoutes.ready.length>0?<div className="mr-ready-routes__grid">{contactRoutes.ready.map((route,index)=><ContactRouteCard key={route.key} route={route} returnHref={returnHref} companyWebsiteHref={contactRoutes.companyWebsiteHref} index={index}/>)}</div>:<EmptyState icon="route" title="No ready contact route yet" body="MarketRoute is still checking the best way in. Email, phone and direct links will appear as soon as a contact route is ready."/>}
      {contactRoutes.researching.length>0&&<div className="mr-ready-routes__researching"><Icon name="search" size={14}/><span>{contactRoutes.researching.length} additional route{contactRoutes.researching.length===1?" is":"s are"} still being verified.</span></div>}
    </section>

    <section className="mr-opportunity-verdict">
      <div className="mr-opportunity-verdict__copy"><span>MarketRoute view</span><h2>{verdict}</h2><p>{profile.executableNow?"There is a strong reason to pursue this company, the right buyer is clear and a usable contact route is ready.":"MarketRoute is still checking the reason, buyer or contact route before recommending action."}</p></div>
      <dl className="mr-opportunity-verdict__facts">
        <div><dt>Why it matters</dt><dd>{profile.executableNow?"Supported":"Still qualifying"}</dd><small>Reason to pursue</small></div>
        <div><dt>Contact route</dt><dd>{routeSummary(profile.authorisedRoutes,profile.structuralRoutes)}</dd><small>Path to the buyer</small></div>
        <div><dt>Right person</dt><dd>{profile.authorisedRoutes>0?"Ready":"Still verifying"}</dd><small>Buyer and contact route</small></div>
        <div><dt>Research strength</dt><dd>{truthStrength(truthIndex)}</dd><small>{truthIndex}/100 research quality</small></div>
      </dl>
    </section>


    <section className="mr-dashboard-grid mr-dashboard-grid--secondary">
      <Panel><SectionHeading eyebrow="STILL CHECKING" title="What still needs to be known?" description="These are the remaining questions MarketRoute is using to decide whether the opportunity should change."/>{gaps.length?<ResearchPressure items={gaps}/>:<EmptyState icon="check" title="Nothing important left to check" body="MarketRoute has no important open questions for this opportunity right now."/>}</Panel>

      <Panel><SectionHeading eyebrow="READINESS" title={profile.executableNow?"This opportunity is ready to contact":"This opportunity still needs more checking"} description={profile.executableNow?"The reason to pursue, buyer and contact route are all ready. You can act without waiting for another approval step.":"The opportunity moves to ready automatically when MarketRoute has enough current research and a usable route."}/><ProvenanceTrail items={[{label:"Current state",value:profile.executableNow?"Ready":humanStatus(text(workflow.state,"Researching"))},{label:"Reason to pursue",value:profile.authorityReady?"Ready":"Still checking"},{label:"Outreach can be prepared",value:model.actions.canGenerateEngagement?"Yes":"Not yet"},{label:"Ready to act",value:model.actions.canExecute?"Yes":"Not yet"}]}/>{!canMutate&&<div className="mr-readonly-note"><Icon name="shield" size={15}/><span>Viewer access is read-only.</span></div>}<div className="mr-readonly-note"><Icon name="shield" size={15}/><span>MarketRoute decides when the research is strong enough. You stay in control of the message you choose to send.</span></div></Panel>

      <AssistedEngagementPanel engagement={engagement} opportunityId={opportunityId} pathFingerprint={authorisedPath?text(authorisedPath.pathFingerprint):null} returnHref={returnHref} canMutate={canMutate} paidAccess={commercialAccess.mode==="PAID"||commercialAccess.mode==="FULL"}/>
    </section>

    <details className="mr-advanced-intelligence">
      <summary><span><Icon name="database" size={16}/><strong>Research details</strong><small>See the deeper checks and source trail behind this opportunity</small></span><Icon name="chevron" size={16}/></summary>
      <div className="mr-advanced-intelligence__body">
        <section className="mr-dashboard-grid mr-dashboard-grid--primary">
          <Panel emphasis="blue"><SectionHeading eyebrow="AUTHORITY CHAIN · ADVANCED" title="How did MarketRoute reach the commercial decision?" description="The engine keeps commercial reality, route authority and contact authority separate so one score can never mask a missing layer."/><AuthorityStack stages={stages}/><div className="mr-authority-meta"><div><span>Authority lineage</span><strong>{shortFingerprint(authority.envelopeFingerprint)}</strong></div><div><span>Next revalidation</span><strong>{formatDateTime(profile.nextRevalidationAt)}</strong></div></div></Panel>
          <Panel><SectionHeading eyebrow="TRUTH INDEX · ADVANCED" title="How strong is the research?" description="Coverage, evidence sufficiency, freshness and coherence remain separately inspectable underneath the customer-facing explanation. Research strength is epistemic quality, not a probability of purchase."/><TruthGauge value={truthIndex} state={humanStatus(text(truth.entityState,"NO CURRENT TRUTH"))}/><div className="mr-truth-dimensions">{truthDimensions.map(({label,value})=><div className="mr-truth-dimension" key={label}><div><span>{label}</span><strong>{Math.round(percent(value))}%</strong></div><div className="mr-progress"><span style={{width:`${percent(value)}%`}}/></div></div>)}</div><div className="mr-calibration-note"><Icon name="database" size={15}/><div><span>Probability calibration</span><strong>{humanStatus(text(truth.probabilityState,"UNCALIBRATED"))}</strong></div></div></Panel>
        </section>
        <Panel className="mr-route-live-panel"><SectionHeading eyebrow="ROUTE STRUCTURE · ADVANCED" title="How was each route established?" description="This is the structural path behind the ready contact panels above. Every path remains structural or Truth-qualified, and this view does not create or rank contact authority."/>{paths.length===0?<EmptyState icon="route" title="No proven route yet" body="MarketRoute has not yet proved a structural path into this company."/>:<div className="mr-route-live-list">{paths.slice(0,8).map((path,index)=>{const authorised=booleanValue(path.authorised);return <article key={text(path.pathFingerprint)}><div className="mr-route-live-list__head"><div><span className="mr-route-live-list__number">Route {index+1}</span><StatusBadge compact label={authorised?"Contact-qualified":"Structural only"} tone={authorised?"green":"amber"}/></div><span title={text(path.pathState)}>{humanStatus(text(path.pathState))} · {shortFingerprint(path.pathFingerprint)}</span></div><RoutePath nodes={routeNodes(path.nodes,authorised)} caption={`${humanStatus(text(path.knowledgeState))} relationship knowledge · terminal access point ${text(path.terminalAccessPointId)}`}/></article>})}</div>}</Panel>
        <Panel className="mr-evidence-panel"><SectionHeading eyebrow="PROVENANCE · ADVANCED" title="Show me exactly what this decision is built on" description="Open a current-lineage claim to inspect the evidence, source and revalidation state behind the commercial decision."/>{claims.length===0?<EmptyState icon="database" title="No current claim lineage" body="There is no current claim snapshot available for provenance inspection."/>:<div className="mr-claim-grid">{claims.slice(0,24).map((claim)=><a href={`${returnHref}?claim=${encodeURIComponent(text(claim.snapshotId))}`} key={text(claim.snapshotId)}><div><strong>{humanStatus(text(claim.claimKey))}</strong><span>{humanStatus(text(claim.predicate))} · {text(claim.canonicalValue,"structured")}</span></div><StatusBadge compact label={humanStatus(text(claim.truthState))} title={text(claim.truthState)} tone={statusTone(text(claim.truthState))}/><small>{Array.isArray(claim.layers)?claim.layers.filter((layer):layer is string=>typeof layer==="string").join(", "):"Current lineage"}</small></a>)}</div>}</Panel>
      </div>
    </details>
    {provenance&&<ProvenanceDrawer model={provenance} closeHref={returnHref}/>} 
  </div>
}
