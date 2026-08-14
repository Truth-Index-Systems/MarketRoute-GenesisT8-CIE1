import { StatusBadge, type VisualTone } from "@/ui/primitives/status-badge";
import { humanStatus } from "@/ui/application/language";

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

const meaning: Record<string, string> = {
  R4: "Is there a real commercial reason to engage?",
  R5: "Is there a proven route into the organisation?",
  R6: "Is there a qualified person or channel we can use?",
};

export function AuthorityStack({ stages }: AuthorityStackProps) {
  return (
    <div className="mr-authority-stack">
      {stages.map((stage, index) => (
        <article className="mr-authority-stage" key={`${stage.stage}-${stage.decision}`}>
          <div className="mr-authority-stage__index" aria-hidden="true">{String(index + 1).padStart(2, "0")}</div>
          <div className="mr-authority-stage__content">
            <div className="mr-authority-stage__question">
              <span>{meaning[stage.stage] ?? stage.name}</span>
              <small>{stage.name} · {stage.stage}</small>
            </div>
            <strong>{stage.detail}</strong>
          </div>
          <StatusBadge label={humanStatus(stage.decision)} tone={stage.tone} compact title={stage.decision} />
        </article>
      ))}
    </div>
  );
}
