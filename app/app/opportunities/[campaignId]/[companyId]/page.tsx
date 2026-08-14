import { workspaceSessionOrRedirect } from "@/app/app/_lib/session";
import { applicationReadServiceFromEnvironment } from "@/application/read-model/service";
import { asObject,asObjectArray,booleanValue,companyProfile,formatDateTime,percent,shortFingerprint,statusTone,text } from "@/application/read-model/presentation";
import type { RouteNodeView } from "@/ui/intelligence/route-path";
import { AuthorityStack,commercialVerdict,EmptyState,humanStatus,Icon,PageHeader,Panel,ProvenanceDrawer,ProvenanceTrail,ResearchPressure,routeSummary,RoutePath,SectionHeading,StatusBadge,TruthGauge,truthStrength } from "@/ui";

function routeNodes(value:unknown):RouteNodeView[]{
  return asObjectArray(value).map((node)=>{
    const kind=text(node.kind,"ORGANISATIONAL_UNIT");
    return {label:text(node.label,"Unnamed node"),meta:text(node.meta,""),kind:kind==="COMPANY"?"company":kind==="PERSON"?"person":kind==="ACCESS_POINT"?"channel":"unit"};
  });
}

export default async function OpportunityWorkspace({params,searchParams}:{params:Promise<{campaignId:string;companyId:string}>;searchParams:Promise<Record<string,string|string[]|undefined>>}){
  const {campaignId,companyId}=await params;
  const query=await searchParams;
  const {workspace}=await workspaceSessionOrRedirect();
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

  const stages=[
    {stage:"R4",name:"Commercial reality",decision:text(r4.decision,"NO CURRENT R4"),detail:humanStatus(text(r4.decision,"NO_CURRENT_R4")),tone:statusTone(text(r4.decision,"UNKNOWN"))},
    {stage:"R5",name:"Route authority",decision:text(r5.decision,"NO CURRENT R5"),detail:`${Number(r5.distinctAccessPointCount??0)} structural access point(s) currently represented`,tone:statusTone(text(r5.decision,"UNKNOWN"))},
    {stage:"R6",name:"Contact authority",decision:text(r6.decision,"NO CURRENT R6"),detail:`${Number(r6.distinctAuthorisedAccessPointCount??0)} qualified access point(s) currently authorised`,tone:statusTone(text(r6.decision,"UNKNOWN"))}
  ];
  const gaps=asObjectArray(research.candidates).slice(0,6).map((g)=>({label:`${humanStatus(text(g.layer))}: ${humanStatus(text(g.action))}`,detail:humanStatus(text(g.reasonCode)),state:(text(g.tier)==="DECISION_BLOCKER"?"blocking":text(g.tier)==="ENRICHMENT"?"clear":"watch") as "blocking"|"watch"|"clear"}));
  const truthDimensions:Array<{label:string;value:unknown}>=[{label:"Coverage",value:truth.currentCoverage},{label:"Evidence sufficiency",value:truth.evidenceSufficiency},{label:"Freshness",value:truth.freshnessCoverage},{label:"Coherence",value:truth.coherence}];
  const verdict=commercialVerdict(profile.disposition,profile.executableNow);

  return <div>
    <PageHeader eyebrow="OPPORTUNITY" title={profile.companyName} description={profile.canonicalDomain??"Canonical domain not yet established"} actions={<StatusBadge label={profile.executableNow?"Ready to contact":"Not ready to contact"} tone={profile.executableNow?"green":"slate"}/>}/>
    {actionError&&<div className="mr-alert mr-alert--error"><Icon name="shield" size={16}/><span>{actionError}</span></div>}

    <section className="mr-opportunity-verdict">
      <div className="mr-opportunity-verdict__copy"><span>MarketRoute view</span><h2>{verdict}</h2><p>{profile.executableNow?"The current commercial case, organisational route and contact authority allow action now.":"MarketRoute is holding action until the required commercial, route and contact authority is current."}</p></div>
      <dl className="mr-opportunity-verdict__facts">
        <div><dt>Commercial case</dt><dd>{humanStatus(profile.commercialReality)}</dd><small>R4</small></div>
        <div><dt>Route in</dt><dd>{routeSummary(profile.authorisedRoutes,profile.structuralRoutes)}</dd><small>R5</small></div>
        <div><dt>Buyer access</dt><dd>{humanStatus(profile.contactAuthority)}</dd><small>R6</small></div>
        <div><dt>Research strength</dt><dd>{truthStrength(truthIndex)}</dd><small>Truth Index {truthIndex}/100</small></div>
      </dl>
    </section>

    <section className="mr-dashboard-grid mr-dashboard-grid--primary">
      <Panel emphasis="blue"><SectionHeading eyebrow="Commercial decision · R4 → R6" title="Why is this company worth pursuing?" description="MarketRoute keeps the three required authority questions separate. A company does not become an opportunity because one aggregate score crossed a threshold."/><AuthorityStack stages={stages}/><div className="mr-authority-meta"><div><span>Authority lineage</span><strong>{shortFingerprint(authority.envelopeFingerprint)}</strong></div><div><span>Next revalidation</span><strong>{formatDateTime(profile.nextRevalidationAt)}</strong></div></div></Panel>

      <Panel><SectionHeading eyebrow="Research quality · Truth Index" title="How strong is the research?" description="Coverage, evidence sufficiency, freshness and coherence are shown separately. Epistemic quality, not probability."/><TruthGauge value={truthIndex} state={humanStatus(text(truth.entityState,"NO CURRENT TRUTH"))}/><div className="mr-truth-dimensions">{truthDimensions.map(({label,value})=><div className="mr-truth-dimension" key={label}><div><span>{label}</span><strong>{Math.round(percent(value))}%</strong></div><div className="mr-progress"><span style={{width:`${percent(value)}%`}}/></div></div>)}</div><div className="mr-calibration-note"><Icon name="database" size={15}/><div><span>Probability calibration</span><strong>{humanStatus(text(truth.probabilityState,"UNCALIBRATED"))}</strong></div></div></Panel>
    </section>

    <Panel className="mr-route-live-panel"><SectionHeading eyebrow="Route to buyer · R5 + R6" title="How do we reach the right person?" description="Structural paths come from current R5. A named person or channel only becomes usable when current R6 contact authority binds it."/>{paths.length===0?<EmptyState icon="route" title="No proven route yet" body="MarketRoute has not yet proved a structural path into this company."/>:<div className="mr-route-live-list">{paths.slice(0,8).map((path,index)=>{const authorised=booleanValue(path.authorised);return <article key={text(path.pathFingerprint)}><div className="mr-route-live-list__head"><div><span className="mr-route-live-list__number">Route {index+1}</span><StatusBadge compact label={authorised?"Contact-qualified":"Structural only"} tone={authorised?"green":"amber"}/></div><span title={text(path.pathState)}>{humanStatus(text(path.pathState))} · {shortFingerprint(path.pathFingerprint)}</span></div><RoutePath nodes={routeNodes(path.nodes)} caption={`${humanStatus(text(path.knowledgeState))} relationship knowledge · terminal access point ${text(path.terminalAccessPointId)}`}/></article>})}</div>}</Panel>

    <section className="mr-dashboard-grid mr-dashboard-grid--secondary">
      <Panel><SectionHeading eyebrow="Open questions · Genesis research" title="What still needs to be known?" description={humanStatus(text(research.lifecycleState,"Current authority lifecycle"))}/>{gaps.length?<ResearchPressure items={gaps}/>:<EmptyState icon="check" title="No active research pressure" body="The current research read returned no pending knowledge gaps."/>}</Panel>

      <Panel><SectionHeading eyebrow="Your decision · Workflow" title="What happens next?" description="Human workflow remains independent from mathematical authority. Your approval cannot make stale or missing authority executable."/><ProvenanceTrail items={[{label:"Current workflow",value:humanStatus(text(workflow.state,"Not materialised"))},{label:"Ready for review",value:model.actions.canReview?"Yes":"No"},{label:"Outreach can be generated",value:model.actions.canGenerateEngagement?"Yes":"No"},{label:"Executable now",value:model.actions.canExecute?"Yes":"No"}]}/>{!canMutate&&<div className="mr-readonly-note"><Icon name="shield" size={15}/><span>Viewer access is read-only.</span></div>}{canMutate&&model.actions.canReview&&opportunityId&&<form className="mr-review-form" action={`/api/opportunities/${opportunityId}/review`} method="post"><input type="hidden" name="campaignId" value={campaignId}/><input type="hidden" name="companyId" value={companyId}/><input type="hidden" name="returnTo" value={returnHref}/><label><span>Decision note</span><textarea name="note" placeholder="Optional note for your team" rows={2}/></label><div><button className="mr-button mr-button--primary" name="decision" value="APPROVE" type="submit">Approve opportunity</button><button className="mr-button mr-button--secondary" name="decision" value="RETURN_TO_RESEARCH" type="submit">Request more research</button><button className="mr-button mr-button--ghost" name="decision" value="REJECT" type="submit">Reject</button></div></form>}</Panel>

      <Panel><SectionHeading eyebrow="Outreach · Engagement" title="Is there outreach in progress?" description="Message strategy and delivery sit downstream of opportunity approval and are checked against live authority again before execution."/>{canMutate&&model.actions.canGenerateEngagement&&opportunityId&&authorisedPath&&<form className="mr-message-actions" action={`/api/engagement/opportunities/${opportunityId}/generate`} method="post"><input type="hidden" name="pathFingerprint" value={text(authorisedPath.pathFingerprint)}/><input type="hidden" name="returnTo" value={returnHref}/><button className="mr-button mr-button--primary" type="submit">Generate outreach draft</button></form>}{Object.keys(engagement).length===0?<EmptyState icon="engagement" title="No outreach yet" body={model.actions.canGenerateEngagement?"Generate an evidence-grounded draft from the authorised route above.":"Approve an executable opportunity before engagement can begin."}/>:<><ProvenanceTrail items={[{label:"Approval policy",value:humanStatus(text(engagement.policyMode,"HUMAN_ONLY"))},{label:"Channel",value:humanStatus(text(asObject(engagement.strategy).channel,"Not generated"))},{label:"Message review",value:humanStatus(text(asObject(engagement.aiReview).verdict,"Pending"))},{label:"Delivery",value:humanStatus(text(asObject(engagement.delivery).status,"Not queued"))}]}/>{opportunityId&&typeof asObject(engagement.message).messageId==="string"&&<div className="mr-message-actions">{canMutate&&booleanValue(asObject(engagement.actions).canApproveMessage)&&<form action={`/api/engagement/messages/${text(asObject(engagement.message).messageId)}/approval`} method="post"><input type="hidden" name="opportunityId" value={opportunityId}/><input type="hidden" name="returnTo" value={returnHref}/><button className="mr-button mr-button--secondary" name="decision" value="APPROVE" type="submit">Approve message</button><button className="mr-button mr-button--ghost" name="decision" value="REJECT" type="submit">Reject message</button></form>}{canMutate&&booleanValue(asObject(engagement.actions).canQueue)&&<form action={`/api/engagement/messages/${text(asObject(engagement.message).messageId)}/queue`} method="post"><input type="hidden" name="opportunityId" value={opportunityId}/><input type="hidden" name="returnTo" value={returnHref}/><button className="mr-button mr-button--primary" type="submit">Queue outreach</button></form>}</div>}</>}</Panel>
    </section>

    <Panel className="mr-evidence-panel"><SectionHeading eyebrow="Evidence and provenance" title="Show me what this decision is built on" description="Open any current-lineage Truth snapshot to inspect the exact claim, evidence, source and revalidation state behind the commercial decision."/>{claims.length===0?<EmptyState icon="database" title="No current claim lineage" body="There is no current R4/R5/R6 claim snapshot available for provenance inspection."/>:<div className="mr-claim-grid">{claims.slice(0,24).map((claim)=><a href={`${returnHref}?claim=${encodeURIComponent(text(claim.snapshotId))}`} key={text(claim.snapshotId)}><div><strong>{humanStatus(text(claim.claimKey))}</strong><span>{humanStatus(text(claim.predicate))} · {text(claim.canonicalValue,"structured")}</span></div><StatusBadge compact label={humanStatus(text(claim.truthState))} title={text(claim.truthState)} tone={statusTone(text(claim.truthState))}/><small>{Array.isArray(claim.layers)?claim.layers.filter((layer):layer is string=>typeof layer==="string").join(", "):"Current lineage"}</small></a>)}</div>}</Panel>
    {provenance&&<ProvenanceDrawer model={provenance} closeHref={returnHref}/>} 
  </div>
}
