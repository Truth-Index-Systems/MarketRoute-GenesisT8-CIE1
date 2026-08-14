export type VisualTone = "blue" | "green" | "amber" | "red" | "slate" | "violet";

interface StatusBadgeProps {
  label: string;
  tone?: VisualTone;
  dot?: boolean;
  compact?: boolean;
  title?: string;
}

export function StatusBadge({ label, tone = "slate", dot = true, compact = false, title }: StatusBadgeProps) {
  return (
    <span title={title} className={["mr-badge", `mr-badge--${tone}`, compact ? "mr-badge--compact" : ""].filter(Boolean).join(" ")}>
      {dot && <span className="mr-badge__dot" aria-hidden="true" />}
      {label}
    </span>
  );
}
