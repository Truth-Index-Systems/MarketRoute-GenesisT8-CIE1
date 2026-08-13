import {
  AuthorityStack,
  Button,
  Icon,
  MetricCard,
  Panel,
  ProvenanceTrail,
  ResearchPressure,
  RoutePath,
  SectionHeading,
  StatusBadge,
  TruthGauge,
} from "@/ui";

const authorityStages = [
  { stage: "R4", name: "Commercial reality", decision: "CANDIDATE", detail: "Commercially admissible", tone: "green" as const },
  { stage: "R5", name: "Route authority", decision: "OPEN", detail: "Structural route proven", tone: "blue" as const },
  { stage: "R6", name: "Contact authority", decision: "AUTHORISED", detail: "Named route current", tone: "violet" as const },
];

const routeNodes = [
  { label: "Northstar Systems", meta: "Target company", kind: "company" as const },
  { label: "Revenue Operations", meta: "Commercial function", kind: "unit" as const },
  { label: "Maya Chen", meta: "VP Revenue Operations", kind: "person" as const },
  { label: "Work email", meta: "Current ownership proven", kind: "channel" as const },
];

export default function CommandCentrePreview() {
  return (
    <div className="mr-command-preview">
      <section className="mr-page-intro">
        <div>
          <div className="mr-kicker"><span /> COMMAND CENTRE</div>
          <h1>Know who to target.<br /><em>Know the route in.</em></h1>
          <p>
            MarketRoute turns evidence into commercial reality, proven routes and contact authority—so the companies you pursue come with a reason and a path.
          </p>
        </div>
        <div className="mr-preview-notice" role="note">
          <Icon name="spark" size={16} />
          <div><strong>Design system preview</strong><span>Non-authoritative sample data · Build 14</span></div>
        </div>
      </section>

      <section className="mr-metric-grid" aria-label="Preview intelligence metrics">
        <MetricCard label="Companies mapped" value="1,248" meta="Across active market research" icon={<Icon name="companies" />} />
        <MetricCard label="Commercial candidates" value="186" meta="Current R4 candidate state" icon={<Icon name="shield" />} accent />
        <MetricCard label="Routes structurally open" value="143" meta="Current R5 route authority" icon={<Icon name="route" />} />
        <MetricCard label="Contact authorised" value="97" meta="Current R6 contact authority" icon={<Icon name="check" />} />
      </section>

      <section className="mr-dashboard-grid mr-dashboard-grid--primary">
        <Panel className="mr-opportunity-preview" emphasis="blue">
          <SectionHeading
            eyebrow="Opportunity intelligence"
            title="Northstar Systems"
            description="B2B software · United Kingdom"
            action={<StatusBadge label="ACTIONABLE" tone="green" />}
          />
          <div className="mr-opportunity-preview__body">
            <AuthorityStack stages={authorityStages} />
            <div className="mr-route-column">
              <div className="mr-panel-label">Proven route</div>
              <RoutePath nodes={routeNodes} caption="Every edge is structural or Truth-qualified. R6 owns the final person/channel binding." />
            </div>
          </div>
          <div className="mr-opportunity-preview__footer">
            <div>
              <span className="mr-data-label">Workflow</span>
              <strong>REVIEWABLE</strong>
            </div>
            <div>
              <span className="mr-data-label">Executable now</span>
              <strong>NO · founder review required</strong>
            </div>
            <Button variant="primary" disabled>Review opportunity <Icon name="arrow" size={16} /></Button>
          </div>
        </Panel>

        <Panel className="mr-truth-preview">
          <SectionHeading eyebrow="Truth" title="Evidence readiness" description="Epistemic quality, not probability." />
          <TruthGauge value={86} state="CURRENT" />
          <div className="mr-truth-dimensions">
            {[
              ["Coverage", 94],
              ["Evidence sufficiency", 91],
              ["Freshness", 86],
              ["Coherence", 98],
            ].map(([label, value]) => (
              <div className="mr-truth-dimension" key={String(label)}>
                <div><span>{label}</span><strong>{value}%</strong></div>
                <div className="mr-progress"><span style={{ width: `${value}%` }} /></div>
              </div>
            ))}
          </div>
          <div className="mr-calibration-note">
            <Icon name="database" size={16} />
            <div><span>Probability calibration</span><strong>UNCALIBRATED</strong></div>
          </div>
        </Panel>
      </section>

      <section className="mr-dashboard-grid mr-dashboard-grid--secondary">
        <Panel>
          <SectionHeading eyebrow="Genesis" title="Research pressure" description="What must be learned next, ordered categorically." />
          <ResearchPressure items={[
            { label: "Buyer-role currency", detail: "Contact Truth revalidation due in 2h", state: "watch" },
            { label: "Secondary route", detail: "One independent route currently authorised", state: "watch" },
            { label: "Commercial boundaries", detail: "All mandatory R4 boundaries represented", state: "clear" },
          ]} />
        </Panel>

        <Panel>
          <SectionHeading eyebrow="Lineage" title="Authority provenance" description="The exact chain behind the current product state." />
          <ProvenanceTrail items={[
            { label: "Truth", value: "MRV2-TFR · current" },
            { label: "R4", value: "Commercial candidate" },
            { label: "R5", value: "Structural route open" },
            { label: "R6", value: "Contact authorised" },
          ]} />
        </Panel>

        <Panel>
          <SectionHeading eyebrow="Engagement" title="Next action" description="Language stays downstream of current authority." />
          <div className="mr-next-action">
            <div className="mr-next-action__icon"><Icon name="engagement" size={19} /></div>
            <div><strong>Founder review required</strong><p>Approve the opportunity before MarketRoute can generate or queue outreach.</p></div>
          </div>
          <div className="mr-next-action__meta">
            <StatusBadge label="HUMAN ONLY" tone="slate" compact />
            <span>Send gate re-checks R4 → R5 → R6</span>
          </div>
        </Panel>
      </section>
    </div>
  );
}
