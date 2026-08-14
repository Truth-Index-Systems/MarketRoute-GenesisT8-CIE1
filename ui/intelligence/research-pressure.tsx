interface ResearchPressureItem {
  label: string;
  detail: string;
  state: "blocking" | "watch" | "clear";
}

interface ResearchPressureProps {
  items: ResearchPressureItem[];
}

const stateLabel = { blocking: "Needs evidence", watch: "Monitor", clear: "Resolved" } as const;

export function ResearchPressure({ items }: ResearchPressureProps) {
  return (
    <div className="mr-pressure-list">
      {items.map((item) => (
        <div className="mr-pressure-item" key={item.label}>
          <span className={`mr-pressure-item__signal mr-pressure-item__signal--${item.state}`} aria-hidden="true" />
          <div>
            <strong>{item.label}</strong>
            <small>{item.detail}</small>
          </div>
          <span className="mr-pressure-item__state">{stateLabel[item.state]}</span>
        </div>
      ))}
    </div>
  );
}
