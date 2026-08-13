import { StatusBadge, type VisualTone } from "@/ui/primitives/status-badge";

export interface AuthorityStageView {
  stage: string;
  name: string;
  decision: string;
  detail: string;
  tone: VisualTone;
}

interface AuthorityStackProps {
  stages: AuthorityStageView[];
}

export function AuthorityStack({ stages }: AuthorityStackProps) {
  return (
    <div className="mr-authority-stack">
      {stages.map((stage, index) => (
        <article className="mr-authority-stage" key={`${stage.stage}-${stage.decision}`}>
          <div className="mr-authority-stage__rail" aria-hidden="true">
            <span>{stage.stage}</span>
            {index < stages.length - 1 && <i />}
          </div>
          <div className="mr-authority-stage__content">
            <div>
              <small>{stage.name}</small>
              <strong>{stage.detail}</strong>
            </div>
            <StatusBadge label={stage.decision} tone={stage.tone} compact />
          </div>
        </article>
      ))}
    </div>
  );
}
