import { redirect } from "next/navigation";
import { founderSessionIsValid } from "@/application/founder/auth";
import { loadFounderDashboard,type FounderStageState } from "@/application/founder/dashboard";
import { MarketRouteLogo } from "@/ui/brand/marketroute-logo";
import { Icon,type IconName } from "@/ui/icons";

export const runtime="nodejs";
export const dynamic="force-dynamic";
export const revalidate=0;

function obj(value:unknown):Record<string,unknown>{return value&&typeof value==="object"&&!Array.isArray(value)?value as Record<string,unknown>:{};}
function num(value:unknown){const n=Number(value??0);return Number.isFinite(n)?n:0;}
function text(value:unknown,fallback="—"){return typeof value==="string"&&value?value:fallback;}
function money(value:unknown){const n=num(value);return `$${n.toLocaleString("en-US",{minimumFractionDigits:n<10?2:0,maximumFractionDigits:2})}`;}
function integer(value:unknown){return Math.round(num(value)).toLocaleString("en-GB");}
function relative(value:string|null){if(!value)return "No activity yet";const ms=Date.now()-Date.parse(value);if(!Number.isFinite(ms))return "No activity yet";const min=Math.max(0,Math.floor(ms/60000));if(min<1)return "just now";if(min<60)return `${min}m ago`;const h=Math.floor(min/60);if(h<48)return `${h}h ago`;return `${Math.floor(h/24)}d ago`;}
function stateLabel(state:FounderStageState){return state==="LIVE"?"Live now":state==="WORKING"?"Producing data":state==="WAITING"?"Waiting for data":state==="ATTENTION"?"Needs attention":"Disabled";}
function iconFor(key:string):IconName{return key==="growth"?"database":key==="bootstrap"?"spark":key==="discovery"?"companies":key==="research"?"research":key==="evidence"?"database":key==="truth"?"shield":key==="r4"?"check":key==="r5"?"route":key==="r6"?"user":key==="opportunity"?"opportunities":key==="engagement"?"engagement":"mail";}

