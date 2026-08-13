export type VisualTone = "blue" | "green" | "amber" | "red" | "slate" | "violet";

interface StatusBadgeProps {
  label: string;
  tone?: VisualTone;
  dot?: boolean;
  compact?: boolean;
}

export function StatusBadge({ label, tone = "slate", dot = true, compact = false }: StatusBadgeProps) {
  return (
    <span className={["mr-badge", `mr-badge--${tone}`, compact ? "mr-badge--compact" : ""].filter(Boolean).join(" ")}>
      {dot && <span className="mr-badge__dot" aria-hidden="true" />}
      {label}
    </span>
  );
}
