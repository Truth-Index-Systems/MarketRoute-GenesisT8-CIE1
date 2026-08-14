interface TruthGaugeProps {
  value: number;
  label?: string;
  state?: string;
}

function clampPercent(value: number) {
  return Math.max(0, Math.min(100, Math.round(value)));
}

export function TruthGauge({ value, label = "Research strength", state }: TruthGaugeProps) {
  const safe = clampPercent(value);
  return (
    <div className="mr-truth-gauge" aria-label={`${label}: ${safe} out of 100`}>
      <div className="mr-truth-gauge__score">
        <strong>{safe}</strong>
        <span>/100</span>
      </div>
      <div className="mr-truth-gauge__copy">
        <span>{label}</span>
        {state && <strong>{state}</strong>}
        <small>Truth Index</small>
      </div>
      <div className="mr-truth-gauge__bar" aria-hidden="true"><span style={{ width: `${safe}%` }} /></div>
    </div>
  );
}