export default async function FounderDashboard(){
  if(!(await founderSessionIsValid()))redirect("/dashboard/login");
  let model;
  try{model=await loadFounderDashboard();}catch(error){
    const message=error instanceof Error?error.message:"MARKETROUTE_FOUNDER_DASHBOARD_FAILED";
    return <main className="mr-founder"><header className="mr-founder__topbar"><MarketRouteLogo/><div><span>Founder operations</span><form method="post" action="/api/founder/logout"><button type="submit">Lock dashboard</button></form></div></header><section className="mr-founder__error"><span>DATA CONNECTION</span><h1>Founder dashboard is protected, but its observability data is not available yet.</h1><p>{message}</p><p>Apply the Founder Dashboard Supabase migration, then refresh this page.</p></section></main>;
  }
  const {snapshot,environment,stages}=model;
  const platform=obj(snapshot.platform),growth=obj(snapshot.growth),research=obj(snapshot.research),evidence=obj(snapshot.evidence),truth=obj(snapshot.truth),r4=obj(snapshot.r4),r5=obj(snapshot.r5),r6=obj(snapshot.r6),opportunity=obj(snapshot.opportunity),engagement=obj(snapshot.engagement),ai=obj(snapshot.ai),runtime=obj(snapshot.runtime),schema=obj(snapshot.schemaRelease);
  const criticalAttention=stages.filter(s=>s.state==="ATTENTION").length;
  const live=stages.filter(s=>s.state==="LIVE"||s.state==="WORKING").length;
  const budget=num(research.dailyBudgetUsd),spentToday=num(research.spentTodayUsd);
  const budgetPct=budget>0?Math.min(100,(spentToday/budget)*100):0;
  const researched=num(truth.researchedCompanies),scoped=num(obj(snapshot.discovery).scopedCompanies);
  const researchCoverage=scoped>0?Math.min(100,(researched/scoped)*100):0;
  const generatedAt=text(snapshot.generatedAt);
  const growthTarget=Math.max(1,num(growth.targetCompanies));
  const growthCompanies=num(growth.companies),growthDense80=num(growth.dense80),growthDense100=num(growth.dense100);
  const growthPct=Math.min(100,(growthCompanies/growthTarget)*100);
  const growthDensePct=Math.min(100,(growthDense80/growthTarget)*100);
  const growthIndustries=(Array.isArray(growth.industries)?growth.industries:[]).map(obj);
  return <main className="mr-founder">
    <header className="mr-founder__topbar"><div className="mr-founder__brand"><MarketRouteLogo/><span>Founder operations</span></div><div className="mr-founder__top-actions"><a href="/dashboard">Refresh data</a><form method="post" action="/api/founder/logout"><button type="submit">Lock dashboard</button></form></div></header>

    <section className="mr-founder__hero">
      <div><div className="mr-founder__eyebrow"><span className={criticalAttention?"attention":"healthy"}/>{criticalAttention?`${criticalAttention} stage${criticalAttention===1?"":"s"} need attention`:`${live} stages are live or producing`}</div><h1>Is MarketRoute actually working?</h1><p>This console answers that from persisted production data — not from frontend assumptions. Every stage shows what it has produced, when it last moved and whether the runtime feeding it is alive.</p></div>
      <div className="mr-founder__hero-meta"><span>Snapshot</span><strong>{new Date(generatedAt).toLocaleString("en-GB",{dateStyle:"medium",timeStyle:"short",timeZone:"UTC"})} UTC</strong><small>{text(schema.releaseKey,"Schema release unavailable")}</small></div>
    </section>

    <section className="mr-founder-growth">
      <div className="mr-founder-growth__head"><div><span>PRE-LAUNCH PRIMARY</span><h2>Genesis database growth</h2><p>Autonomous shared intelligence — independent of customer campaigns. Genesis is building the reusable market database first, then campaigns can consume what is already known.</p></div><div className="mr-founder-growth__phase"><span>Current phase</span><strong>{text(growth.phase,"SEED")}</strong><small>Next: {text(growth.nextPriorityIndustry,"waiting for planner")}</small></div></div>
      <div className="mr-founder-growth__metrics"><article><span>Companies</span><strong>{integer(growthCompanies)} <small>/ {integer(growthTarget)}</small></strong><div className="mr-founder-progress"><span style={{width:`${growthPct}%`}}/></div><p>{growthPct.toFixed(1)}% of launch breadth</p></article><article><span>≥80% data density</span><strong>{integer(growthDense80)}</strong><div className="mr-founder-progress"><span style={{width:`${growthDensePct}%`}}/></div><p>{growthDensePct.toFixed(1)}% of launch density target</p></article><article><span>100% dense</span><strong>{integer(growthDense100)}</strong><p>Core + profile + routes + contact intelligence</p></article><article><span>Average data density</span><strong>{num(growth.averageDensity).toFixed(0)}%</strong><p>Operational completeness — not Truth probability</p></article><article><span>Growth spend today</span><strong>{money(growth.spentTodayUsd)}</strong><p>of {money(growth.dailyBudgetUsd)} autonomous budget</p></article></div>
      <div className="mr-founder-growth__industries">{growthIndustries.map(row=>{const companies=num(row.companies),target=Math.max(1,num(row.launchTarget)),pct=Math.min(100,(companies/target)*100);return <article key={text(row.key)}><div className="mr-founder-growth__industry-head"><div><span>{text(row.name)}</span><small>Priority {integer(row.priority)}</small></div><strong>{integer(companies)} <small>/ {integer(target)}</small></strong></div><div className="mr-founder-progress"><span style={{width:`${pct}%`}}/></div><div className="mr-founder-growth__industry-meta"><span>≥80% <strong>{integer(row.dense80)}</strong></span><span>100% <strong>{integer(row.dense100)}</strong></span><span>Avg <strong>{num(row.averageDensity).toFixed(0)}%</strong></span><span>People <strong>{integer(row.people)}</strong></span><span>Routes <strong>{integer(row.relationships)}</strong></span></div></article>})}</div>
    </section>

    <section className="mr-founder__summary-grid">
      <article><span>Companies collected</span><strong>{integer(obj(snapshot.discovery).companies)}</strong><small>{integer(obj(snapshot.discovery).people)} people identified</small></article>
      <article><span>Evidence collected</span><strong>{integer(evidence.items)}</strong><small>{integer(evidence.sources)} sources · {integer(evidence.claims)} claims</small></article>
      <article><span>Companies with Truth</span><strong>{integer(truth.researchedCompanies)}</strong><small>{researchCoverage.toFixed(0)}% of scoped companies</small></article>
      <article><span>Commercial candidates</span><strong>{integer(r4.candidates)}</strong><small>{integer(r5.reachableCompanies)} currently reachable</small></article>
      <article><span>Contact-qualified</span><strong>{integer(r6.contactQualifiedCompanies)}</strong><small>{integer(r6.authorisedAccessPoints)} authorised access points</small></article>
      <article><span>Opportunities</span><strong>{integer(opportunity.total)}</strong><small>{integer(opportunity.reviewable)} reviewable · {integer(opportunity.approved)} approved</small></article>
    </section>

    <section className="mr-founder__section-head"><div><span>END-TO-END PIPELINE</span><h2>Every production stage</h2></div><p>A zero is not automatically a failure. “Waiting for data” means the stage has not yet received enough upstream material; “Needs attention” means a persisted failure or failed runtime was observed.</p></section>
    <section className="mr-founder__pipeline">
      {stages.map((stage,index)=><article className={`mr-founder-stage mr-founder-stage--${stage.state.toLowerCase()}`} key={stage.key}>
        <div className="mr-founder-stage__index">{String(index+1).padStart(2,"0")}</div><div className="mr-founder-stage__icon"><Icon name={iconFor(stage.key)} size={19}/></div>
        <div className="mr-founder-stage__identity"><span>{stage.technicalLabel}</span><h3>{stage.label}</h3><p>{stage.detail}</p></div>
        <div className="mr-founder-stage__volume"><strong>{integer(stage.value)}</strong><span>{stage.valueLabel}</span>{stage.secondary&&<small>{stage.secondary}</small>}</div>
        <div className="mr-founder-stage__health"><span className={`mr-founder-status mr-founder-status--${stage.state.toLowerCase()}`}><i/>{stateLabel(stage.state)}</span><small>{relative(stage.latestAt)}</small></div>
      </article>)}
    </section>

    <section className="mr-founder__two-col">
      <div className="mr-founder-panel"><div className="mr-founder-panel__head"><div><span>GENESIS RESEARCH</span><h2>Research throughput & budget</h2></div><Icon name="research" size={20}/></div><div className="mr-founder-panel__metrics"><div><span>Work units</span><strong>{integer(research.workUnits)}</strong></div><div><span>Completed</span><strong>{integer(research.succeeded)}</strong></div><div><span>Queued / running</span><strong>{integer(num(research.pending)+num(research.running))}</strong></div><div><span>Failed</span><strong>{integer(research.failed)}</strong></div></div><div className="mr-founder-budget"><div><span>Today</span><strong>{money(spentToday)} <small>of {money(budget)} configured</small></strong></div><div className="mr-founder-progress"><span style={{width:`${budgetPct}%`}}/></div><div className="mr-founder-budget__foot"><span>Lifetime research spend {money(research.spentUsd)}</span><span>{budget>0?`${budgetPct.toFixed(1)}% of today's configured allowance`:`No active research budget yet`}</span></div></div></div>

      <div className="mr-founder-panel"><div className="mr-founder-panel__head"><div><span>OPENAI</span><h2>Model activity</h2></div><Icon name="spark" size={20}/></div><div className="mr-founder-ai"><div className="mr-founder-ai__primary"><span>24h requests</span><strong>{integer(ai.requests24h)}</strong><small>{integer(ai.success24h)} succeeded · {integer(ai.failed24h)} failed</small></div><div className="mr-founder-ai__secondary"><div><span>24h spend</span><strong>{money(ai.spend24hUsd)}</strong></div><div><span>Lifetime spend</span><strong>{money(ai.spendUsd)}</strong></div><div><span>Model</span><strong>{text(ai.latestModel,environment.openAIModel)}</strong></div><div><span>Last request</span><strong>{relative(typeof ai.latestAt==="string"?ai.latestAt:null)}</strong></div></div></div></div>
    </section>

    <section className="mr-founder__two-col">
      <div className="mr-founder-panel"><div className="mr-founder-panel__head"><div><span>DATA VOLUME</span><h2>What Genesis has accumulated</h2></div><Icon name="database" size={20}/></div><div className="mr-founder-data-list"><div><span>Shared growth companies</span><strong>{integer(growth.companies)}</strong></div><div><span>Canonical companies</span><strong>{integer(obj(snapshot.discovery).companies)}</strong></div><div><span>People</span><strong>{integer(obj(snapshot.discovery).people)}</strong></div><div><span>Sources</span><strong>{integer(evidence.sources)}</strong></div><div><span>Acquisitions</span><strong>{integer(evidence.acquisitions)}</strong></div><div><span>Evidence items</span><strong>{integer(evidence.items)}</strong></div><div><span>Claims</span><strong>{integer(evidence.claims)}</strong></div><div><span>Truth entity snapshots</span><strong>{integer(truth.entitySnapshots)}</strong></div><div><span>Commercial relationships</span><strong>{integer(r5.relationships)}</strong></div><div><span>Graph nodes</span><strong>{integer(r5.graphNodes)}</strong></div></div></div>

      <div className="mr-founder-panel"><div className="mr-founder-panel__head"><div><span>PRODUCTION RUNTIME</span><h2>Cron heartbeat</h2></div><Icon name="clock" size={20}/></div><div className="mr-founder-runtime">{([['GROWTH','Every 2 min'],['BOOTSTRAP','Every 10 min'],['RESEARCH','Every 5 min'],['DELIVERY','Every 2 min']] as const).map(([key,schedule])=>{const row=obj(runtime[key]);const event=text(row.eventType,"NO RUN");const at=typeof row.occurredAt==="string"?row.occurredAt:null;return <div key={key}><span className={`mr-founder-runtime__dot mr-founder-runtime__dot--${event.toLowerCase()}`}/><div><strong>{key.charAt(0)+key.slice(1).toLowerCase()}</strong><small>{schedule}</small></div><div className="mr-founder-runtime__right"><strong>{event}</strong><small>{relative(at)}</small></div></div>})}</div><div className="mr-founder-runtime-note">Delivery is {environment.deliveryEnabled?<strong>enabled</strong>:<strong>intentionally disabled</strong>}. A disabled delivery heartbeat is healthy while the kill switch remains off.</div></div>
    </section>

    <section className="mr-founder__two-col">
      <div className="mr-founder-panel"><div className="mr-founder-panel__head"><div><span>ENGAGEMENT</span><h2>From message to delivery</h2></div><Icon name="mail" size={20}/></div><div className="mr-founder-funnel"><div><span>Strategies</span><strong>{integer(engagement.strategies)}</strong></div><i/><div><span>Messages</span><strong>{integer(engagement.messages)}</strong></div><i/><div><span>Review passed</span><strong>{integer(engagement.reviewPass)}</strong></div><i/><div><span>Approved</span><strong>{integer(engagement.approvals)}</strong></div><i/><div><span>Sent</span><strong>{integer(engagement.deliverySent)}</strong></div></div><div className="mr-founder-inline-alerts"><span>Blocked stale <strong>{integer(engagement.deliveryBlockedStale)}</strong></span><span>Reconciliation <strong>{integer(engagement.deliveryReconciliation)}</strong></span><span>Failed <strong>{integer(engagement.deliveryFailed)}</strong></span></div></div>

      <div className="mr-founder-panel"><div className="mr-founder-panel__head"><div><span>CONFIGURATION</span><h2>Production readiness</h2></div><Icon name="shield" size={20}/></div><div className="mr-founder-checks"><div><i className={environment.ok?"ok":"bad"}/><span>Core environment</span><strong>{environment.ok?"Configured":"Missing values"}</strong></div><div><i className={environment.founderAuthConfigured?"ok":"bad"}/><span>Founder dashboard auth</span><strong>{environment.founderAuthConfigured?"Configured":"Missing"}</strong></div><div><i className="ok"/><span>Supabase key mode</span><strong>{environment.supabaseKeyMode}</strong></div><div><i className="ok"/><span>OpenAI model</span><strong>{environment.openAIModel}</strong></div><div><i className={environment.deliveryEnabled?"ok":"neutral"}/><span>Email delivery</span><strong>{environment.deliveryEnabled?"Enabled":"Off by design"}</strong></div></div>{environment.missing.length>0&&<div className="mr-founder-config-missing">Missing: {environment.missing.join(", ")}</div>}</div>
    </section>

    <footer className="mr-founder__footer"><span>MarketRoute V2 · Genesis T8 · Founder-only observability</span><span>{integer(platform.activeCampaigns)} active campaigns · {integer(platform.organisations)} organisations</span></footer>
  </main>;
}
