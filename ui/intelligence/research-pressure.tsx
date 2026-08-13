interface ResearchPressureItem {
  label: string;
  detail: string;
  state: "blocking" | "watch" | "clear";
}

interface ResearchPressureProps {
  items: ResearchPressureItem[];
}

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
        </div>
      ))}
    </div>
  );
}
