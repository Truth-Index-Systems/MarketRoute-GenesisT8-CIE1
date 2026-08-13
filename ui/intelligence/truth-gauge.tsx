interface TruthGaugeProps {
  value: number;
  label?: string;
  state?: string;
}

function clampPercent(value: number) {
  return Math.max(0, Math.min(100, Math.round(value)));
}

export function TruthGauge({ value, label = "Truth Index", state }: TruthGaugeProps) {
  const safe = clampPercent(value);
  return (
    <div className="mr-truth-gauge" aria-label={`${label}: ${safe}%`}>
      <div className="mr-truth-gauge__ring" style={{ "--mr-gauge": `${safe}%` } as React.CSSProperties}>
        <div className="mr-truth-gauge__inner">
          <strong>{safe}</strong>
          <span>/100</span>
        </div>
      </div>
      <div className="mr-truth-gauge__copy">
        <span>{label}</span>
        {state && <strong>{state}</strong>}
      </div>
    </div>
  );
}
