import type { ReactNode } from "react";

interface MetricCardProps {
  label: string;
  value: string;
  meta?: string;
  icon?: ReactNode;
  accent?: boolean;
}

export function MetricCard({ label, value, meta, icon, accent = false }: MetricCardProps) {
  return (
    <article className={["mr-metric-card", accent ? "mr-metric-card--accent" : ""].filter(Boolean).join(" ")}>
      <div className="mr-metric-card__top">
        <span>{label}</span>
        {icon && <span className="mr-metric-card__icon">{icon}</span>}
      </div>
      <strong>{value}</strong>
      {meta && <p>{meta}</p>}
    </article>
  );
}
