import type { ReactNode } from "react";

interface PanelProps {
  children: ReactNode;
  className?: string;
  emphasis?: "default" | "blue" | "quiet";
}

export function Panel({ children, className = "", emphasis = "default" }: PanelProps) {
  return <section className={["mr-panel", `mr-panel--${emphasis}`, className].filter(Boolean).join(" ")}>{children}</section>;
}

interface SectionHeadingProps {
  eyebrow?: string;
  title: string;
  description?: string;
  action?: ReactNode;
}

export function SectionHeading({ eyebrow, title, description, action }: SectionHeadingProps) {
  return (
    <header className="mr-section-heading">
      <div>
        {eyebrow && <div className="mr-kicker">{eyebrow}</div>}
        <h2>{title}</h2>
        {description && <p>{description}</p>}
      </div>
      {action && <div className="mr-section-heading__action">{action}</div>}
    </header>
  );
}
